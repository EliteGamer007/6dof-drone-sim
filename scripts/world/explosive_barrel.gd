@tool
class_name ExplosiveBarrel
extends Node3D
## A fuel or gas drum the operator can set off from the aircraft.
##
## This is the one thing in the simulation the operator can *do* to the site
## rather than only observe, so it is deliberately a deliberate act: B, aimed,
## one barrel at a time. Each one detonates once and is then spent.
##
## Each drum is an instance of scenes/props/explosive_drum.tscn under
## ExplosiveDrums in the main scene. It shows its model in the editor and sits
## itself on the terrain, so a drum can be dragged anywhere.

signal detonated(barrel: ExplosiveBarrel)

const GROUP := "explosive"

@export_enum("Barrel_01", "Barrel_02", "barrel_03", "propane_tank", "small_lpg_tank")
var model_name := "Barrel_01":
	set(v):
		model_name = v
		_rebuild_body()
@export var power := 1.0                 ## scales blast radius, light and heat

var spent := false

var _body: Node3D


func _ready() -> void:
	set_notify_transform(true)
	_rebuild_body()
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	# Warm drums in the afternoon sun: they show on the thermal channel before
	# anyone sets them off, which is the cue that they are worth avoiding.
	Hazards.register_heat_capsule(self, Vector3(0.0, 0.15, 0.0),
		Vector3(0.0, 0.85, 0.0), 0.34, 4.5, false, 0.2, Hazards.HeatKind.GENERIC)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_rebuild_body.call_deferred()


func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		Hazards.unregister(self)


## The model, seated on the ground under the drum. Never saved into the scene.
func _rebuild_body() -> void:
	if not is_inside_tree() or spent:
		return
	if _body and is_instance_valid(_body):
		remove_child(_body)
		_body.queue_free()
	var g := Terrain.height(global_position.x, global_position.z) - global_position.y
	_body = BuildKit.model(self, model_name, Vector3(0.0, g, 0.0), 0.0, 1.0, true)
	if _body:
		_body.set_meta(&"generated", true)


## Sets the barrel off. Safe to call twice - the second call does nothing,
## which matters because the detonate key can be held down.
func detonate() -> void:
	if spent:
		return
	spent = true
	remove_from_group(GROUP)
	Hazards.unregister(self)

	if _body and is_instance_valid(_body):
		_body.queue_free()
		_body = null

	var blast := Explosion.new()
	blast.name = "Explosion"
	blast.power = power
	# Same parent as the barrel, so the barrel's local position is the right
	# one. Placed before it enters the tree: set afterwards, the interpolated
	# first frame would streak in from the parent's origin.
	blast.position = position + Vector3.UP * (
		Terrain.height(global_position.x, global_position.z) - global_position.y)
	# Parented to the world rather than to the barrel, so the barrel can go
	# away while the fire it started keeps burning.
	get_parent().add_child(blast)
	blast.reset_physics_interpolation()

	detonated.emit(self)


## The nearest live barrel to a point, or null. Used by the aircraft when the
## operator presses detonate without anything under the reticle.
static func nearest(tree: SceneTree, point: Vector3,
		max_range := 70.0) -> ExplosiveBarrel:
	var best: ExplosiveBarrel = null
	var best_d := max_range
	for node in tree.get_nodes_in_group(GROUP):
		var barrel := node as ExplosiveBarrel
		if barrel == null or barrel.spent or not is_instance_valid(barrel):
			continue
		var d := barrel.global_position.distance_to(point)
		if d < best_d:
			best_d = d
			best = barrel
	return best


## The live barrel closest to the line the reticle is pointing down. Aiming
## beats proximity, so the operator can pick one barrel out of a cluster.
static func under_reticle(tree: SceneTree, origin: Vector3, direction: Vector3,
		max_range := 120.0) -> ExplosiveBarrel:
	var best: ExplosiveBarrel = null
	var best_miss := INF
	for node in tree.get_nodes_in_group(GROUP):
		var barrel := node as ExplosiveBarrel
		if barrel == null or barrel.spent or not is_instance_valid(barrel):
			continue
		var to_target := barrel.global_position - origin
		var along := to_target.dot(direction)
		if along <= 0.5 or along > max_range:
			continue
		var miss := (to_target - direction * along).length()
		if miss > maxf(1.6, along * 0.06):
			continue
		if miss < best_miss:
			best_miss = miss
			best = barrel
	return best
