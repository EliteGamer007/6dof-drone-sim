class_name Drone
extends RigidBody3D
## Quadrotor flight model, airframe visuals and payload mounts.
##
## Two flight modes:
##   STABILIZED - attitude (angle) mode with altitude hold and position brake,
##                which is how a camera drone actually behaves.
##   ACRO       - rate mode, no self-levelling, for the "manual" demo.
##
## Everything except the airframe mesh is built in code so the scene file stays
## a single node and the rotor geometry always matches the flight model.

signal collided(impact_speed: float)
signal battery_changed(percent: float)

const UP := Vector3.UP
const GRAVITY := 9.81

@export_group("Airframe")
@export var body_scene: PackedScene
@export var body_scale := 0.052
@export var body_offset := Vector3(-0.027, -0.056, 0.039)
@export var body_rotation_degrees := Vector3.ZERO
@export var arm_length := 0.13
@export var dry_mass := 0.90                       ## kg, DJI FPV class

@export_group("Flight tuning")
@export var max_total_thrust := 30.0               ## N, ~3.4:1 thrust/weight
@export var max_tilt_degrees := 35.0
@export var max_climb_rate := 5.0                  ## m/s in stabilized mode
@export var max_yaw_rate_degrees := 160.0
@export var acro_rate_degrees := 320.0
@export var attitude_p := 46.0
@export var attitude_d := 9.5
@export var rate_p := 26.0
@export var inertia_tensor := Vector3(0.020, 0.032, 0.020)
@export var brake_gain := 2.1                      ## position-hold aggressiveness
@export var body_drag := 0.42                      ## quadratic drag coefficient


# ------------------------------------------------------------------ runtime

var battery_percent := 100.0
var battery_voltage := 25.2
var motor_health := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
var motor_output := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var gimbal_pitch := -12.0                          ## degrees, operator controlled
var throttle_command := 0.0
var spotlight_on := false
var precision := false
var armed := true
var total_distance := 0.0
var max_altitude := 0.0
var obstacle_assist_active := false

var start_transform: Transform3D
var _hold_altitude := 0.0
var _holding_altitude := false
var _last_position := Vector3.ZERO
var _rotor_markers: Array[Node3D] = []
var _prop_discs: Array[MeshInstance3D] = []
var _nav_lights: Array[OmniLight3D] = []
var _low_battery_warned := false

var gimbal: Node3D
var camera_mount: Node3D
var spotlight: SpotLight3D
var engine_sound: AudioStreamPlayer3D
var rotor_wash: GPUParticles3D
var proximity: ProximityArray
var gas_sensor: GasSensor
var detector: TargetDetector
var trail: GasTrail
var payload: PayloadBay
var damage: DamageModel                   ## set by the DamageModel child


# ---------------------------------------------------------------- lifecycle

func _ready() -> void:
	mass = dry_mass
	inertia = inertia_tensor
	can_sleep = false
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 6
	linear_damp = 0.0
	angular_damp = 0.0
	gravity_scale = 0.0
	axis_lock_angular_x = true
	axis_lock_angular_z = true

	_build_collision()
	_build_airframe()
	_build_rotors()
	_build_nav_lights()
	_build_gimbal()
	_build_audio()
	_build_rotor_wash()
	_build_sensors()

	start_transform = global_transform
	_last_position = global_position
	_hold_altitude = global_position.y
	Sim.drone = self
	Sim.home_position = global_position

	# The motors and battery are warm - the drone shows up on its own thermal
	# feed reflections and, more usefully, on a second drone's camera.
	Hazards.register_heat(self, 9.0, 0.4)

	body_entered.connect(_on_body_entered)
	flight_model = int(Sim.settings.get("flight_model", FlightModel.ARCADE))
	Sim.settings_changed.connect(func():
		set_flight_model(int(Sim.settings.get("flight_model", FlightModel.ARCADE))))

	engine_sound.play()


func _exit_tree() -> void:
	Hazards.unregister(self)


# ------------------------------------------------------------ construction

func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	# The prop discs are the widest part; the hull is what actually strikes.
	shape.size = Vector3(arm_length * 1.9, 0.09, arm_length * 1.9)
	col.shape = shape
	col.name = "Hull"
	add_child(col)


