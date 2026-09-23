class_name Autopilot
extends Node
## The aircraft's two automatic modes. Either one is cancelled the instant the
## pilot touches a stick or a trigger - the operator is always in charge.
##
##   RETURN HOME  Climbs to a safe height above the staging area, flies
##                straight back, and descends onto the van's deck facing the
##                way it launched. What every survey drone does when the link
##                degrades or the operator calls it in.
##
##   ORBIT        Circles a contact at the radius it was engaged from, nose
##                and gimbal held on the target: a point-of-interest orbit,
##                used to inspect a find from every side without having to
##                fly it by hand.
##
## It flies through exactly the same command path as the sticks - a velocity
## and a yaw rate - so it inherits the same smoothing, the same collision
## behaviour and the same limits. It cannot do anything a pilot could not.

signal mode_changed(mode: int)

enum Mode { OFF, RETURN_HOME, ORBIT }
const MODE_NAMES := ["OFF", "RETURN HOME", "ORBIT"]

enum Phase { CLIMB, TRANSIT, DESCEND }
const PHASE_NAMES := ["CLIMBING", "RETURNING", "DESCENDING"]

@export var cruise_speed := 10.0          ## m/s on the way home
@export var climb_rate := 4.0             ## m/s
@export var descent_rate := 2.2           ## m/s, slowing to a touchdown
@export var safe_height := 20.0           ## metres above the home deck
@export var orbit_speed := 4.5            ## m/s along the circle
@export var orbit_min_radius := 7.0
@export var orbit_max_radius := 32.0
@export var override_threshold := 0.35    ## stick deflection that cancels

var mode: int = Mode.OFF
var phase: int = Phase.CLIMB
var active: bool:
	get:
		return mode != Mode.OFF

var orbit_target: Node3D = null
var orbit_radius := 14.0

var _drone: Drone
var _yaw_cmd := 0.0
var _orbit_angle := 0.0
var _orbit_height := 0.0
var _home_yaw := 0.0
var _settled := 0.0


func _ready() -> void:
	_drone = get_parent() as Drone
	if _drone:
		_drone.autopilot = self


func engage_return_home() -> void:
	if _drone == null:
		return
	mode = Mode.RETURN_HOME
	phase = Phase.CLIMB
	_home_yaw = _yaw_of(_drone.start_transform.basis)
	_settled = 0.0
	Sim.toast.emit("AUTOPILOT: RETURNING TO THE VAN  %.0f m" % _drone.distance_to_home(),
		Sim.Severity.CAUTION)
	Sfx.play("ui_switch", -4.0, 0.9)
	mode_changed.emit(mode)


func engage_orbit(target: Node3D) -> void:
	if _drone == null or target == null:
		return
	orbit_target = target
	var flat := _flat(_drone.global_position - target.global_position)
	orbit_radius = clampf(flat.length(), orbit_min_radius, orbit_max_radius)
	_orbit_angle = atan2(flat.y, flat.x)
	_orbit_height = _drone.global_position.y
	mode = Mode.ORBIT
	var name_text := (target as Detectable).label if target is Detectable else "target"
	Sim.toast.emit("AUTOPILOT: ORBITING %s  r %.0f m" % [name_text.to_upper(),
		orbit_radius], Sim.Severity.INFO)
	Sfx.play("ui_switch", -4.0, 1.1)
	mode_changed.emit(mode)


func cancel(reason: String) -> void:
	if mode == Mode.OFF:
		return
	mode = Mode.OFF
	orbit_target = null
	if reason != "":
		Sim.toast.emit("AUTOPILOT OFF  -  %s" % reason, Sim.Severity.INFO)
	mode_changed.emit(mode)


## Status line for the HUD.
func status_text() -> String:
	match mode:
		Mode.RETURN_HOME:
			return "RTH  %s  %.0f m" % [PHASE_NAMES[phase], _drone.distance_to_home()]
		Mode.ORBIT:
			var label := "TARGET"
			if orbit_target is Detectable:
				label = (orbit_target as Detectable).label.to_upper().left(22)
			return "ORBIT  %s  r %.0f m" % [label, orbit_radius]
	return ""


## The velocity the aircraft should fly this tick. Called by the drone.
func velocity_command() -> Vector3:
	if _pilot_override():
		cancel("PILOT OVERRIDE")
		return Vector3.ZERO
	match mode:
		Mode.RETURN_HOME:
			return _return_home()
		Mode.ORBIT:
			return _orbit()
	return Vector3.ZERO


