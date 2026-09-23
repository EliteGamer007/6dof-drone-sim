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
##   FPV   - on the nose, wide and tilted, the way an FPV quad flies
##
## Why it is built the way it is
##   The aircraft moves at the physics rate (60 Hz). The screen draws at the
##   display rate - 144 Hz on a gaming laptop. A camera that reads the raw body
##   position sees it stand still for a frame or two and then jump, and that
##   step is the jitter: invisible flying forward, because the motion is along
##   the view axis, and at its worst on a strafe or a climb, where the motion
##   runs across the frame.
##
##   So this rig reads only the *interpolated* transform, and it holds the
##   camera rigidly to it. Translation is never smoothed - smoothing it just
##   trades jitter for lag. The only thing that eases is the yaw of the shot,
##   which is what gives a chase camera its swing on a turn.

enum View { CHASE, CLOSE, FPV }

const VIEW_NAMES := ["CHASE", "CLOSE FOLLOW", "FPV NOSE CAM"]

@export var chase_distance := 2.6
@export var chase_height := 0.85
@export var close_distance := 0.9
@export var close_height := 0.26
@export var close_shoulder := 0.17     ## sideways offset so the drone is not dead centre
@export var yaw_follow := 7.0          ## how quickly the shot swings round behind a turn
@export var wall_margin := 0.25

## Field of view per view. FPV runs wide because that is what the lens on a
## real FPV quad does, and the distortion is most of why the footage feels fast.
const VIEW_FOV := [78.0, 50.0, 104.0]

var view: View = View.CHASE
var camera: Camera3D
var vision: VisionPost

var _drone: Drone
var _zoom := 1.0
var _cam_yaw := 0.0
var _cam_pitch := 0.0
var _arm := -1.0
var _lead := Vector3.ZERO
var _vibration := 0.0
var _shake_time := 0.0
var _shake_power := 0.0
var _initialised := false


func setup(drone: Drone) -> void:
	_drone = drone


func _ready() -> void:
	# This node is moved every rendered frame, not every physics tick, so it
	# must not be interpolated itself - it reads the aircraft's interpolated
	# transform instead.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

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

	Sim.camera_shake.connect(_on_camera_shake)


func _process(delta: float) -> void:
	if _drone == null or not is_instance_valid(_drone):
		return
	_handle_input(delta)
	_shake_time = maxf(_shake_time - delta, 0.0)

	var body := _drone.get_global_transform_interpolated()
	var yaw := _yaw_of(body.basis)
	if not _initialised:
		_cam_yaw = yaw
		_initialised = true

	match view:
		View.CHASE:
			_update_follow(delta, body.origin, yaw, chase_distance, chase_height, 0.0)
		View.CLOSE:
			_update_follow(delta, body.origin, yaw, close_distance, close_height,
				close_shoulder)
		View.FPV:
			_update_fpv(delta, yaw)

	_apply_shake()

	var target_fov: float = VIEW_FOV[view] / _zoom
	camera.fov = lerpf(camera.fov, target_fov, clampf(delta * 8.0, 0.0, 1.0))


func _handle_input(delta: float) -> void:
	if Input.is_action_just_pressed("switch_camera"):
		set_view(((view + 1) % View.size()) as View)
		Sfx.play("ui_switch", -7.0)
		Sim.toast.emit("VIEW: %s" % VIEW_NAMES[view], Sim.Severity.INFO)
	if Input.is_action_pressed("zoom_in"):
		_zoom = clampf(_zoom + delta * 1.6, 1.0, 4.0)
	if Input.is_action_pressed("zoom_out"):
		_zoom = clampf(_zoom - delta * 1.6, 1.0, 4.0)


func set_view(v: View) -> void:
	view = v
	_arm = -1.0          # re-measure the wall clearance for the new distance