func _build_gimbal() -> void:
	gimbal = Node3D.new()
	gimbal.name = "Gimbal"
	gimbal.position = Vector3(0.0, -0.012, -0.075)
	add_child(gimbal)

	camera_mount = Node3D.new()
	camera_mount.name = "CameraMount"
	camera_mount.position = Vector3(0.0, 0.0, -0.03)
	gimbal.add_child(camera_mount)

	spotlight = SpotLight3D.new()
	spotlight.name = "Spotlight"
	spotlight.light_color = Color(0.95, 0.97, 1.0)
	spotlight.light_energy = 12.0
	spotlight.spot_range = 42.0
	spotlight.spot_angle = 26.0
	spotlight.spot_angle_attenuation = 0.9
	spotlight.spot_attenuation = 1.2
	spotlight.shadow_enabled = true
	spotlight.light_volumetric_fog_energy = 2.0
	spotlight.visible = false
	gimbal.add_child(spotlight)


func _build_audio() -> void:
	engine_sound = AudioStreamPlayer3D.new()
	engine_sound.name = "EngineSound"
	var stream := load("res://assets/audio/quadcopter_loop.mp3")
	if stream == null:
		stream = load("res://assets/audio/rotor_loop.wav")
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	elif stream is AudioStreamMP3:
		stream.loop = true
	engine_sound.stream = stream
	engine_sound.volume_db = -8.0
	engine_sound.unit_size = 4.0
	engine_sound.max_distance = 90.0
	add_child(engine_sound)


func _build_rotor_wash() -> void:
	var ramp := Vfx.ramp([
		Color(0.80, 0.75, 0.66, 0.0),
		Color(0.80, 0.75, 0.66, 0.36),
		Color(0.80, 0.75, 0.66, 0.0),
	], [0.0, 0.25, 1.0])

	rotor_wash = GPUParticles3D.new()
	rotor_wash.name = "RotorWash"
	rotor_wash.amount = 130
	rotor_wash.lifetime = 1.5
	rotor_wash.local_coords = false
	rotor_wash.visibility_aabb = AABB(Vector3(-6.0, -6.0, -6.0), Vector3(12.0, 12.0, 12.0))
	rotor_wash.emitting = false

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.42
	pm.emission_ring_inner_radius = 0.1
	pm.emission_ring_height = 0.05
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 62.0
	pm.initial_velocity_min = 1.4
	pm.initial_velocity_max = 3.6
	pm.gravity = Vector3(0.0, 0.9, 0.0)
	pm.damping_min = 1.2
	pm.damping_max = 2.6
	pm.scale_min = 0.5
	pm.scale_max = 1.6
	pm.color_ramp = ramp
	rotor_wash.process_material = pm
	rotor_wash.draw_pass_1 = Vfx.quad(Vector2.ONE * 0.75)
	rotor_wash.material_override = Vfx.billboard_material(Vfx.soft_circle(64, 2.2), false)
	rotor_wash.position = Vector3(0.0, -0.1, 0.0)
	add_child(rotor_wash)


## Sensors, autopilot and payload bay. They are nodes in scenes/drone.tscn so
## the aircraft's structure can be seen and edited in the editor; anything the
## scene does not provide is built here, so a bare Drone.new() still works.
func _build_sensors() -> void:
	proximity = get_node_or_null("ProximityArray") as ProximityArray
	if proximity == null:
		proximity = ProximityArray.new()
		proximity.name = "ProximityArray"
		add_child(proximity)

	gas_sensor = get_node_or_null("GasSensor") as GasSensor
	if gas_sensor == null:
		gas_sensor = GasSensor.new()
		gas_sensor.name = "GasSensor"
		# Sampling head sits below the airframe, out of the prop wash.
		gas_sensor.position = Vector3(0.0, -0.09, 0.0)
		add_child(gas_sensor)

	detector = get_node_or_null("TargetDetector") as TargetDetector
	if detector == null:
		detector = TargetDetector.new()
		detector.name = "TargetDetector"
		add_child(detector)

	if autopilot == null:
		var ap := Autopilot.new()
		ap.name = "Autopilot"
		add_child(ap)           # registers itself as drone.autopilot

	if damage == null:
		var dm := DamageModel.new()
		dm.name = "DamageModel"
		add_child(dm)            # registers itself as drone.damage

	payload = get_node_or_null("PayloadBay") as PayloadBay
	if payload == null:
		payload = PayloadBay.new()
		payload.name = "PayloadBay"
		payload.position = Vector3(0.0, -0.14, 0.02)
		add_child(payload)

	trail = GasTrail.new()
	trail.drone = self
	add_child(trail)


