class_name Victim
extends Detectable
## A survivor awaiting extraction.
##
## Deliberately built from simple primitives rather than a detailed human
## model. This follows the ethics note in the project research: the scene is an
## educational reconstruction of a disaster assessment task, so a person is
## represented clearly enough to find and classify, and no further.
##
## Every body part registers the capsule it is drawn with as a heat source, at
## the surface temperature that part really shows a thermal camera: exposed
## skin warmest, clothed torso a few degrees lower, extremities cooling. So in
## the thermal image the warm shape *is* the person - a head, shoulders, an
## arm - and not a round blob hovering over them. The contrast against rubble
## that has been losing heat since sunset is what makes them findable; in EO a
## figure in grey dust is nearly invisible.

enum Pose { SEATED, PRONE, TRAPPED, WAVING }

## Surface temperatures (deg C) as seen by a long-wave camera.
const SKIN_FACE := 34.3
const SKIN_HAND := 32.4
const CLOTHED_TORSO := 31.2
const CLOTHED_LIMB := 30.1

@export var pose: Pose = Pose.SEATED
@export var responsive := true             ## taps on debris to signal position
@export var clothing := Color(0.32, 0.30, 0.34)

## Drops the figure onto whatever solid surface is under it when the scene
## starts, so placing one by hand only means getting the X and Z right. Without
## this every survivor has to be given a Y that matches procedural terrain
## nobody can see in the editor, which is why they ended up floating and
## half-buried.
@export var snap_to_ground := true

## Set when a first-aid kit from the payload bay lands within reach.
var supplied := false
## How far above the authored position to start looking, and how far down to
## search. Kept short on purpose: a survivor placed in the void under a slab
## should land on the void floor, not be dragged down through the world.
@export var snap_from_above := 2.0
@export var snap_search_depth := 9.0

var _torso: Node3D
var _left_arm: Node3D
var _breath := 0.0
var _heat_nodes: Array[Node3D] = []
var _cloth: StandardMaterial3D
var _skin: StandardMaterial3D
var _strobe: MeshInstance3D


func _ready() -> void:
	kind = Sim.FindingKind.VICTIM
	if label == "Contact":
		label = "Survivor"
	if detail == "":
		detail = _default_detail()
	if recommended_action == "":
		recommended_action = ("Mark position, confirm access route, hand off to "
			+ "the extraction team with the gas reading for this location.")
	severity = Sim.Severity.CRITICAL
	thermal_contrast = 1.0
	detection_radius = 0.85
	max_detect_range = 55.0
	# A survivor is logged when the operator tags them, not when the detector
	# happens to glimpse them. Finding people is the job; the aircraft spotting
	# a warm shape is only the evidence for doing it.
	auto_log = false
	super._ready()

	_cloth = StandardMaterial3D.new()
	_cloth.albedo_color = clothing.lerp(Color(0.62, 0.60, 0.56), 0.35)  # concrete dust
	_cloth.roughness = 0.94
	_skin = StandardMaterial3D.new()
	_skin.albedo_color = Color(0.62, 0.48, 0.40).lerp(Color(0.65, 0.63, 0.58), 0.3)
	_skin.roughness = 0.85

	match pose:
		Pose.PRONE:
			_build_prone()
		Pose.TRAPPED:
			_build_trapped()
		_:
			_build_upright(pose == Pose.WAVING)

	# A body lying on rubble warms the ground it rests on - a faint thermal
	# "shadow" that survives even when most of the person is covered.
	Hazards.register_heat_capsule(self, Vector3(0.0, 0.03, 0.0), Vector3(0.0, 0.03, 0.0),
		0.28, 2.2, false, 0.42, Hazards.HeatKind.PERSON)
	_heat_nodes.append(self)

	if responsive:
		_build_audio()

	if snap_to_ground:
		# Deferred: the physics world is not queryable while the tree is still
		# being built.
		_snap_to_ground.call_deferred()


