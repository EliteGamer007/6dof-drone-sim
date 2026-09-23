@tool
class_name SitePiece
extends Node3D
## Base for every hand-placeable piece of the site: buildings, vehicles, the
## crane, the casualty point, signs, props.
##
## Each piece builds its own geometry from code, in the editor as well as in
## the game, so it can be seen, selected and dragged around in scenes/main.tscn.
## Move one and it rebuilds on the spot, re-seated on the terrain wherever it
## was dropped; change an export and the change shows immediately.
##
## Everything a piece builds is tagged as generated and never written back into
## the scene file - main.tscn stores where a piece is and how it is set up,
## not thousands of slabs.

## Varies the randomised detail (debris, lean, collapse pattern) without
## touching the piece's overall layout.
@export var seed := 1:
	set(v):
		seed = v
		_request_rebuild()

var rng := RandomNumberGenerator.new()
var _pending := false


func _ready() -> void:
	set_notify_transform(true)
	_rebuild()


func _notification(what: int) -> void:
	# Dragged in the editor: rebuild so it follows the ground under it.
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_request_rebuild()


func _request_rebuild() -> void:
	if not is_inside_tree() or _pending:
		return
	_pending = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_pending = false
	for child in get_children():
		if child.has_meta(&"generated"):
			remove_child(child)
			child.queue_free()
	rng.seed = seed
	_build()


## Override: build the piece's geometry.
func _build() -> void:
	pass


static func is_runtime() -> bool:
	return not Engine.is_editor_hint()


## Terrain height under a point in this piece's own frame, relative to the
## piece. Adding it to a local Y seats that point on the ground regardless of
## where the piece has been moved or how high its origin happens to sit.
func ground(local_x: float, local_z: float) -> float:
	var world := global_transform * Vector3(local_x, 0.0, local_z)
	return Terrain.height(world.x, world.z) - global_position.y


# ------------------------------------------------ builders, marked generated

func slab(size: Vector3, pos: Vector3, rot_deg: Vector3,
		mat: Material, parent: Node3D = null) -> StaticBody3D:
	return _mark(BuildKit.slab(parent if parent else self, size, pos, rot_deg, mat),
		parent)


func cylinder(radius: float, height: float, pos: Vector3, mat: Material,
		rot_deg := Vector3.ZERO) -> StaticBody3D:
	return _mark(BuildKit.cylinder(self, radius, height, pos, mat, rot_deg), null)


func box(size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO,
		parent: Node3D = null) -> MeshInstance3D:
	return _mark(BuildKit.box(parent if parent else self, size, pos, mat, rot_deg),
		parent)


func model(model_name: String, pos: Vector3, yaw: float, scale := 1.0,
		collide := true, tilt := 0.0) -> Node3D:
	return _mark(BuildKit.model(self, model_name, pos, yaw, scale, collide, tilt), null)


func add_generated(node: Node, parent: Node = null) -> Node:
	(parent if parent else self).add_child(node)
	if parent == null or parent == self:
		node.set_meta(&"generated", true)
	return node


func _mark(node: Node, parent: Node3D) -> Node:
	# Only direct children need the tag; anything under them goes with them.
	if node and (parent == null or parent == self):
		node.set_meta(&"generated", true)
	return node