func _build_airframe() -> void:
	if has_node("Airframe"):
		airframe = $Airframe
		_disable_shadow_casting_on_small_parts(airframe)
		return
	if body_scene == null:
		_build_placeholder_body()
		return
	var body := body_scene.instantiate()
	body.name = "Airframe"
	add_child(body)
	if body is Node3D:
		body.scale = Vector3.ONE * body_scale
		body.position = body_offset
		body.rotation_degrees = body_rotation_degrees
		_disable_shadow_casting_on_small_parts(body)
		airframe = body


## The imported airframe has 120+ small meshes; letting every one of them cast
## a shadow costs far more than it shows at this scale.
func _disable_shadow_casting_on_small_parts(node: Node) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	for child in node.get_children():
		_disable_shadow_casting_on_small_parts(child)


func _build_placeholder_body() -> void:
	var hull := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.11, 0.05, 0.19)
	hull.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.10, 0.12)
	mat.metallic = 0.5
	mat.roughness = 0.4
	hull.material_override = mat
	hull.name = "Airframe"
	add_child(hull)
	airframe = hull


func rotor_offsets() -> Array[Vector3]:
	var a := arm_length
	# X-configuration: 0 front-left, 1 front-right, 2 rear-right, 3 rear-left
	return [
		Vector3(-a, 0.022, -a),
		Vector3(a, 0.022, -a),
		Vector3(a, 0.022, a),
		Vector3(-a, 0.022, a),
	]


func _build_rotors() -> void:
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = 0.063
	disc_mesh.bottom_radius = 0.063
	disc_mesh.height = 0.004
	disc_mesh.radial_segments = 24
	disc_mesh.rings = 1

	var disc_mat := StandardMaterial3D.new()
	disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mat.albedo_color = Color(0.72, 0.76, 0.82, 0.16)
	disc_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	disc_mat.no_depth_test = false

	for i in 4:
		var marker := Node3D.new()
		marker.name = "Rotor%d" % i
		marker.position = rotor_offsets()[i]
		add_child(marker)
		_rotor_markers.append(marker)

		var disc := MeshInstance3D.new()
		disc.name = "PropDisc"
		disc.mesh = disc_mesh
		disc.material_override = disc_mat.duplicate()
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker.add_child(disc)
		_prop_discs.append(disc)


func _build_nav_lights() -> void:
	var offsets := rotor_offsets()
	# green forward, red aft - standard aviation convention
	var colors := [Color(0.2, 1.0, 0.3), Color(0.2, 1.0, 0.3),
		Color(1.0, 0.15, 0.15), Color(1.0, 0.15, 0.15)]
	for i in 4:
		var light := OmniLight3D.new()
		light.name = "NavLight%d" % i
		light.position = offsets[i] + Vector3(0.0, -0.012, 0.0)
		light.light_color = colors[i]
		# LED scale. These used to carry a 2.4 m range, which washed the whole
		# landing deck green whenever the aircraft was sitting on it.
		light.light_energy = 0.45
		light.omni_range = 0.85
		light.shadow_enabled = false
		add_child(light)
		_nav_lights.append(light)


# ------------------------------------------------------------------ physics

## Handling.
##
## Two flight models, picked in Settings (Esc -> Flight model):
##
##   ARCADE      The sticks command a velocity in the aircraft's own frame. It
##               goes where it is pointed and stops when the sticks centre;
##               strafe, climb and turn are independent and equally crisp.
##
##   FLIGHT SIM  The aircraft has a nose. The left stick points it - up and
##               down pitch the nose, left and right turn - and RT drives it
##               along wherever the nose is pointing, LT brakes. The right
##               stick climbs and slides directly. Momentum carries: let go of
##               the trigger and it coasts down to a hover instead of stopping
##               dead, the way a real aircraft does.
##
## Both are commanded-velocity models on top of the rigid body, so walls still
## stop the aircraft and neither can drift: no input means a zero command, and
## the body is brought to rest.
##
## Rendering never reads this state directly. The body moves at the physics
## rate; the screen draws at the display rate. Everything that follows the
## aircraft on screen reads the *interpolated* transform, and the few values
## the cameras need that are not part of a transform (lean, nose angle) are
## interpolated here, in body_lean() and view_pitch().

