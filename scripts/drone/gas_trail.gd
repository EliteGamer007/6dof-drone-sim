class_name GasTrail
extends MultiMeshInstance3D
## A 3D breadcrumb of every air sample the aircraft has taken.
##
## This is how survey drones with gas pods present their data: not as a number
## on a screen but as a point cloud in space, each point coloured by what the
## air was like there. Flown for a few minutes, it turns the invisible plumes
## into shapes you can walk around - which in a headset is the single most
## persuasive thing in the simulation.
##
## Clean air is drawn small and dim; anything past a first alarm takes the
## colour of the gas responsible and grows with severity.

const MAX_POINTS := 3000
const SPACING := 1.4                 ## metres between samples
const DRAW_PRIORITY := 105           ## above the sensor post-process

var drone: Drone

var _head := 0
var _count := 0
var _last := Vector3.INF
var _material: StandardMaterial3D


func _ready() -> void:
	name = "GasTrail"
	top_level = true
	global_transform = Transform3D.IDENTITY

	var sphere := SphereMesh.new()
	sphere.radius = 0.11
	sphere.height = 0.22
	sphere.radial_segments = 8
	sphere.rings = 4

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.render_priority = DRAW_PRIORITY
	sphere.material = _material

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = MAX_POINTS
	mm.visible_instance_count = 0
	mm.mesh = sphere
	multimesh = mm

	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# the point cloud spans the whole site; never let the culler drop it
	custom_aabb = AABB(Vector3(-400.0, -50.0, -400.0), Vector3(800.0, 300.0, 800.0))

	visible = bool(Sim.settings.get("gas_trail", true))
	Sim.settings_changed.connect(func(): visible = bool(Sim.settings.get("gas_trail", true)))


func _physics_process(_delta: float) -> void:
	if drone == null or not is_instance_valid(drone) or drone.gas_sensor == null:
		return
	var p := drone.gas_sensor.global_position
	if _last != Vector3.INF and p.distance_to(_last) < SPACING:
		return
	_last = p
	_add_sample(p, drone.gas_sensor.readings, drone.gas_sensor.hazard_index)


func _add_sample(p: Vector3, readings: PackedFloat32Array, index: float) -> void:
	var colour: Color
	var size := 0.55
	if index < 0.35:
		# clean: a faint teal thread that just records the route
		colour = Color(0.20, 0.75, 0.70, 0.30)
	else:
		var worst := _worst(readings)
		var c: Color = Hazards.GAS_COLORS[worst]
		var strength := clampf(index, 0.0, 3.0)
		colour = Color(c.r, c.g, c.b, clampf(0.35 + strength * 0.25, 0.35, 1.0))
		size = lerpf(0.8, 2.4, clampf(strength / 3.0, 0.0, 1.0))

	var xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * size), p)
	multimesh.set_instance_transform(_head, xf)
	multimesh.set_instance_color(_head, colour)
	_head = (_head + 1) % MAX_POINTS
	_count = mini(_count + 1, MAX_POINTS)
	multimesh.visible_instance_count = _count


func _worst(readings: PackedFloat32Array) -> int:
	var worst := 0
	var score := -1.0
	for i in Hazards.GAS_COUNT:
		var v := readings[i]
		var s := 0.0
		if i == Hazards.Gas.O2:
			s = (Hazards.GAS_BASELINE[i] - v) / (Hazards.GAS_BASELINE[i] - Hazards.GAS_ALARM_LOW[i])
		else:
			s = v / maxf(Hazards.GAS_ALARM_LOW[i], 0.001)
		if s > score:
			score = s
			worst = i
	return worst


func clear() -> void:
	_head = 0
	_count = 0
	_last = Vector3.INF
	multimesh.visible_instance_count = 0


func sample_count() -> int:
	return _count