func yaw_command() -> float:
	return _yaw_cmd


# ---------------------------------------------------------------- modes

func _return_home() -> Vector3:
	var pos := _drone.global_position
	var home := Sim.home_position
	var to_home := _flat(home - pos)
	var distance := to_home.length()
	var cruise_alt := home.y + safe_height
	var cmd := Vector3.ZERO

	match phase:
		Phase.CLIMB:
			# Straight up first: the way home may run through the city.
			cmd.y = climb_rate if pos.y < cruise_alt - 0.4 else 0.0
			_face(Vector3(to_home.x, 0.0, to_home.y))
			if pos.y >= cruise_alt - 0.4 or distance < 4.0:
				phase = Phase.TRANSIT
		Phase.TRANSIT:
			# Slow down on the approach rather than overshooting the deck.
			var speed := minf(cruise_speed, distance * 0.55)
			var dir := to_home.normalized() if distance > 0.01 else Vector2.ZERO
			cmd = Vector3(dir.x, 0.0, dir.y) * speed
			cmd.y = clampf((cruise_alt - pos.y) * 1.2, -2.0, 2.0)
			_face(Vector3(dir.x, 0.0, dir.y))
			if distance < 0.8 and _drone.ground_speed() < 1.2:
				phase = Phase.DESCEND
		Phase.DESCEND:
			# Hold station over the deck and come straight down, turning to
			# face the way it launched so it lands exactly as it took off.
			cmd = Vector3(to_home.x, 0.0, to_home.y) * 1.6
			cmd = cmd.limit_length(2.0)
			var height := pos.y - home.y
			cmd.y = -descent_rate if height > 2.0 else -0.7
			_face_yaw(_home_yaw)
			if height < 0.35 and absf(_drone.vertical_speed()) < 0.25:
				_settled += get_physics_process_delta_time()
				if _settled > 0.4:
					cancel("")
					if _drone.payload:
						_drone.payload.reload()
					if _drone.damage:
						_drone.damage.repair()
					Sim.toast.emit("LANDED ON THE VAN  -  REPAIRED AND RELOADED",
						Sim.Severity.INFO)
					Sfx.play("marker_drop", -6.0, 0.9)
			else:
				_settled = 0.0
	return cmd


func _orbit() -> Vector3:
	if orbit_target == null or not is_instance_valid(orbit_target):
		cancel("TARGET LOST")
		return Vector3.ZERO
	var delta := get_physics_process_delta_time()
	var centre := orbit_target.global_position
	var pos := _drone.global_position

	_orbit_angle += orbit_speed / orbit_radius * delta
	var want := Vector3(centre.x + cos(_orbit_angle) * orbit_radius, _orbit_height,
		centre.z + sin(_orbit_angle) * orbit_radius)
	# Tangential velocity along the circle, plus a correction that pulls the
	# aircraft back onto it - so it stays on the ring even after a wall or a
	# gust has pushed it off.
	var tangent := Vector3(-sin(_orbit_angle), 0.0, cos(_orbit_angle)) * orbit_speed
	var cmd := tangent + (want - pos) * 1.4
	cmd = cmd.limit_length(orbit_speed * 2.0)

	var to_target := centre - pos
	_face(Vector3(to_target.x, 0.0, to_target.z))
	# Hold the gimbal on the target so the payload watches it all the way round.
	var flat_dist := _flat(to_target).length()
	_drone.gimbal_pitch = clampf(rad_to_deg(atan2(to_target.y, flat_dist)), -80.0, 20.0)
	return cmd


# -------------------------------------------------------------- helpers

func _pilot_override() -> bool:
	for action in ["pitch_up", "pitch_down", "roll_left", "roll_right",
			"yaw_left", "yaw_right", "throttle_up", "throttle_down"]:
		if Input.get_action_strength(action) > override_threshold:
			return true
	return false


func _face(direction: Vector3) -> void:
	if direction.length_squared() < 0.0001:
		_yaw_cmd = 0.0
		return
	_face_yaw(atan2(-direction.x, -direction.z))


func _face_yaw(target_yaw: float) -> void:
	var error := wrapf(target_yaw - _yaw_of(_drone.global_basis), -PI, PI)
	_yaw_cmd = clampf(error * 2.4, -1.7, 1.7)


static func _yaw_of(basis: Basis) -> float:
	var fwd := -basis.z
	return atan2(-fwd.x, -fwd.z)


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