enum FlightModel { ARCADE, SIM }
const FLIGHT_MODEL_NAMES := ["ARCADE", "FLIGHT SIM"]

## Fine control near the centre of the stick, full authority at the edge.
const STICK_EXPO := 0.28

@export_group("Arcade handling")
@export var cruise_speed := 12.0          ## m/s horizontal
@export var climb_speed := 6.0            ## m/s vertical
@export var accel := 24.0                 ## m/s^2 toward the stick command
@export var brake_accel := 28.0           ## m/s^2 once the sticks centre
@export var vertical_accel := 20.0        ## m/s^2 on the climb axis
@export var turn_rate_degrees := 100.0
@export var turn_accel_degrees := 600.0   ## how fast the yaw rate itself changes
@export var max_bank_degrees := 20.0      ## visual limit on the airframe lean

@export_group("Flight sim handling")
@export var sim_max_speed := 18.0         ## m/s along the nose at full throttle
@export var sim_accel := 7.5              ## m/s^2 at full RT
@export var sim_brake := 15.0             ## m/s^2 at full LT
@export var sim_coast_drag := 1.8         ## m/s^2 with neither trigger held
@export var sim_pitch_rate_degrees := 55.0
@export var sim_max_pitch_degrees := 50.0
@export var sim_turn_rate_degrees := 80.0
@export var sim_climb_speed := 5.0        ## right stick up/down, direct
@export var sim_slide_speed := 4.0        ## right stick left/right, direct
@export var sim_max_bank_degrees := 32.0

var flight_model: int = FlightModel.ARCADE
var airframe: Node3D
var autopilot: Autopilot                  ## set by the Autopilot child, if any

var _yaw_rate := 0.0
var _last_velocity := Vector3.ZERO
var _smoothed_accel := Vector3.ZERO
var _lean := Vector2.ZERO                 ## x pitch, y roll, radians
var _lean_prev := Vector2.ZERO
var _sim_speed := 0.0
var _nose_pitch := 0.0                    ## radians, flight-sim mode only
var _nose_prev := 0.0


func _physics_process(delta: float) -> void:
	_lean_prev = _lean
	_nose_prev = _nose_pitch
	_read_discrete_inputs()

	if damage and damage.is_destroyed():
		# Motors cut. Nothing is commanded; the body falls under gravity until
		# the damage model launches the spare.
		_update_visuals(0.0, delta)
		_last_velocity = linear_velocity
		return

	precision = Input.is_action_pressed("precision_mode")
	var scale := 0.4 if precision else 1.0
	# A damaged aircraft has less thrust to give: top speed, climb and turn
	# all come down with it, so the pilot feels the damage, not just reads it.
	if damage:
		scale *= lerpf(0.4, 1.0, damage.thrust_factor())

	var command := Vector3.ZERO           # world-space velocity the sticks ask for
	var yaw_command := 0.0                # rad/s
	var horizontal_rate := accel
	var vertical_rate := vertical_accel

	if autopilot and autopilot.active:
		# The autopilot flies the aircraft through exactly the same command
		# path as the sticks, so it inherits the same smoothing and the same
		# collision behaviour - it cannot do anything a pilot could not.
		command = autopilot.velocity_command()
		yaw_command = autopilot.yaw_command()
		horizontal_rate = accel * 0.8
		_nose_pitch = move_toward(_nose_pitch, 0.0, delta)
		_sim_speed = Vector3(command.x, 0.0, command.z).length()
	elif flight_model == FlightModel.SIM:
		var sim := _sim_command(delta, scale)
		command = sim[0]
		yaw_command = sim[1]
		# The ramp lives in the throttle, so the velocity itself can follow
		# the command closely - that is what keeps it from feeling soft.
		horizontal_rate = 30.0
		vertical_rate = 16.0
	else:
		var arcade := _arcade_command(scale)
		command = arcade[0]
		yaw_command = arcade[1]
		horizontal_rate = accel if arcade[2] else brake_accel

	if bool(Sim.settings.get("obstacle_assist", false)):
		command = _apply_obstacle_assist(command)

	# Landing assist: descending onto a surface, the last couple of metres are
	# flown at a touchdown rate, the way a real flight controller does. So a
	# landing is never scored as a crash - that is kept for actual crashes.
	if command.y < -1.3:
		var agl := altitude_agl()
		if agl < 2.5:
			command.y = maxf(command.y,
				lerpf(-1.2, command.y, clampf((agl - 0.4) / 2.1, 0.0, 1.0)))

	var flat := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	flat = flat.move_toward(Vector3(command.x, 0.0, command.z), horizontal_rate * delta)
	var vy := move_toward(linear_velocity.y, command.y, vertical_rate * delta)
	linear_velocity = Vector3(flat.x, vy, flat.z)

	# Yaw rate ramps rather than snapping, so a turn starts and finishes
	# smoothly instead of the whole frame stepping round.
	_yaw_rate = move_toward(_yaw_rate, yaw_command,
		deg_to_rad(turn_accel_degrees) * delta)
	angular_velocity = Vector3(0.0, _yaw_rate, 0.0)

	_update_attitude(delta)

	var effort := clampf(command.length() / maxf(cruise_speed, 0.1), 0.0, 1.0)
	var thrust := mass * GRAVITY * (1.0 + effort * 0.6)
	throttle_command = thrust / max_total_thrust
	for i in 4:
		motor_output[i] = 0.35 + effort * 0.5
	_update_gimbal(delta)
	_update_visuals(thrust, delta)

	var travelled := global_position.distance_to(_last_position)
	total_distance += travelled
	max_altitude = maxf(max_altitude, altitude_agl())
	_last_position = global_position
	_last_velocity = linear_velocity


