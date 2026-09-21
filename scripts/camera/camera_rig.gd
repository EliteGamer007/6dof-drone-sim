class_name CameraRig
extends Node3D
## Flat-screen camera rig (keyboard / gamepad testing path).
##
## One camera is moved between mounts rather than several cameras being
## switched, so the post-process quad, the auto-gain state and the reticle only
## ever exist once.
##
## Three views, cycled with RB / Back / C:
##   CHASE - the standard following shot, far enough back to fly by
##   CLOSE - tight over-the-shoulder, where the airframe reads clearly
##   FPV   - bolted to the nose, wide and tilted, the way an FPV quad flies

enum View { CHASE, CLOSE, FPV }

const VIEW_NAMES := ["CHASE", "CLOSE FOLLOW", "FPV NOSE CAM"]

@export var chase_distance := 2.4
@export var chase_height := 0.85
@export var close_distance := 0.82
@export var close_height := 0.22
@export var close_shoulder := 0.17     ## sideways offset so the drone is not dead centre

## Field of view per view. FPV runs wide because that is what the lens on a
## real FPV quad does, and the distortion is most of why the footage feels fast.
const VIEW_FOV := [78.0, 46.0, 104.0]

var view: View = View.CHASE
var camera: Camera3D
var vision: VisionPost

var _drone: Drone
var _zoom := 1.0
var _spring: SpringArm3D
var _shake := 0.0
var _shake_time := 0.0
var _shake_power := 0.0


func setup(drone: Drone) -> void:
	_drone = drone


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "PayloadCamera"
	camera.fov = VIEW_FOV[view]
	camera.near = 0.03
	camera.far = 1600.0
	camera.current = true
	add_child(camera)

	vision = VisionPost.new()
	vision.name = "VisionPost"
	camera.add_child(vision)

	_spring = SpringArm3D.new()
	_spring.name = "ChaseArm"
	_spring.spring_length = chase_distance
	_spring.margin = 0.22
	add_child(_spring)

	Sim.camera_shake.connect(_on_camera_shake)


func _process(delta: float) -> void:
	if _drone == null or not is_instance_valid(_drone):
		return
	_handle_input(delta)

	_shake_time = maxf(_shake_time - delta, 0.0)

	match view:
		View.CHASE:
			_update_follow(delta, chase_distance, chase_height, 0.0, 16.0)
		View.CLOSE:
			_update_follow(delta, close_distance, close_height, close_shoulder, 22.0)
		View.FPV:
			_update_fpv(delta)

	_apply_shake(delta)

	var target_fov: float = VIEW_FOV[view] / _zoom
	camera.fov = lerpf(camera.fov, target_fov, clampf(delta * 8.0, 0.0, 1.0))


func _handle_input(delta: float) -> void:
	if Input.is_action_just_pressed("switch_camera"):
		view = ((view + 1) % View.size()) as View
		Sfx.play("ui_switch", -7.0)
		Sim.toast.emit("VIEW: %s" % VIEW_NAMES[view], Sim.Severity.INFO)
	if Input.is_action_pressed("zoom_in"):
		_zoom = clampf(_zoom + delta * 1.6, 1.0, 4.0)
	if Input.is_action_pressed("zoom_out"):
		_zoom = clampf(_zoom - delta * 1.6, 1.0, 4.0)


## Chase and close are the same shot at two distances: a spring arm behind the
## aircraft's heading, so a wall between the camera and the drone pulls the
## camera in instead of clipping through it.
func _update_follow(delta: float, distance: float, height: float,
		shoulder: float, follow_rate: float) -> void:
	var yaw := _drone.heading_degrees()
	var basis := Basis(Vector3.UP, deg_to_rad(-yaw))
	_spring.global_position = (_drone.global_position + Vector3.UP * height
		+ basis * Vector3(shoulder, 0.0, 0.0))
	_spring.global_basis = basis
	# Backing off as speed builds is what makes a follow shot read as fast.
	_spring.spring_length = distance * (1.0 + _drone.ground_speed() * 0.03)

	var desired := _spring.global_position + basis * Vector3(0.0, 0.0, _spring.get_hit_length())

	# Smooth the *offset* from the aircraft, not the world position. Chasing
	# the world position meant every translation - strafe, reverse, climb -
	# dragged the camera behind and then snapped it back, which is the laggy
	# feel. This way the rig tracks the aircraft rigidly and only the shape of
	# the shot eases, so sideways motion is as crisp as forward motion.
	var anchor := _drone.global_position
	var current_offset := camera.global_position - anchor
	var wanted_offset := desired - anchor
	current_offset = current_offset.lerp(wanted_offset,
		clampf(delta * follow_rate, 0.0, 1.0))
	camera.global_position = anchor + current_offset

	# A small lead so the camera looks where it is going. Kept short: a long
	# lead swings the whole frame every time the stick moves.
	var look_at_point := _drone.global_position + _drone.linear_velocity * 0.05
	camera.look_at(look_at_point, Vector3.UP)


## Hard-mounted to the nose. Unlike the chase views this one inherits the
## airframe's lean, so accelerating drops the horizon and braking lifts it -
## the single cue that makes FPV footage feel like flying rather than sliding.
func _update_fpv(delta: float) -> void:
	var mount := _drone.camera_mount
	if mount == null:
		return
	var yaw := deg_to_rad(-_drone.heading_degrees())
	var lean := _drone.body_lean()

	var basis := Basis(Vector3.UP, yaw)
	basis = basis * Basis(Vector3.RIGHT, lean.x + deg_to_rad(_drone.gimbal_pitch))
	basis = basis * Basis(Vector3.FORWARD, lean.y)

	# Frame vibration: small, throttle-dependent, and it settles to nothing in a
	# hover. Any more than this and it reads as a broken camera.
	_shake = lerpf(_shake, _drone.throttle_command * 0.0016
		+ _drone.ground_speed() * 0.00022, clampf(delta * 6.0, 0.0, 1.0))
	var t := Time.get_ticks_msec() * 0.001
	basis = basis * Basis.from_euler(Vector3(
		sin(t * 61.0) * _shake, sin(t * 47.0) * _shake, sin(t * 53.0) * _shake))

	camera.global_position = mount.global_position
	camera.global_basis = basis


## Blast shake, applied after the view has positioned the camera so it works
## identically in all three - including FPV, where it reads as the airframe
## being hit by the pressure wave.
func _on_camera_shake(strength: float) -> void:
	_shake_power = maxf(_shake_power, strength)
	_shake_time = maxf(_shake_time, 0.7 * strength)


func _apply_shake(_delta: float) -> void:
	if _shake_time <= 0.0:
		_shake_power = 0.0
		return
	var amount := _shake_power * _shake_time * 0.32
	var t := Time.get_ticks_msec() * 0.001
	camera.global_position += Vector3(
		sin(t * 53.0) * amount * 0.22,
		sin(t * 71.0) * amount * 0.18,
		sin(t * 61.0) * amount * 0.22)
	camera.global_basis = camera.global_basis * Basis.from_euler(Vector3(
		sin(t * 67.0) * amount * 0.04,
		sin(t * 59.0) * amount * 0.04,
		sin(t * 73.0) * amount * 0.05))


func view_name() -> String:
	return VIEW_NAMES[view]
