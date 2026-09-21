class_name HazardBeacon
extends Node3D
## World-anchored marker over a confirmed finding.
##
## This is the answer to "the operator has to see exactly where the problem
## is". A number on a HUD does not survive being described to a third party;
## a labelled beacon standing in the world does, and in VR it reads instantly
## because it has real depth and parallax. The label is drawn without depth
## testing on purpose, so a marker behind a slab still tells you it is there.

const SHAFT_HEIGHT := 26.0

var finding: Dictionary = {}
var tint := Color.WHITE

var _label: Label3D
var _shaft: MeshInstance3D
var _ring: MeshInstance3D
var _age := 0.0


static func create(finding_data: Dictionary) -> HazardBeacon:
	var b := HazardBeacon.new()
	b.finding = finding_data
	return b


func _ready() -> void:
	tint = Sim.SEVERITY_COLORS[int(finding.get("severity", Sim.Severity.INFO))]
	_build_shaft()
	_build_ring()
	_build_label()
	add_to_group("beacon")


func _process(delta: float) -> void:
	_age += delta
	var pulse := 0.5 + 0.5 * sin(_age * 3.4)

	if _shaft:
		var mat := _shaft.material_override as StandardMaterial3D
		mat.albedo_color.a = lerpf(0.10, 0.30, pulse)
	if _ring:
		var ring_mat := _ring.material_override as StandardMaterial3D
		ring_mat.albedo_color.a = lerpf(0.30, 0.80, pulse)

	if _label and Sim.drone:
		var d := global_position.distance_to(Sim.drone.global_position)
		_label.text = "%s\n%.0f m" % [_title(), d]
		# Scale with range so the label holds a roughly constant angular size:
		# legible at a hundred metres, and not a billboard in your face at ten.
		_label.pixel_size = clampf(d * 0.00085, 0.0035, 0.045)
		_label.visible = d < 240.0


func _title() -> String:
	var kind := int(finding.get("kind", Sim.FindingKind.MARKER))
	return "%s  #%d" % [Sim.KIND_NAMES[kind], int(finding.get("id", 0))]


func _build_shaft() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.26
	mesh.bottom_radius = 0.10
	mesh.height = SHAFT_HEIGHT
	mesh.radial_segments = 10
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.18)
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_shaft = MeshInstance3D.new()
	_shaft.mesh = mesh
	_shaft.material_override = mat
	_shaft.position.y = SHAFT_HEIGHT * 0.5
	_shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shaft)


func _build_ring() -> void:
	_ring = Vfx.ground_ring(1.8, tint, 0.28)
	_ring.position.y = 0.1
	add_child(_ring)


func _build_label() -> void:
	_label = Label3D.new()
	_label.text = _title()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = false
	_label.pixel_size = 0.006
	_label.font_size = 42
	_label.outline_size = 14
	_label.modulate = tint
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_label.position.y = 2.1
	# above the payload post-process, or a marker behind you in thermal mode
	# would be silently painted over
	_label.render_priority = 108
	_label.outline_render_priority = 107
	add_child(_label)