## Arcade: the left stick is a velocity in the aircraft's own frame.
## Returns [command, yaw_rate, stick_active].
func _arcade_command(scale: float) -> Array:
	var forward := _shape(Input.get_axis("pitch_down", "pitch_up"))
	var strafe := _shape(Input.get_axis("roll_left", "roll_right"))
	var lift := Input.get_action_strength("throttle_up") \
		- Input.get_action_strength("throttle_down")
	var turn := _shape(Input.get_axis("yaw_left", "yaw_right"))

	var stick := Vector3(strafe, 0.0, -forward)
	if stick.length() > 1.0:
		stick = stick.normalized()
	var command := Basis(UP, _current_yaw()) * stick * cruise_speed * scale
	command.y = lift * climb_speed * scale
	return [command, -turn * deg_to_rad(turn_rate_degrees) * scale,
		stick.length_squared() > 0.0001]


## Flight sim: the left stick points the nose, the triggers drive along it.
## Returns [command, yaw_rate].
func _sim_command(delta: float, scale: float) -> Array:
	# Stick up is nose up and stick right is turn right. Not inverted, on
	# purpose: this is a drone, not an aircraft yoke.
	var steer := _shape(Input.get_axis("roll_left", "roll_right"))
	var pitch_in := _shape(Input.get_axis("pitch_down", "pitch_up"))
	var rt := Input.get_action_strength("throttle_up")
	var lt := Input.get_action_strength("throttle_down")
	var vertical := _shape(Input.get_axis("gimbal_down", "gimbal_up"))
	var slide := _shape(Input.get_axis("yaw_left", "yaw_right"))

	var limit := deg_to_rad(sim_max_pitch_degrees)
	_nose_pitch = clampf(
		_nose_pitch + pitch_in * deg_to_rad(sim_pitch_rate_degrees) * delta,
		-limit, limit)

	if lt > 0.01:
		_sim_speed = move_toward(_sim_speed, 0.0, sim_brake * lt * delta)
	elif rt > 0.01:
		_sim_speed = move_toward(_sim_speed, sim_max_speed * rt * scale,
			sim_accel * delta)
	else:
		_sim_speed = move_toward(_sim_speed, 0.0, sim_coast_drag * delta)

	var heading := Basis(UP, _current_yaw())
	var nose := heading * Basis(Vector3.RIGHT, _nose_pitch) * Vector3.FORWARD

	# Momentum cannot build up against something solid. If the body is being
	# held back - a wall, the ground - the throttle speed is pulled down to
	# what it is actually achieving, so backing off does not launch it.
	var achieved := maxf(linear_velocity.dot(nose), 0.0)
	_sim_speed = minf(_sim_speed, achieved + 3.0)

	var command := nose * _sim_speed
	command += UP * vertical * sim_climb_speed * scale
	command += heading * Vector3.RIGHT * slide * sim_slide_speed * scale
	return [command, -steer * deg_to_rad(sim_turn_rate_degrees) * scale]