## Chase and close: the same shot at two distances.
func _update_follow(delta: float, anchor: Vector3, yaw: float, distance: float,
		height: float, shoulder: float) -> void:
	# The yaw of the shot eases toward the aircraft's heading, which is the
	# swing on a turn. Nothing else here is smoothed.
	_cam_yaw = lerp_angle(_cam_yaw, yaw, clampf(delta * yaw_follow, 0.0, 1.0))
	# In flight-sim mode the shot rises and falls with the nose, so the view
	# shows where the aircraft is pointed rather than the ground under it.
	_cam_pitch = lerpf(_cam_pitch, _drone.view_pitch() * 0.45,
		clampf(delta * 5.0, 0.0, 1.0))
	var basis := Basis(Vector3.UP, _cam_yaw) * Basis(Vector3.RIGHT, _cam_pitch)

	var pivot := anchor + Vector3.UP * height + basis * Vector3(shoulder, 0.0, 0.0)
	var wanted := distance * (1.0 + _drone.ground_speed() * 0.02)

	# Wall clearance. Pulling in is immediate, so the camera can never end up
	# inside a building; letting back out eases, so leaving a wall does not pop
	# the shot.
	var clear := _clearance(pivot, basis * Vector3.BACK, wanted)
	if _arm < 0.0 or clear < _arm:
		_arm = clear
	else:
		_arm = lerpf(_arm, clear, clampf(delta * 3.0, 0.0, 1.0))

	camera.global_position = pivot + basis * Vector3(0.0, 0.0, _arm)

	# A short, smoothed lead: the camera looks slightly ahead of the aircraft
	# without the frame swinging every time the stick moves.
	_lead = _lead.lerp(_drone.linear_velocity * 0.05, clampf(delta * 5.0, 0.0, 1.0))
	var look := anchor + Vector3.UP * height * 0.35 + _lead
	if camera.global_position.distance_squared_to(look) > 0.0001:
		camera.look_at(look, Vector3.UP)


## How far the camera can sit back from the pivot before it meets geometry.
func _clearance(from: Vector3, direction: Vector3, length: float) -> float:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from,
		from + direction * (length + wall_margin))
	params.exclude = [_drone.get_rid()]
	params.collide_with_areas = false
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return length
	return maxf(from.distance_to(hit.position) - wall_margin, 0.2)


## On the nose. Unlike the chase views this one inherits the airframe's
## attitude, so accelerating drops the horizon and braking lifts it - the
## single cue that makes FPV footage feel like flying rather than sliding.
func _update_fpv(delta: float, yaw: float) -> void:
	var mount := _drone.camera_mount
	if mount == null:
		return
	var lean := _drone.body_lean()          # interpolated
	var pitch := lean.x + deg_to_rad(_drone.gimbal_pitch)
	var roll := lean.y
	if _drone.flight_model == Drone.FlightModel.ARCADE:
		# In arcade the lean is there to be read, not to swing the horizon on
		# every stick input, so the nose camera takes most of it but not all.
		pitch = lean.x * 0.6 + deg_to_rad(_drone.gimbal_pitch)
		roll = lean.y * 0.6

	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) \
		* Basis(Vector3.BACK, roll)

	# Frame vibration: small, speed-dependent, gone in a hover. Any more than
	# this and it reads as a broken camera.
	_vibration = lerpf(_vibration, _drone.ground_speed() * 0.00018,
		clampf(delta * 6.0, 0.0, 1.0))
	var t := Time.get_ticks_msec() * 0.001
	basis = basis * Basis.from_euler(Vector3(
		sin(t * 61.0) * _vibration, sin(t * 47.0) * _vibration,
		sin(t * 53.0) * _vibration))

	camera.global_transform = Transform3D(basis,
		mount.get_global_transform_interpolated().origin)


static func _yaw_of(basis: Basis) -> float:
	var fwd := -basis.z
	return atan2(-fwd.x, -fwd.z)


## Blast shake, applied after the view has positioned the camera so it works
## identically in all three - including FPV, where it reads as the airframe
## being hit by the pressure wave.
func _on_camera_shake(strength: float) -> void:
	_shake_power = maxf(_shake_power, strength)
	_shake_time = maxf(_shake_time, 0.7 * strength)


func _apply_shake() -> void:
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
