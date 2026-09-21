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


func _build_sensors() -> void:
	proximity = ProximityArray.new()
	proximity.name = "ProximityArray"
	add_child(proximity)

	gas_sensor = GasSensor.new()
	gas_sensor.name = "GasSensor"
	# Sampling head sits below the airframe, out of the prop wash.
	gas_sensor.position = Vector3(0.0, -0.09, 0.0)
	add_child(gas_sensor)

	detector = TargetDetector.new()
	detector.name = "TargetDetector"
	add_child(detector)

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

## Handling model.
##
## The sticks command a velocity, but the aircraft is not teleported onto it:
## it accelerates towards it at a finite rate, brakes harder than it
## accelerates, and banks by however much specific force it is pulling. So it
## carries momentum, leans into a turn and settles afterwards - while still
## going exactly where it is pointed and stopping dead when you let go. No
## uncommanded drift in any axis.
@export_group("Handling")
@export var cruise_speed := 12.0          ## m/s forward
@export var strafe_ratio := 0.78          ## sideways is slower than forward
@export var climb_speed := 5.0            ## m/s vertical
@export var accel := 12.0                 ## m/s^2 powering up
@export var brake_accel := 16.0           ## m/s^2 with the sticks centred
@export var vertical_accel := 9.0         ## m/s^2 on the climb axis
@export var turn_rate_degrees := 95.0
@export var turn_accel_degrees := 420.0   ## how fast the yaw rate itself changes
@export var max_bank_degrees := 26.0      ## visual limit on the airframe lean

var airframe: Node3D
var _yaw_rate := 0.0
var _last_velocity := Vector3.ZERO
var _lean := Vector2.ZERO                 ## x pitch, y roll, radians


func _physics_process(delta: float) -> void:
	_read_discrete_inputs()

	# Normal video-game layout, never inverted:
	#   W / S (left stick up/down)    forward / back
	#   A / D (left stick left/right) strafe
	#   Space / Shift (RT / LT)       up / down
	#   Q / E, arrow keys (right stick) turn
	var forward := Input.get_axis("pitch_down", "pitch_up")
	var strafe := Input.get_axis("roll_left", "roll_right")
	var lift := Input.get_action_strength("throttle_up") - Input.get_action_strength("throttle_down")
	var turn := Input.get_axis("yaw_left", "yaw_right")

	precision = Input.is_action_pressed("precision_mode")
	var scale := 0.4 if precision else 1.0

	var heading := Basis(UP, _current_yaw())
	var stick := Vector3(strafe * strafe_ratio, 0.0, -forward)
	if stick.length() > 1.0:
		stick = stick.normalized()
	var target := heading * stick * cruise_speed * scale
	if bool(Sim.settings.get("obstacle_assist", false)):
		target = _apply_obstacle_assist(target)

	# Accelerate at one rate, brake at a firmer one. A quad can always stop
	# harder than it can accelerate, and it is what makes this easy to fly.
	var flat := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var rate := accel if stick.length_squared() > 0.001 else brake_accel
	flat = flat.move_toward(target, rate * delta)

	var vy := move_toward(linear_velocity.y, lift * climb_speed * scale,
		vertical_accel * delta)
	linear_velocity = Vector3(flat.x, vy, flat.z)

	# Yaw rate ramps rather than snapping, so a turn starts and stops smoothly
	# instead of the whole airframe stepping sideways.
	_yaw_rate = move_toward(_yaw_rate,
		-turn * deg_to_rad(turn_rate_degrees) * scale,
		deg_to_rad(turn_accel_degrees) * delta)
	angular_velocity = Vector3(0.0, _yaw_rate, 0.0)

	_update_lean(heading, delta)

	var effort := clampf(target.length() / cruise_speed, 0.0, 1.0)
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


## Bank angle from specific force, the way a real multirotor works: the
## airframe tilts by exactly the angle whose horizontal thrust component
## produces the acceleration it is pulling, plus a standing tilt to hold
## against drag at speed. Pure animation - the collision body stays level, so
## none of this can tip the aircraft over or push it off course.
func _update_lean(heading: Basis, delta: float) -> void:
	if airframe == null:
		return
	var accel_world := (linear_velocity - _last_velocity) / maxf(delta, 0.0001)
	var drag_trim := Vector3(linear_velocity.x, 0.0, linear_velocity.z) * 0.30
	var local := heading.inverse() * (accel_world + drag_trim)

	var limit := deg_to_rad(max_bank_degrees)
	var want := Vector2(
		clampf(atan2(local.z, GRAVITY) * 0.65, -limit, limit),
		clampf(atan2(-local.x, GRAVITY) * 0.65, -limit, limit))
	_lean = _lean.lerp(want, clampf(delta * 7.0, 0.0, 1.0))
	airframe.rotation.x = _lean.x
	airframe.rotation.z = _lean.y


## Current airframe attitude in radians - read by the FPV camera so the nose
## cam inherits the lean.
func body_lean() -> Vector2:
	return _lean


func _update_gimbal(delta: float) -> void:
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
	if Input.is_action_just_pressed("return_home"):
		Sim.toast.emit("RTL BEARING %03d  %.0f m" %
			[bearing_to_home(), distance_to_home()], Sim.Severity.CAUTION)


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
	_last_velocity = Vector3.ZERO
	motor_health = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	gimbal_pitch = -12.0
	_holding_altitude = false
	_low_battery_warned = false
	Sim.toast.emit("AIRFRAME RESET - BACK ON THE VAN", Sim.Severity.INFO)
	Sfx.play("ui_switch", -4.0)


func _on_body_entered(_body: Node) -> void:
	var speed := linear_velocity.length()
	if speed < 0.6:
		return
	Sfx.play("impact", clampf(-18.0 + speed * 1.6, -18.0, -2.0),
		randf_range(0.9, 1.1), 0.15)
	collided.emit(speed)
	if speed > 4.5:
		# a hard strike can cost a motor - recoverable, but it shows up on the HUD
		var motor := randi() % 4
		motor_health[motor] = maxf(motor_health[motor] - 0.35, 0.25)
		Sim.alarm_raised.emit(Sim.Severity.WARNING,
			"PROP STRIKE - MOTOR %d DEGRADED" % (motor + 1))