## Soft centre, full edge. Keyboard input is 0 or 1 and passes through intact.
func _shape(v: float) -> float:
	var a := absf(v)
	return signf(v) * (a * (1.0 - STICK_EXPO) + a * a * a * STICK_EXPO)


## Braking assist. Scales back only the part of the commanded velocity that is
## pointed at the nearest obstacle, so the aircraft still flies freely along
## the wall it is inspecting and simply refuses to be driven into it. Full
## authority at the caution ring, none at all by the critical ring.
func _apply_obstacle_assist(target: Vector3) -> Vector3:
	obstacle_assist_active = false
	if proximity == null or not is_instance_valid(proximity):
		return target
	var d := proximity.closest_distance
	if d > proximity.caution_distance:
		return target
	var into := proximity.closest_direction
	if into.length_squared() < 1e-4:
		return target
	into = into.normalized()
	var closing := target.dot(into)
	if closing <= 0.0:
		return target          # already flying away from it
	var allowed := clampf((d - proximity.critical_distance)
		/ maxf(proximity.caution_distance - proximity.critical_distance, 0.01),
		0.0, 1.0)
	obstacle_assist_active = true
	return target - into * closing * (1.0 - allowed)


## Airframe attitude. Pure animation: the collision body stays level, so none
## of this can tip the aircraft or push it off course.
##
## Arcade leans by the specific force the aircraft is pulling, the way a real
## multirotor has to tilt to accelerate. Flight sim points the airframe along
## the nose and banks into turns in proportion to speed.
func _update_attitude(delta: float) -> void:
	if airframe == null:
		return
	var heading := Basis(UP, _current_yaw())

	# The raw acceleration steps every time move_toward reaches its target,
	# so it is smoothed before anything is drawn from it. Leaning straight off
	# the raw value is what made the airframe twitch on a stick release.
	var raw := (linear_velocity - _last_velocity) / maxf(delta, 0.0001)
	_smoothed_accel = _smoothed_accel.lerp(raw, clampf(delta * 9.0, 0.0, 1.0))

	var want := Vector2.ZERO
	if flight_model == FlightModel.SIM and not (autopilot and autopilot.active):
		var bank_limit := deg_to_rad(sim_max_bank_degrees)
		want.x = _nose_pitch
		want.y = clampf(_yaw_rate * _sim_speed * 0.05, -bank_limit, bank_limit)
	else:
		var drag_trim := Vector3(linear_velocity.x, 0.0, linear_velocity.z) * 0.25
		var local := heading.inverse() * (_smoothed_accel + drag_trim)
		var limit := deg_to_rad(max_bank_degrees)
		want.x = clampf(atan2(local.z, GRAVITY) * 0.6, -limit, limit)
		want.y = clampf(atan2(-local.x, GRAVITY) * 0.6, -limit, limit)

	_lean = _lean.lerp(want, clampf(delta * 8.0, 0.0, 1.0))
	var wobble := _wobble()
	airframe.rotation.x = _lean.x + wobble.x
	airframe.rotation.z = _lean.y + wobble.y


## Uneven motors make the airframe hunt. Smooth in time, so it reads as a
## struggling aircraft rather than as noise - and it is in body_lean(), so the
## nose camera feels it too.
func _wobble() -> Vector2:
	if damage == null:
		return Vector2.ZERO
	var amount := damage.imbalance() * 0.14 + (1.0 - damage.integrity / 100.0) * 0.035
	if amount < 0.001:
		return Vector2.ZERO
	var t := Time.get_ticks_msec() * 0.001
	return Vector2(sin(t * 8.7) * amount, sin(t * 6.9 + 1.3) * amount)


## Airframe attitude for rendering, interpolated between physics ticks.
func body_lean() -> Vector2:
	return _lean_prev.lerp(_lean, Engine.get_physics_interpolation_fraction()) + _wobble()


## How far the chase camera should pitch with the aircraft: the nose angle in
## flight-sim mode, nothing in arcade. Interpolated, like body_lean().
func view_pitch() -> float:
	if flight_model != FlightModel.SIM:
		return 0.0
	return lerpf(_nose_prev, _nose_pitch, Engine.get_physics_interpolation_fraction())


