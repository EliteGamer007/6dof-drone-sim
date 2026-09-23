@tool
class_name AccessRoute
extends SitePiece
## The only route a vehicle can take from the staging area to the collapse,
## coned on the ground, and the fallen wall panel that blocks it - which is the
## single most useful thing an assessment flight can report.
##
## Edit `waypoints` in the inspector (metres, in this node's frame) to re-route
## it; `blocked_at` picks which waypoint the wall panel lies across.

@export var waypoints := PackedVector2Array([
	Vector2(4.0, 88.0), Vector2(10.0, 76.0), Vector2(14.0, 62.0),
	Vector2(12.0, 48.0), Vector2(2.0, 36.0), Vector2(-14.0, 28.0),
	Vector2(-26.0, 22.0)]):
	set(v):
		waypoints = v
		_request_rebuild()
@export var blocked_at := 4:
	set(v):
		blocked_at = v
		_request_rebuild()
@export_range(2.0, 10.0, 0.5) var cone_spacing := 4.5:
	set(v):
		cone_spacing = v
		_request_rebuild()


func _build() -> void:
	if waypoints.size() < 2:
		return
	var cone_mat := StandardMaterial3D.new()
	cone_mat.albedo_color = Color(0.95, 0.42, 0.08)
	cone_mat.roughness = 0.8
	cone_mat.emission_enabled = true
	cone_mat.emission = Color(0.9, 0.35, 0.05)
	cone_mat.emission_energy_multiplier = 0.3

	# Every cone in one MultiMesh: they are identical, so a hundred of them
	# cost one draw call.
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.03
	mesh.bottom_radius = 0.21
	mesh.height = 0.56
	mesh.radial_segments = 8
	mesh.rings = 1
	mesh.material = cone_mat

	var placements: Array[Vector3] = []
	for i in waypoints.size() - 1:
		var a := waypoints[i]
		var b := waypoints[i + 1]
		var steps := int(maxf(a.distance_to(b) / cone_spacing, 1.0))
		for k in steps:
			var p := a.lerp(b, float(k) / float(steps))
			for side: float in [-1.6, 1.6]:
				var n: Vector2 = (b - a).normalized().orthogonal() * side
				placements.append(Vector3(p.x + n.x, ground(p.x + n.x, p.y + n.y) + 0.28,
					p.y + n.y))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = placements.size()
	for i in placements.size():
		mm.set_instance_transform(i, Transform3D(Basis(), placements[i]))
	var cones := MultiMeshInstance3D.new()
	cones.name = "Cones"
	cones.multimesh = mm
	cones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_generated(cones)

	# Where the route dies.
	var at := waypoints[clampi(blocked_at, 0, waypoints.size() - 1)]
	var broken := Materials.broken_concrete()
	slab(Vector3(7.6, 1.1, 2.4), Vector3(at.x, ground(at.x, at.y) + 0.5, at.y),
		Vector3(6.0, 28.0, 9.0), broken)
	slab(Vector3(5.2, 0.9, 2.0),
		Vector3(at.x - 3.4, ground(at.x - 3.4, at.y + 1.6) + 0.4, at.y + 1.6),
		Vector3(-4.0, 52.0, -7.0), broken)

	if not is_runtime():
		return
	var d := Detectable.new()
	d.kind = Sim.FindingKind.STRUCTURAL
	d.label = "Access route blocked"
	d.detail = ("A wall panel has come down across the only vehicle route between the "
		+ "staging area and the collapse. Until it is cleared, everything past this "
		+ "point is a carry, not a drive.")
	d.recommended_action = ("Plant and lifting gear to this point first. Clearing it "
		+ "is worth more than any other single task on site.")
	d.severity = Sim.Severity.WARNING
	d.detection_radius = 3.0
	d.max_detect_range = 85.0
	d.position = Vector3(at.x, ground(at.x, at.y) + 2.2, at.y)
	add_generated(d)
