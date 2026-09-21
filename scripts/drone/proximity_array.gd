class_name ProximityArray
extends Node3D
## Obstacle-detection ring, modelled on the ToF/vision sensors a real inspection
## drone carries: eight lateral beams plus up and down.
##
## Feeds three things: the HUD proximity ring, the audible closing tone, and the
## flight controller's braking assist.

signal obstacle_critical(direction: Vector3, distance: float)

const SECTORS := 8

@export var range_m := 9.0
@export var caution_distance := 3.2
@export var critical_distance := 1.4
@export var vertical_range := 6.0

var distances := PackedFloat32Array()      ## per lateral sector, metres (range_m = clear)
var distance_up := 0.0
var distance_down := 0.0
var closest_distance := 999.0
var closest_direction := Vector3.ZERO

var _beep_accumulator := 0.0
var _parent_body: RigidBody3D


func _ready() -> void:
	distances.resize(SECTORS)
	for i in SECTORS:
		distances[i] = range_m
	_parent_body = get_parent() as RigidBody3D


func _physics_process(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	if _parent_body:
		exclude.append(_parent_body.get_rid())

	closest_distance = 999.0
	closest_direction = Vector3.ZERO

	var yaw := global_basis.get_euler().y
	for i in SECTORS:
		var angle := TAU * float(i) / float(SECTORS)
		# sector 0 is straight ahead, then clockwise
		var dir := Basis(Vector3.UP, yaw + angle) * Vector3.FORWARD
		var d := _cast(space, dir, range_m, exclude)
		distances[i] = d
		if d < closest_distance:
			closest_distance = d
			closest_direction = dir

	distance_up = _cast(space, Vector3.UP, vertical_range, exclude)
	distance_down = _cast(space, Vector3.DOWN, vertical_range, exclude)

	_update_audio(delta)

	if closest_distance < critical_distance:
		obstacle_critical.emit(closest_direction, closest_distance)


func _cast(space: PhysicsDirectSpaceState3D, dir: Vector3, length: float,
		exclude: Array[RID]) -> float:
	var params := PhysicsRayQueryParameters3D.create(
		global_position, global_position + dir * length)
	params.exclude = exclude
	params.collide_with_areas = false
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return length
	return global_position.distance_to(hit.position)


func _update_audio(delta: float) -> void:
	if closest_distance > caution_distance:
		_beep_accumulator = 0.0
		return
	# The closer the obstacle, the faster the tone - a parking sensor.
	var t := clampf((closest_distance - critical_distance)
		/ maxf(caution_distance - critical_distance, 0.01), 0.0, 1.0)
	var interval := lerpf(0.09, 0.55, t)
	_beep_accumulator += delta
	if _beep_accumulator >= interval:
		_beep_accumulator = 0.0
		Sfx.play("proximity", lerpf(-6.0, -18.0, t), lerpf(1.35, 0.95, t))


## Unit-ish push direction away from nearby geometry, used by the flight
## controller's braking assist. Length scales with how urgent the avoidance is.
func avoidance_vector() -> Vector3:
	var push := Vector3.ZERO
	for i in SECTORS:
		var d := distances[i]
		if d >= caution_distance:
			continue
		var angle := TAU * float(i) / float(SECTORS)
		var yaw := global_basis.get_euler().y
		var dir := Basis(Vector3.UP, yaw + angle) * Vector3.FORWARD
		var urgency := 1.0 - clampf((d - critical_distance * 0.5)
			/ maxf(caution_distance - critical_distance * 0.5, 0.01), 0.0, 1.0)
		push -= dir * urgency
	return push.limit_length(1.0)


## 0 clear .. 1 touching, per lateral sector - what the HUD ring draws.
func sector_pressure(i: int) -> float:
	if i < 0 or i >= SECTORS:
		return 0.0
	return 1.0 - clampf(distances[i] / range_m, 0.0, 1.0)