func flight_model_name() -> String:
	return FLIGHT_MODEL_NAMES[flight_model]


## Throttle-driven airspeed in flight-sim mode, for the HUD.
func sim_airspeed() -> float:
	return _sim_speed


func set_flight_model(model: int) -> void:
	if model == flight_model:
		return
	flight_model = model
	# Hand over without a jolt: the new model starts from what the aircraft is
	# already doing rather than from rest.
	var heading := Basis(UP, _current_yaw())
	_sim_speed = maxf((heading * Vector3.FORWARD).dot(linear_velocity), 0.0)
	_nose_pitch = 0.0
	_nose_prev = 0.0


func _update_gimbal(delta: float) -> void:
	if autopilot and autopilot.active:
		pass                     # the autopilot holds the gimbal on its target
	elif flight_model == FlightModel.SIM:
		# The right stick flies the aircraft in this mode, so the payload
		# simply looks where the nose points, a few degrees down.
		gimbal_pitch = move_toward(gimbal_pitch, -6.0, 40.0 * delta)
	else:
		var tilt := Input.get_axis("gimbal_up", "gimbal_down")
		if absf(tilt) > 0.05:
			gimbal_pitch = clampf(gimbal_pitch - tilt * 55.0 * delta, -90.0, 32.0)
	if Input.is_action_just_pressed("gimbal_center"):
		gimbal_pitch = 0.0

	# Three-axis stabilisation: keep the payload level in world space and let
	# the operator own the tilt axis. This is why the FPV feed stays smooth.
	var yaw := _current_yaw()
	var target := Basis.from_euler(Vector3(deg_to_rad(gimbal_pitch), yaw, 0.0),
		EULER_ORDER_YXZ)
	var current := gimbal.global_basis.get_rotation_quaternion()
	var smoothed := current.slerp(target.get_rotation_quaternion(),
		clampf(delta * 16.0, 0.0, 1.0))
	gimbal.global_basis = Basis(smoothed)


func _current_yaw() -> float:
	var fwd := -global_basis.z
	if absf(fwd.x) < 1e-5 and absf(fwd.z) < 1e-5:
		fwd = global_basis.y   # pointing straight up/down, fall back
	return atan2(-fwd.x, -fwd.z)


# ----------------------------------------------------------------- visuals


func _update_visuals(thrust: float, delta: float) -> void:
	var load := clampf(thrust / max_total_thrust, 0.0, 1.0)

	for i in 4:
		var disc := _prop_discs[i]
		var spin := (2200.0 + motor_output[i] * 5200.0) * motor_health[i]
		disc.rotate_y(deg_to_rad(spin) * delta)
		var mat := disc.material_override as StandardMaterial3D
		mat.albedo_color.a = lerpf(0.06, 0.30, clampf(motor_output[i], 0.0, 1.0))

	var blink := fmod(Time.get_ticks_msec() / 1000.0, 1.4) < 0.12
	for i in 4:
		_nav_lights[i].light_energy = 1.1 if blink else 0.35

	# rotor wash kicks up dust only when we are low enough for it to matter
	var agl := altitude_agl()
	var wash := clampf(1.0 - agl / 2.6, 0.0, 1.0) * load
	rotor_wash.emitting = wash > 0.05
	rotor_wash.amount_ratio = clampf(wash, 0.05, 1.0)

	if engine_sound.playing:
		var target_pitch := 0.72 + load * 0.9 + linear_velocity.length() * 0.012
		engine_sound.pitch_scale = lerpf(engine_sound.pitch_scale, target_pitch,
			clampf(delta * 7.0, 0.0, 1.0))
		engine_sound.volume_db = lerpf(engine_sound.volume_db,
			lerpf(-14.0, -2.0, load), clampf(delta * 5.0, 0.0, 1.0))

	Sfx.set_wind_intensity(Hazards.current_wind().length() + linear_velocity.length() * 0.4)


# ------------------------------------------------------------------ queries

func altitude_agl() -> float:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		global_position, global_position + Vector3.DOWN * 400.0)
	params.exclude = [get_rid()]
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return global_position.y
	return global_position.y - hit.position.y


func ground_speed() -> float:
	return Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()


func vertical_speed() -> float:
	return linear_velocity.y


func heading_degrees() -> float:
	return fposmod(rad_to_deg(-_current_yaw()), 360.0)