## Puts the figure's feet on the first solid surface below it.
func _snap_to_ground() -> void:
	if not is_inside_tree():
		return
	var world := get_world_3d()
	if world == null:
		return
	var from := global_position + Vector3.UP * snap_from_above
	var to := from + Vector3.DOWN * (snap_from_above + snap_search_depth)
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collide_with_areas = false
	var hit := world.direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return
	global_position = Vector3(global_position.x, hit.position.y, global_position.z)
	reset_physics_interpolation()


func _exit_tree() -> void:
	for n in _heat_nodes:
		Hazards.unregister(n)


## Tagged survivors get a strobe over them that stays lit for the rest of the
## mission, so a second pass can see at a glance who has already been accounted
## for and who has not.
func _on_tagged() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 1.0, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 1.0, 0.45)
	mat.emission_energy_multiplier = 6.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_strobe = MeshInstance3D.new()
	_strobe.name = "TaggedStrobe"
	var sphere := SphereMesh.new()
	sphere.radius = 0.10
	sphere.height = 0.20
	sphere.radial_segments = 10
	sphere.rings = 6
	_strobe.mesh = sphere
	_strobe.material_override = mat
	_strobe.position = Vector3(0.0, 1.85, 0.0)
	_strobe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_strobe)

	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 1.0, 0.5)
	light.light_energy = 2.4
	light.omni_range = 5.0
	light.shadow_enabled = false
	_strobe.add_child(light)


func _process(delta: float) -> void:
	_breath += delta
	if _torso:
		# shallow, fast breathing - visible in IR at close range
		var s := 1.0 + sin(_breath * 2.3) * 0.022
		_torso.scale = Vector3(s, 1.0, s)
	if pose == Pose.WAVING and _left_arm:
		_left_arm.rotation_degrees.z = -150.0 + sin(_breath * 3.1) * 26.0
	if _strobe:
		var pulse := 0.55 + 0.45 * sin(_breath * 6.0)
		_strobe.scale = Vector3.ONE * (0.8 + pulse * 0.5)


# ------------------------------------------------------------- construction

