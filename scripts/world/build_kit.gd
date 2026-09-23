class_name BuildKit
extends RefCounted
## Construction primitives shared by the world builder and every site piece:
## a slab, a column, a mesh-only box, and a Poly Haven model with collision
## fitted to its bounds. One definition of each, so a wall built by the
## warehouse and a wall built by a ruined block behave identically.

const MODEL_ROOT := "res://assets/polyhaven/models/"


## A solid box: mesh and matching collision.
static func slab(parent: Node3D, size: Vector3, pos: Vector3, rot_deg: Vector3,
		mat: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	parent.add_child(body)
	return body


static func cylinder(parent: Node3D, radius: float, height: float, pos: Vector3,
		mat: Material, rot_deg := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg

	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 24
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	body.add_child(col)

	parent.add_child(body)
	return body


## Mesh only, no collision and no shadow: trim, markings, lamps.
static func box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material,
		rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func load_model(model_name: String) -> PackedScene:
	var path := "%s%s/%s_1k.gltf" % [MODEL_ROOT, model_name, model_name]
	if not ResourceLoader.exists(path):
		push_warning("BuildKit: missing model %s" % path)
		return null
	return load(path)


## A downloaded prop, with a box collider fitted to its visual bounds.
static func model(parent: Node3D, model_name: String, pos: Vector3, yaw: float,
		scale := 1.0, collide := true, tilt := 0.0) -> Node3D:
	var packed := load_model(model_name)
	if packed == null:
		return null
	var inst := packed.instantiate()
	var holder: Node3D = StaticBody3D.new() if collide else Node3D.new()
	holder.position = pos
	holder.rotation_degrees = Vector3(tilt, yaw, tilt * 0.6)
	holder.add_child(inst)
	if inst is Node3D:
		inst.scale = Vector3.ONE * scale
	parent.add_child(holder)

	if collide:
		var aabb := aabb_of(inst)
		if aabb.size.length() > 0.01:
			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = aabb.size * scale
			col.shape = shape
			col.position = aabb.get_center() * scale
			holder.add_child(col)
	return holder


static func aabb_of(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for child in descendants(node):
		if child is VisualInstance3D:
			var box_aabb: AABB = child.get_aabb()
			if child != node and child is Node3D:
				box_aabb = child.transform * box_aabb
			if first:
				out = box_aabb
				first = false
			else:
				out = out.merge(box_aabb)
	return out


static func descendants(node: Node) -> Array:
	var out := [node]
	for c in node.get_children():
		out.append_array(descendants(c))
	return out


## A light that exists only after dark, driven by WorldBuilder's clock.
static func night_light(light: Light3D) -> Light3D:
	light.add_to_group(WorldBuilder.NIGHT_LIGHT_GROUP)
	# Off in the editor. In the game, whatever the clock says right now - the
	# world re-applies the whole group once every piece is in the tree.
	light.visible = not Engine.is_editor_hint() and WorldBuilder.is_night(Sim.time_of_day)
	return light