func distance_to_home() -> float:
	return global_position.distance_to(Sim.home_position)


func attitude_degrees() -> Vector2:
	## x = pitch (nose up positive), y = roll (right wing down positive)
	var fwd := -global_basis.z
	var right := global_basis.x
	return Vector2(rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0))),
		rad_to_deg(asin(clampf(-right.y, -1.0, 1.0))))


# ------------------------------------------------------------------ actions

func _read_discrete_inputs() -> void:
	if Input.is_action_just_pressed("reset_drone"):
		reset_to_start()
	if Input.is_action_just_pressed("toggle_spotlight"):
		set_spotlight(not spotlight_on)
	if Input.is_action_just_pressed("toggle_avoidance"):
		Sim.set_setting("obstacle_assist", not Sim.settings.obstacle_assist)
		Sfx.play("ui_click")
		Sim.toast.emit("OBSTACLE ASSIST %s" %
			("ON" if Sim.settings.obstacle_assist else "OFF"), Sim.Severity.INFO)
	if Input.is_action_just_pressed("toggle_trail"):
		Sim.set_setting("gas_trail", not bool(Sim.settings.get("gas_trail", true)))
		Sfx.play("ui_click")
		Sim.toast.emit("AIR-SAMPLE TRAIL %s" %
			("ON" if Sim.settings.gas_trail else "OFF"), Sim.Severity.INFO)
	if Input.is_action_just_pressed("return_home") and autopilot:
		if autopilot.mode == Autopilot.Mode.RETURN_HOME:
			autopilot.cancel("RETURN HOME CANCELLED")
		else:
			autopilot.engage_return_home()
	if Input.is_action_just_pressed("orbit_poi") and autopilot:
		if autopilot.mode == Autopilot.Mode.ORBIT:
			autopilot.cancel("ORBIT ENDED")
		else:
			_engage_orbit()
	if Input.is_action_just_pressed("drop_supply") and payload:
		payload.drop()


## Orbit whatever the reticle is on, or failing that the contact the detector
## is focused on.
func _engage_orbit() -> void:
	var camera := get_viewport().get_camera_3d()
	var target: Node3D = null
	if camera:
		target = Detectable.under_reticle(get_tree(), camera.global_position,
			-camera.global_basis.z)
	if target == null and detector and is_instance_valid(detector.focused):
		target = detector.focused
	if target == null:
		Sim.toast.emit("ORBIT: PUT THE RETICLE ON A CONTACT FIRST", Sim.Severity.INFO)
		Sfx.play("ui_click", -8.0)
		return
	autopilot.engage_orbit(target)


func set_spotlight(on: bool) -> void:
	spotlight_on = on
	spotlight.visible = on
	Sfx.play("ui_click")


func bearing_to_home() -> int:
	var d := Sim.home_position - global_position
	return int(fposmod(rad_to_deg(atan2(d.x, -d.z)), 360.0))


func reset_to_start() -> void:
	global_transform = start_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_yaw_rate = 0.0
	_lean = Vector2.ZERO
	_lean_prev = Vector2.ZERO
	_sim_speed = 0.0
	_nose_pitch = 0.0
	_nose_prev = 0.0
	_last_velocity = Vector3.ZERO
	if autopilot:
		autopilot.cancel("")
	# Undo a crash: motors back on, gravity off, the tumble locked out again.
	gravity_scale = 0.0
	axis_lock_angular_x = true
	axis_lock_angular_z = true
	if damage:
		damage.repair()
	reset_physics_interpolation()
	motor_health = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	gimbal_pitch = -12.0
	if payload:
		payload.reload()
	_holding_altitude = false
	_low_battery_warned = false
	Sim.toast.emit("BACK ON THE VAN  -  AIRFRAME REPAIRED, KITS RELOADED",
		Sim.Severity.INFO)
	Sfx.play("ui_switch", -4.0)


func _on_body_entered(_body: Node) -> void:
	# The speed going *into* the contact. By the time this fires the solver
	# has already stopped the body, so its current velocity understates the hit.
	var speed := maxf(_last_velocity.length(), linear_velocity.length())
	if speed < 0.6:
		return
	Sfx.play("impact", clampf(-18.0 + speed * 1.6, -18.0, -2.0),
		randf_range(0.9, 1.1), 0.15)
	collided.emit(speed)
	if damage:
		damage.impact(speed)