## A capsule body part: the mesh, and the identical capsule registered as a
## heat source on the part's own pivot, so animation carries the heat with it.
func _part(radius: float, length: float, offset: Vector3, angles: Vector3,
		mat: StandardMaterial3D, surface_temp: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = offset
	pivot.rotation_degrees = angles
	add_child(pivot)

	var height := maxf(length, radius * 2.05)
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = radius
	capsule.height = height
	capsule.radial_segments = 12
	capsule.rings = 4
	mesh.mesh = capsule
	mesh.material_override = mat
	mesh.position.y = -height * 0.5 + radius
	pivot.add_child(mesh)

	# The capsule's inner segment runs from the pivot to (height - 2r) below it.
	Hazards.register_heat_capsule(pivot, Vector3.ZERO,
		Vector3(0.0, -height + 2.0 * radius, 0.0), radius, surface_temp, true,
		0.06, Hazards.HeatKind.PERSON)
	_heat_nodes.append(pivot)
	return pivot


func _ball(radius: float, pos: Vector3, mat: StandardMaterial3D,
		surface_temp: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 14
	sphere.rings = 8
	mi.mesh = sphere
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	Hazards.register_heat_capsule(mi, Vector3.ZERO, Vector3.ZERO, radius,
		surface_temp, true, 0.05, Hazards.HeatKind.PERSON)
	_heat_nodes.append(mi)
	return mi


func _build_upright(waving: bool) -> void:
	# seated against debris, knees up
	_torso = _part(0.17, 0.60, Vector3(0.0, 0.92, 0.0), Vector3(-12.0, 0.0, 0.0),
		_cloth, CLOTHED_TORSO)
	_part(0.075, 0.40, Vector3(-0.19, 0.93, 0.02), Vector3(0.0, 0.0, -90.0),
		_cloth, CLOTHED_TORSO)   # shoulders
	_ball(0.105, Vector3(0.0, 1.07, 0.06), _skin, SKIN_FACE)

	_left_arm = _part(0.052, 0.46, Vector3(-0.21, 0.88, 0.02),
		Vector3(0.0, 0.0, -150.0 if waving else -18.0), _cloth, CLOTHED_LIMB)
	_part(0.052, 0.46, Vector3(0.21, 0.88, 0.02), Vector3(-30.0, 0.0, 16.0),
		_cloth, CLOTHED_LIMB)
	_ball(0.045, Vector3(0.30, 0.52, -0.16), _skin, SKIN_HAND)

	_part(0.072, 0.48, Vector3(-0.10, 0.46, 0.06), Vector3(-78.0, 0.0, 0.0),
		_cloth, CLOTHED_LIMB)
	_part(0.072, 0.48, Vector3(0.10, 0.46, 0.06), Vector3(-72.0, 0.0, 0.0),
		_cloth, CLOTHED_LIMB)


func _build_prone() -> void:
	_torso = _part(0.18, 0.64, Vector3(0.0, 0.20, 0.0), Vector3(-90.0, 0.0, 0.0),
		_cloth, CLOTHED_TORSO)
	_ball(0.105, Vector3(0.0, 0.17, -0.54), _skin, SKIN_FACE)

	_left_arm = _part(0.052, 0.44, Vector3(-0.25, 0.16, -0.18),
		Vector3(-90.0, 0.0, -28.0), _cloth, CLOTHED_LIMB)
	_part(0.052, 0.44, Vector3(0.25, 0.16, -0.18), Vector3(-90.0, 0.0, 24.0),
		_cloth, CLOTHED_LIMB)
	_ball(0.045, Vector3(-0.44, 0.10, -0.52), _skin, SKIN_HAND)
	_ball(0.045, Vector3(0.42, 0.10, -0.50), _skin, SKIN_HAND)

	_part(0.072, 0.52, Vector3(-0.11, 0.16, 0.50), Vector3(-90.0, 0.0, -6.0),
		_cloth, CLOTHED_LIMB)
	_part(0.072, 0.52, Vector3(0.11, 0.16, 0.50), Vector3(-90.0, 0.0, 6.0),
		_cloth, CLOTHED_LIMB)


## Only head, shoulders and one arm clear of the debris - the hard case the
## thermal payload exists to solve.
func _build_trapped() -> void:
	_torso = _part(0.17, 0.34, Vector3(0.0, 0.42, 0.0), Vector3(-58.0, 0.0, 0.0),
		_cloth, CLOTHED_TORSO)
	_ball(0.105, Vector3(0.0, 0.57, 0.15), _skin, SKIN_FACE)
	_left_arm = _part(0.052, 0.42, Vector3(-0.19, 0.44, 0.10),
		Vector3(-40.0, 0.0, -120.0), _cloth, CLOTHED_LIMB)
	_ball(0.045, Vector3(-0.52, 0.30, 0.22), _skin, SKIN_HAND)


func _build_audio() -> void:
	var stream := load("res://assets/audio/tap_signal.wav")
	if stream == null:
		return
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	var audio := AudioStreamPlayer3D.new()
	audio.stream = stream
	audio.volume_db = -9.0
	audio.unit_size = 4.0
	audio.max_distance = 38.0
	audio.pitch_scale = randf_range(0.92, 1.1)
	add_child(audio)
	audio.play()


func _default_detail() -> String:
	match pose:
		Pose.TRAPPED:
			return ("Survivor pinned under collapsed material; head and one arm "
				+ "clear. Almost invisible in the daylight feed against grey "
				+ "rubble - the thermal channel is what makes this find.")
		Pose.PRONE:
			return ("Non-ambulatory survivor, prone and not moving. Treat as a "
				+ "casualty requiring stretcher extraction.")
		Pose.WAVING:
			return ("Ambulatory survivor signalling to the aircraft. Responsive "
				+ "and able to move to an access point unaided.")
		_:
			return ("Seated survivor, conscious. Likely able to assist their own "
				+ "extraction once a safe route is confirmed.")
