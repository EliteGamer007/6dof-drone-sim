@tool
class_name Harbour
extends SitePiece
## The quay wall and the water it holds back.
##
## The wall only reads as a quay if there is sea on the other side of it. One
## plane and one shader for the water - no reflections or refraction, which at
## this distance would not show and would cost. It sits below the wall top so
## the wall is visibly holding the sea back.
##
## Water is the one thing on site colder than ambient, so the shoreline is the
## sharpest edge on the thermal image.

@export_range(2, 30) var wall_sections := 12:
	set(v):
		wall_sections = v
		_request_rebuild()
@export var water_size := Vector2(620.0, 420.0):
	set(v):
		water_size = v
		_request_rebuild()

const SECTION := 18.0


func _build() -> void:
	var concrete := Materials.concrete()
	var span := float(wall_sections) * SECTION

	# The wall itself, in slightly settled sections.
	for i in wall_sections:
		var x := -span * 0.5 + (float(i) + 0.5) * SECTION
		slab(Vector3(17.5, 4.0, 2.0), Vector3(x, ground(x, 0.0) + 1.4, 0.0),
			Vector3(0.0, 0.0, rng.randf_range(-3.0, 3.0)), concrete)

	# Apron between the wall and the water line, so there is no gap to see
	# through at a shallow angle.
	var apron := Materials.concrete(Color(0.52, 0.50, 0.47))
	slab(Vector3(maxf(span, water_size.x) + 20.0, 3.0, 14.0),
		Vector3(0.0, ground(0.0, 0.0) - 0.6, -8.0), Vector3.ZERO, apron)

	var shader := load("res://shaders/water.gdshader")
	if shader:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var plane := PlaneMesh.new()
		plane.size = water_size
		plane.subdivide_width = 60
		plane.subdivide_depth = 40
		plane.material = mat
		var water := MeshInstance3D.new()
		water.name = "Water"
		water.mesh = plane
		water.position = Vector3(0.0, ground(0.0, 0.0) - 1.1, -water_size.y * 0.5 - 4.0)
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_generated(water)

		if is_runtime():
			Hazards.register_heat_capsule(water,
				Vector3(-water_size.x * 0.42, 0.0, 0.0),
				Vector3(water_size.x * 0.42, 0.0, 0.0),
				water_size.y * 0.28, -6.0, false, 26.0, Hazards.HeatKind.COLD)


func _exit_tree() -> void:
	if is_runtime():
		for child in get_children():
			Hazards.unregister(child)
