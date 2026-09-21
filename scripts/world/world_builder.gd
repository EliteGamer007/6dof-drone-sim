@tool
class_name WorldBuilder
extends Node3D
## Builds the survey area: terrain with a blast crater, ruined port structures,
## scattered CC0 props, and the hazards the mission is about.
##
## Everything is generated from a fixed seed, so the scene is identical every
## run - which matters when you are demonstrating to an examiner and need the
## survivor to be in the same place twice.

signal world_ready

enum Quality { LOW, MEDIUM, HIGH, VR }

## Named times the settings menu steps through. DUSK is the default: bright
## enough to fly on the daylight camera, dark enough that thermal clearly wins.
const TIME_PRESETS := [
	["DAWN", 6.4],
	["DAY", 13.0],
	["DUSK", 17.6],
	["NIGHT", 22.3],
]

## Nodes in this group are switched on after dark and off during the day, so
## the site lights itself the way a working site would.
const NIGHT_LIGHT_GROUP := "night_light"

const TERRAIN_SIZE := 420.0
const TERRAIN_STEPS := 112
const CRATER_RADIUS := 58.0
const CRATER_DEPTH := 9.5
const MODEL_ROOT := "res://assets/polyhaven/models/"

## The staging area. The drone launches from, and recovers to, the roof of the
## response van parked here, so this one point drives the launch transform, the
## RTL objective, and the clear radius the prop scatter has to respect.
const PAD_CENTRE := Vector2(0.0, 96.0)
const PAD_CLEAR_RADIUS := 19.0
const VAN_DECK_HEIGHT := 2.46         ## metres above the ground the van sits on
const VAN_YAW_DEGREES := 8.0
## The touchdown circle, in the van's own frame: the middle of the deck, not
## the middle of the vehicle.
const VAN_PAD_OFFSET := Vector3(0.0, VAN_DECK_HEIGHT + 0.12, 0.75)

const HDRI_DAY := "res://assets/polyhaven/hdris/kloofendal_overcast_puresky_2k.hdr"
const HDRI_DUSK := "res://assets/polyhaven/hdris/industrial_sunset_02_puresky_2k.hdr"
const HDRI_NIGHT := "res://assets/polyhaven/hdris/wasteland_clouds_puresky_2k.hdr"

@export var quality: Quality = Quality.MEDIUM
## Off when scenes/main.tscn supplies its own Survivors node, so the six
## hand-placed figures are not doubled up by the procedural fallback.
@export var place_victims := true
@export var world_seed := 20200804        ## the date of the event being studied

var environment: WorldEnvironment
var sun: DirectionalLight3D
var terrain: StaticBody3D
var epicentre := Vector3(0.0, 0.0, -12.0)

var _rng := RandomNumberGenerator.new()
var _sky_material := PanoramaSkyMaterial.new()
var _structures: Node3D
var _props: Node3D
var _hazards: Node3D
var _height_cache := {}
var _dust: GPUParticles3D
var _is_night := false
var _glow_preset := true
var _windsock: MeshInstance3D


func _ready() -> void:
	_rng.seed = world_seed
	_structures = _group("Structures")
	_props = _group("Props")
	_hazards = _group("Hazards")

	# In the editor, build just the static site (terrain, structures, props) so
	# the scene can be seen and laid out. Hazards, effects and time-of-day need
	# the running simulation.
	if Engine.is_editor_hint():
		_build_environment()
		_build_sun()
		sun.rotation_degrees = Vector3(-18.0, 80.0, 0.0)
		_build_terrain()
		_build_structures()
		_scatter_props()
		return

	var t := Time.get_ticks_msec()
	_build_environment()
	_build_sun()
	_trace("env %d ms", t); t = Time.get_ticks_msec()
	_build_terrain()
	_trace("terrain %d ms", t); t = Time.get_ticks_msec()
	_build_structures()
	_trace("structures %d ms", t); t = Time.get_ticks_msec()
	_scatter_props()
	_place_team_assets()
	_trace("props %d ms", t); t = Time.get_ticks_msec()
	_place_hazards()
	_trace("hazards %d ms", t); t = Time.get_ticks_msec()
	_build_ambient_effects()
	_trace("ambient %d ms", t)

	apply_quality(quality)
	set_time_of_day(Sim.time_of_day)
	world_ready.emit()


## Build timings, printed only when the engine is run with --verbose.
func _trace(fmt: String, since: int) -> void:
	if OS.is_stdout_verbose():
		print("[world] " + (fmt % (Time.get_ticks_msec() - since)))


func _group(n: String) -> Node3D:
	var g := Node3D.new()
	g.name = n
	add_child(g)
	return g


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_windsock()
	_update_sensor_look()
	if Input.is_action_pressed("time_forward"):
		set_time_of_day(Sim.time_of_day + delta * 2.2)
	elif Input.is_action_pressed("time_back"):
		set_time_of_day(Sim.time_of_day - delta * 2.2)


## Bloom belongs to the daylight camera and nothing else. A thermal or
## low-light feed that glows is the single biggest reason a sensor image reads
## as "a game with a filter on it" rather than as a sensor: a real core has no
## HDR bloom, so a frame of ambient-temperature ground stays dark instead of
## washing out into one bright colour.
func _update_sensor_look() -> void:
	if environment == null:
		return
	var env := environment.environment
	var wants: bool = _glow_preset and Sim.vision_mode == Sim.VisionMode.NORMAL
	if env.glow_enabled != wants:
		env.glow_enabled = wants


## The sock points downwind and lifts with the wind speed, so the mast agrees
## with the HUD readout and with the direction the plumes are actually drifting.
func _update_windsock() -> void:
	if _windsock == null or not is_instance_valid(_windsock):
		return
	var wind := Hazards.current_wind()
	var speed := wind.length()
	if speed < 0.05:
		return
	var dir := wind / speed
	# lie flat at 8 m/s, hang down in still air
	var lift := deg_to_rad(lerpf(20.0, 90.0, clampf(speed / 8.0, 0.0, 1.0)))
	var yaw := atan2(dir.x, dir.z)
	_windsock.global_basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, lift)


# ---------------------------------------------------------------- terrain

## Crater profile plus multi-octave noise. Kept as a pure function so the
## prop scatter can ask for ground height without a physics query.
func terrain_height(x: float, z: float) -> float:
	var key := Vector2i(int(x * 4.0), int(z * 4.0))
	if _height_cache.has(key):
		return _height_cache[key]

	var d := Vector2(x - epicentre.x, z - epicentre.z).length()
	var h := 0.0

	# crater bowl with a raised rim of ejecta
	if d < CRATER_RADIUS:
		var t := d / CRATER_RADIUS
		h -= CRATER_DEPTH * (1.0 - t * t) * (1.0 - t * 0.35)
	var rim := exp(-pow((d - CRATER_RADIUS * 1.06) / 22.0, 2.0))
	h += rim * 3.2

	# general rubble undulation, heavier close in
	var rubble_weight := clampf(1.4 - d / 150.0, 0.25, 1.4)
	h += _fbm(Vector2(x, z) * 0.035) * 2.1 * rubble_weight
	h += _fbm(Vector2(x, z) * 0.14 + Vector2(19.0, 7.0)) * 0.55 * rubble_weight

	# flatten the launch pad so the drone starts on something sane
	var pad := exp(-pow(Vector2(x - 0.0, z - 96.0).length() / 14.0, 2.0))
	h = lerpf(h, 0.35, clampf(pad, 0.0, 0.92))

	_height_cache[key] = h
	return h


func _fbm(p: Vector2) -> float:
	var total := 0.0
	var amp := 1.0
	var freq := 1.0
	var norm := 0.0
	for i in 4:
		total += _value_noise(p * freq) * amp
		norm += amp
		amp *= 0.5
		freq *= 2.07
	return (total / norm) * 2.0 - 1.0


func _value_noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := _hash2(i)
	var b := _hash2(i + Vector2(1.0, 0.0))
	var c := _hash2(i + Vector2(0.0, 1.0))
	var d := _hash2(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)


func _hash2(p: Vector2) -> float:
	return fposmod(sin(p.x * 127.1 + p.y * 311.7) * 43758.5453, 1.0)


func _build_terrain() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var step := TERRAIN_SIZE / float(TERRAIN_STEPS)
	var half := TERRAIN_SIZE * 0.5

	for j in TERRAIN_STEPS + 1:
		for i in TERRAIN_STEPS + 1:
			var x := -half + float(i) * step
			var z := -half + float(j) * step
			verts.append(Vector3(x, terrain_height(x, z), z))
			uvs.append(Vector2(float(i) / TERRAIN_STEPS, float(j) / TERRAIN_STEPS))
			# central-difference normal
			var hl := terrain_height(x - step, z)
			var hr := terrain_height(x + step, z)
			var hd := terrain_height(x, z - step)
			var hu := terrain_height(x, z + step)
			normals.append(Vector3(hl - hr, 2.0 * step, hd - hu).normalized())

	var row := TERRAIN_STEPS + 1
	for j in TERRAIN_STEPS:
		for i in TERRAIN_STEPS:
			var a := j * row + i
			var b := a + 1
			var c := a + row
			var d := c + 1
			indices.append_array([a, b, c, b, d, c])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	# Tangents are not optional here: the terrain shader writes NORMAL_MAP, and
	# without a tangent frame that lighting is undefined.
	var tool := SurfaceTool.new()
	tool.create_from_arrays(arrays, Mesh.PRIMITIVE_TRIANGLES)
	tool.generate_tangents()
	var mesh := tool.commit()

	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = load("res://shaders/terrain.gdshader")
	for pair in [["concrete", "damaged_concrete_floor"], ["rubble", "rubble"],
			["road", "asphalt_02"]]:
		shader_mat.set_shader_parameter("%s_albedo" % pair[0],
			Materials.texture(pair[1], "diff"))
		shader_mat.set_shader_parameter("%s_normal" % pair[0],
			Materials.texture(pair[1], "nor_gl"))
		shader_mat.set_shader_parameter("%s_orm" % pair[0],
			Materials.texture(pair[1], "arm"))
	shader_mat.set_shader_parameter("epicentre", epicentre)
	shader_mat.set_shader_parameter("crater_radius", CRATER_RADIUS)
	mesh.surface_set_material(0, shader_mat)

	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	terrain = StaticBody3D.new()
	terrain.name = "Terrain"
	terrain.add_child(mi)

	var shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(_faces_from(verts, indices))
	shape.shape = concave
	terrain.add_child(shape)
	add_child(terrain)


func _faces_from(verts: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for i in indices.size():
		faces[i] = verts[indices[i]]
	return faces


# ------------------------------------------------------------ environment

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	_sky_material.panorama = load(HDRI_DUSK)
	_sky_material.energy_multiplier = 1.0
	sky.sky_material = _sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.tonemap_exposure = 1.2
	env.ambient_light_energy = 1.3

	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.12
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.05

	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 2.2
	env.ssil_enabled = true
	env.ssil_intensity = 0.7

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.74, 0.69, 0.60)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0016
	env.fog_aerial_perspective = 0.28
	env.fog_sky_affect = 0.12

	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.007
	env.volumetric_fog_albedo = Color(0.78, 0.74, 0.66)
	env.volumetric_fog_emission = Color(0.05, 0.04, 0.03)
	env.volumetric_fog_length = 120.0
	env.volumetric_fog_gi_inject = 0.6

	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 0.94

	environment = WorldEnvironment.new()
	environment.name = "WorldEnvironment"
	environment.environment = env
	add_child(environment)


func _build_sun() -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 260.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.42
	sun.light_angular_distance = 0.6
	sun.light_volumetric_fog_energy = 1.4
	add_child(sun)


## Drives sun angle, sky, ambient temperature and the shader's daylight term.
func set_time_of_day(hours: float) -> void:
	Sim.time_of_day = fposmod(hours, 24.0)
	# 06:00 sunrise in the east, 19:00 sunset in the west
	var day_fraction := (Sim.time_of_day - 6.0) / 13.0
	var elevation := sin(day_fraction * PI)
	var azimuth := lerpf(-100.0, 100.0, clampf(day_fraction, 0.0, 1.0))

	if sun:
		sun.rotation_degrees = Vector3(
			-clampf(rad_to_deg(asin(clampf(elevation, -1.0, 1.0))), -89.0, 89.0),
			azimuth, 0.0)
		Sim.sun_direction = -sun.global_basis.z

	var day := clampf(elevation * 1.25, 0.0, 1.0)
	Sim.daylight = day

	if sun:
		sun.light_energy = lerpf(0.45, 1.7, day)
		sun.light_color = Color(1.0, 0.93, 0.82).lerp(Color(1.0, 0.62, 0.38),
			clampf(1.0 - day * 1.6, 0.0, 1.0))

	var night := Sim.time_of_day < 5.6 or Sim.time_of_day > 19.4
	var dusk := not night and (Sim.time_of_day < 8.0 or Sim.time_of_day > 16.5)
	var wanted: String = HDRI_NIGHT if night else (HDRI_DUSK if dusk else HDRI_DAY)
	var current := _sky_material.panorama
	if current == null or current.resource_path != wanted:
		_sky_material.panorama = load(wanted)
	# After dark the sky has to stop acting as a fill light, or the ground
	# stays bright enough that the low-light channel has nothing to amplify
	# and clips to flat white. Night should be dark; that is the point of
	# carrying the other two sensors.
	_sky_material.energy_multiplier = 0.12 if night else lerpf(0.45, 1.0, day)

	if environment:
		var env := environment.environment
		env.volumetric_fog_emission = Color(0.05, 0.04, 0.03).lerp(
			Color(0.02, 0.02, 0.03), 1.0 - day)
		env.fog_light_color = Color(0.74, 0.69, 0.60).lerp(
			Color(0.12, 0.14, 0.20), 1.0 - day)
		env.glow_intensity = lerpf(0.85, 0.5, day)

	# A sliver of moonlight rather than nothing at all: at true night the
	# directional light goes cold and dim instead of off, so EO still shows
	# silhouettes and the operator can see why they want the other sensors.
	if sun and night:
		sun.light_energy = 0.22
		sun.light_color = Color(0.58, 0.68, 1.0)
		sun.rotation_degrees = Vector3(-52.0, 214.0, 0.0)
		Sim.sun_direction = -sun.global_basis.z

	if environment:
		var env2 := environment.environment
		env2.ambient_light_energy = 0.60 if night else 1.3
		env2.ambient_light_color = (Color(0.34, 0.40, 0.56) if night
			else Color(0.62, 0.66, 0.72))

	_set_night_lights(night)

	Hazards.ambient_temp = lerpf(Hazards.AMBIENT_TEMP_NIGHT,
		Hazards.AMBIENT_TEMP_DAY, day)


## Site lighting follows the clock. Everything registered as a night light is
## simply hidden by day, which also takes it out of the renderer's light list.
func _set_night_lights(night: bool) -> void:
	_is_night = night
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(NIGHT_LIGHT_GROUP):
		if node is Node3D:
			node.visible = night


## Steps to the next named time of day and returns its label.
func cycle_time_preset(step := 1) -> String:
	var nearest := 0
	var best := INF
	for i in TIME_PRESETS.size():
		var d: float = absf(float(TIME_PRESETS[i][1]) - Sim.time_of_day)
		d = minf(d, 24.0 - d)
		if d < best:
			best = d
			nearest = i
	var next: int = wrapi(nearest + step, 0, TIME_PRESETS.size())
	set_time_of_day(float(TIME_PRESETS[next][1]))
	return str(TIME_PRESETS[next][0])


## The label of whichever named time we are closest to, for the settings menu.
func time_preset_name() -> String:
	var nearest := 0
	var best := INF
	for i in TIME_PRESETS.size():
		var d: float = absf(float(TIME_PRESETS[i][1]) - Sim.time_of_day)
		d = minf(d, 24.0 - d)
		if d < best:
			best = d
			nearest = i
	return str(TIME_PRESETS[nearest][0])


## Three presets plus the VR one.
##
## Screen-space global illumination (SDFGI) and SSIL are left off at every
## preset: on this scene they cost more than everything else combined and buy
## very little, because almost all of the interesting light is direct.
func apply_quality(preset: Quality) -> void:
	quality = preset
	if environment == null or sun == null:
		return
	var env := environment.environment
	env.ssil_enabled = false
	env.sdfgi_enabled = false

	match preset:
		Quality.LOW:
			# Anything that costs a full-screen pass is gone. This is the
			# preset for integrated graphics.
			env.ssao_enabled = false
			env.volumetric_fog_enabled = false
			_glow_preset = false
			env.fog_enabled = false
			sun.directional_shadow_max_distance = 70.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
			sun.shadow_blur = 0.6
		Quality.MEDIUM:
			# The default. Looks right, runs on a laptop GPU.
			env.ssao_enabled = false
			env.volumetric_fog_enabled = false
			_glow_preset = true
			env.fog_enabled = true
			env.fog_density = 0.0016
			sun.directional_shadow_max_distance = 150.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			sun.shadow_blur = 1.0
		Quality.HIGH:
			# Ambient occlusion seats the rubble on the ground and volumetric
			# fog gives the fires and the spotlight something to shine through.
			env.ssao_enabled = true
			env.ssao_intensity = 1.6
			env.ssao_radius = 1.6
			env.volumetric_fog_enabled = true
			env.volumetric_fog_density = 0.016
			env.volumetric_fog_length = 92.0
			_glow_preset = true
			env.fog_enabled = true
			env.fog_density = 0.0020
			sun.directional_shadow_max_distance = 230.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			sun.shadow_blur = 1.0
		Quality.VR:
			# Stereo doubles the cost of every screen-space effect; the ones
			# that survive are the ones the mission actually needs.
			env.ssao_enabled = false
			env.volumetric_fog_enabled = false
			_glow_preset = true
			env.fog_enabled = true
			env.fog_density = 0.0022
			sun.directional_shadow_max_distance = 120.0
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS

	_update_sensor_look()
	_apply_detail(preset)


## Scene detail that is not a renderer setting: the airborne dust is the one
## particle system big enough to matter on a weak GPU.
func _apply_detail(preset: Quality) -> void:
	if _dust == null or not is_instance_valid(_dust):
		return
	match preset:
		Quality.LOW:
			_dust.visible = false
			_dust.emitting = false
		Quality.MEDIUM, Quality.VR:
			_dust.visible = true
			_dust.emitting = true
			_dust.amount_ratio = 0.55
		Quality.HIGH:
			_dust.visible = true
			_dust.emitting = true
			_dust.amount_ratio = 1.0


# ------------------------------------------------------------- structures

func _slab(size: Vector3, pos: Vector3, rot_deg: Vector3,
		mat: StandardMaterial3D, parent: Node3D = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg

	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	(parent if parent else _structures).add_child(body)
	return body


func _cylinder(radius: float, height: float, pos: Vector3,
		mat: StandardMaterial3D, rot_deg := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg

	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 24
	mi.mesh = cyl
	mi.material_override = mat
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	body.add_child(col)

	_structures.add_child(body)
	return body


func _build_structures() -> void:
	var concrete := Materials.concrete()
	var broken := Materials.broken_concrete()
	var steel := Materials.rusted_steel()
	var stone := Materials.stone()

	_build_silos(concrete, broken)
	_build_warehouse(steel, concrete)
	_build_collapsed_block(broken, stone)
	_build_container_yard(steel)
	_build_pipe_corridor(steel, concrete)
	_build_quay_wall(concrete)
	_build_staging_area()
	_build_forward_operating_points()
	_build_background_city()
	_build_outer_ruins()
	_build_ruined_blocks(broken, stone, concrete)
	_scatter_rubble_field()


# ------------------------------------------------------------ the city

## Distant skyline.
##
## Beirut's port sits inside the city, and a survey area with nothing on the
## horizon reads as a film set rather than a place. This is the cheapest
## possible answer: one MultiMesh of boxes, no collision, no shadows, one draw
## call for the whole skyline. They are never closer than 115 m, so nothing
## here is ever anything but a silhouette.
func _build_background_city() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE

	# The same concrete as the rest of the site rather than flat albedo, or the
	# skyline reads as untextured placeholder boxes.
	var mat := Materials.concrete(Color(0.78, 0.76, 0.72))
	mat.vertex_color_use_as_albedo = true      # per-instance tinting
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.material = mat

	var blocks: Array = []
	for i in 150:
		var angle := _rng.randf() * TAU
		# Far enough out that these are always silhouettes. At the 118 m they
		# started at, flying toward the staging area put a wall of untextured
		# blocks across the whole frame.
		var radius := _rng.randf_range(152.0, 198.0)
		# Weighted behind the launch pad, so looking back over the staging area
		# is city and looking into the site is not.
		if _rng.randf() < 0.5:
			angle = lerpf(-PI * 0.40, PI * 0.40, _rng.randf()) + PI * 0.5
		var x := cos(angle) * radius
		var z := sin(angle) * radius
		# The quay is on the seaward side, so the city stops there. A solid
		# ring would enclose the site like an arena.
		if z < -120.0 and absf(x) < 110.0:
			continue
		if Vector2(x, z).distance_to(PAD_CENTRE) < 46.0:
			continue                            # keep the sky behind the van open
		var w := _rng.randf_range(10.0, 22.0)
		var d := _rng.randf_range(10.0, 22.0)
		# Taller further out, so the skyline builds up rather than walling the
		# site in.
		var h := _rng.randf_range(8.0, 16.0) + (radius - 152.0) * 0.22
		var shade := _rng.randf_range(0.66, 1.0)
		blocks.append([Vector3(x, terrain_height(x, z) - 1.0 + h * 0.5, z),
			Vector3(w, h, d), _rng.randf_range(0.0, 90.0), shade])

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = blocks.size()
	for i in blocks.size():
		var b: Array = blocks[i]
		var basis := Basis(Vector3.UP, deg_to_rad(float(b[2]))).scaled(b[1] as Vector3)
		mm.set_instance_transform(i, Transform3D(basis, b[0] as Vector3))
		var shade: float = b[3]
		mm.set_instance_color(i, Color(shade, shade * 0.99, shade * 0.95))

	var city := MultiMeshInstance3D.new()
	city.name = "BackgroundCity"
	city.multimesh = mm
	city.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	city.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_structures.add_child(city)


## The city edge immediately behind the staging area: close enough to read as
## buildings rather than silhouettes, and damaged, because the blast reached
## this far. These get collision - the operator can fly over here.
func _build_outer_ruins() -> void:
	var concrete := Materials.concrete()
	var broken := Materials.broken_concrete()
	var stone := Materials.stone()

	var sites := [
		[Vector3(-58.0, 0.0, 132.0), 18.0, 22.0, 14.0, 0.62],
		[Vector3(-16.0, 0.0, 148.0), 24.0, 15.0, 16.0, 0.30],
		[Vector3(34.0, 0.0, 138.0), 16.0, 26.0, 13.0, 0.75],
		[Vector3(74.0, 0.0, 120.0), 20.0, 19.0, 15.0, 0.45],
		[Vector3(-92.0, 0.0, 104.0), 15.0, 17.0, 12.0, 0.55],
		[Vector3(104.0, 0.0, 154.0), 22.0, 24.0, 17.0, 0.35],
	]
	for site in sites:
		var pos: Vector3 = site[0]
		_build_damaged_block(pos, float(site[1]), float(site[2]), float(site[3]),
			float(site[4]), concrete, broken, stone)


## Ruined city blocks inside the survey area itself. These are the ones the
## operator flies between, so they carry the detail: standing facades, floor
## slabs that have pancaked, and the voids between them.
func _build_ruined_blocks(broken: StandardMaterial3D, stone: StandardMaterial3D,
		concrete: StandardMaterial3D) -> void:
	# Kept clear on purpose: the crater bowl, the pipe corridor the mission
	# funnels the pilot down, and the staging area.
	var sites := [
		[Vector3(-84.0, 0.0, -22.0), 16.0, 18.0, 13.0, 0.55],
		[Vector3(-22.0, 0.0, 60.0), 19.0, 12.0, 15.0, 0.85],
		[Vector3(64.0, 0.0, 10.0), 15.0, 20.0, 12.0, 0.40],
		[Vector3(26.0, 0.0, -80.0), 18.0, 9.0, 14.0, 1.00],
		[Vector3(78.0, 0.0, -68.0), 20.0, 16.0, 16.0, 0.70],
		[Vector3(-88.0, 0.0, 58.0), 17.0, 11.0, 13.0, 0.95],
		[Vector3(-70.0, 0.0, -78.0), 14.0, 21.0, 12.0, 0.25],
	]
	for site in sites:
		_build_damaged_block(site[0], float(site[1]), float(site[2]),
			float(site[3]), float(site[4]), concrete, broken, stone)


## One damaged building.
##
## `collapse` runs 0 (barely touched, a shell with its floors intact) to 1
## (flattened into a pancake stack). Everything between is a partial: some
## floors down, some walls still standing, the rest in a heap at the base.
func _build_damaged_block(origin: Vector3, width: float, height: float,
		depth: float, collapse: float, concrete: StandardMaterial3D,
		broken: StandardMaterial3D, stone: StandardMaterial3D) -> void:
	var ground := terrain_height(origin.x, origin.z)
	var yaw := _rng.randf_range(0.0, 360.0)
	var root := Node3D.new()
	root.name = "Ruin_%d_%d" % [int(origin.x), int(origin.z)]
	root.position = Vector3(origin.x, ground, origin.z)
	root.rotation_degrees.y = yaw
	_structures.add_child(root)

	var floors := maxi(int(height / 3.4), 1)
	var standing := int(round(float(floors) * (1.0 - collapse)))
	var floor_h := 3.4

	# Standing floors: four corner columns and a slab over them.
	for level in standing:
		var y := float(level) * floor_h
		for cx in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				_slab(Vector3(0.8, floor_h, 0.8),
					Vector3(cx * (width * 0.5 - 0.6), y + floor_h * 0.5,
						cz * (depth * 0.5 - 0.6)),
					Vector3.ZERO, concrete, root)
		_slab(Vector3(width, 0.38, depth), Vector3(0.0, y + floor_h, 0.0),
			Vector3.ZERO, concrete, root)

	# Surviving wall sections on the standing part. Not all four sides - a
	# building with every wall intact does not read as damaged.
	if standing > 0:
		var wall_h := float(standing) * floor_h
		_slab(Vector3(0.45, wall_h, depth), Vector3(-width * 0.5, wall_h * 0.5, 0.0),
			Vector3.ZERO, stone, root)
		if _rng.randf() < 0.65:
			_slab(Vector3(width, wall_h * 0.7, 0.45),
				Vector3(0.0, wall_h * 0.35, -depth * 0.5), Vector3.ZERO, stone, root)
		if _rng.randf() < 0.4:
			_slab(Vector3(0.45, wall_h * 0.55, depth * 0.6),
				Vector3(width * 0.5, wall_h * 0.28, depth * 0.2),
				Vector3(0.0, 0.0, _rng.randf_range(-4.0, 4.0)), stone, root)

	# Collapsed floors, pancaked onto whatever is left standing.
	var pile_base := float(standing) * floor_h
	var collapsed := floors - standing
	for level in collapsed:
		var lean := _rng.randf_range(-11.0, 11.0)
		var y := pile_base + float(level) * 0.95 + 0.3
		_slab(Vector3(width * _rng.randf_range(0.82, 1.02), 0.4,
				depth * _rng.randf_range(0.82, 1.02)),
			Vector3(_rng.randf_range(-1.8, 1.8), y, _rng.randf_range(-1.8, 1.8)),
			Vector3(lean * 0.5, _rng.randf_range(-14.0, 14.0), lean),
			broken, root)
		# rubble columns propping the slab, which is what makes the void
		for c in 2:
			_slab(Vector3(1.0, 0.8, 1.0),
				Vector3(_rng.randf_range(-width * 0.35, width * 0.35), y - 0.6,
					_rng.randf_range(-depth * 0.35, depth * 0.35)),
				Vector3(0.0, _rng.randf_range(0.0, 90.0), 0.0), broken, root)

	# Debris apron around the base - buildings do not fall straight down.
	var apron := int(6.0 + collapse * 8.0)
	for i in apron:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(width * 0.45, width * 0.9)
		_slab(Vector3(_rng.randf_range(1.2, 3.4), _rng.randf_range(0.4, 1.1),
				_rng.randf_range(1.2, 3.4)),
			Vector3(cos(a) * r, _rng.randf_range(0.1, 0.5), sin(a) * r),
			Vector3(_rng.randf_range(-16.0, 16.0), _rng.randf_range(0.0, 90.0),
				_rng.randf_range(-16.0, 16.0)),
			broken, root)


## Ground debris across the whole site, thickest along the pipe corridor.
##
## Three MultiMeshes - chunks, slab fragments and twisted steel - so the entire
## field is three draw calls and carries no collision. It is what turns bare
## terrain into somewhere a building used to be.
func _scatter_rubble_field() -> void:
	var chunk := BoxMesh.new()
	chunk.size = Vector3.ONE
	var shard := BoxMesh.new()
	shard.size = Vector3.ONE
	var bar := BoxMesh.new()
	bar.size = Vector3.ONE

	var rubble_mat := Materials.broken_concrete()
	rubble_mat.vertex_color_use_as_albedo = true
	var steel_mat := Materials.rusted_steel()
	steel_mat.vertex_color_use_as_albedo = true

	chunk.material = rubble_mat
	shard.material = rubble_mat
	bar.material = steel_mat

	var sets := [
		{"mesh": chunk, "count": 420, "name": "RubbleChunks",
			"min": Vector3(0.45, 0.3, 0.45), "max": Vector3(1.9, 1.1, 1.9)},
		{"mesh": shard, "count": 300, "name": "RubbleSlabs",
			"min": Vector3(1.4, 0.12, 1.0), "max": Vector3(4.2, 0.35, 3.0)},
		{"mesh": bar, "count": 220, "name": "RubbleSteel",
			"min": Vector3(0.08, 0.08, 1.6), "max": Vector3(0.22, 0.22, 5.5)},
	]

	for set_def in sets:
		var placements: Array = []
		var attempts := 0
		while placements.size() < int(set_def.count) and attempts < int(set_def.count) * 6:
			attempts += 1
			var x := 0.0
			var z := 0.0
			if _rng.randf() < 0.38:
				# Along the pipe corridor: the mission funnels the pilot down
				# into this slot, so it is the ground they look at most.
				x = _rng.randf_range(-76.0, 10.0)
				z = _rng.randf_range(-2.0, 24.0)
			else:
				var a := _rng.randf() * TAU
				var r := sqrt(_rng.randf()) * 128.0 + 16.0
				x = epicentre.x + cos(a) * r
				z = epicentre.z + sin(a) * r
			if Vector2(x, z).distance_to(PAD_CENTRE) < PAD_CLEAR_RADIUS:
				continue                       # the staging area stays swept
			var lo: Vector3 = set_def.min
			var hi: Vector3 = set_def.max
			var size := Vector3(
				_rng.randf_range(lo.x, hi.x),
				_rng.randf_range(lo.y, hi.y),
				_rng.randf_range(lo.z, hi.z))
			placements.append([
				Vector3(x, terrain_height(x, z) + size.y * 0.35, z), size,
				Vector3(_rng.randf_range(-22.0, 22.0), _rng.randf_range(0.0, 360.0),
					_rng.randf_range(-22.0, 22.0)),
				_rng.randf_range(0.66, 1.0)])

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = set_def.mesh
		mm.instance_count = placements.size()
		for i in placements.size():
			var e: Array = placements[i]
			var angles: Vector3 = e[2]
			var basis := Basis.from_euler(Vector3(deg_to_rad(angles.x),
				deg_to_rad(angles.y), deg_to_rad(angles.z))).scaled(e[1] as Vector3)
			mm.set_instance_transform(i, Transform3D(basis, e[0] as Vector3))
			var shade: float = e[3]
			mm.set_instance_color(i, Color(shade, shade, shade))

		var node := MultiMeshInstance3D.new()
		node.name = str(set_def.name)
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_structures.add_child(node)


## Where the drone lives.
##
## The operator launches from the roof of the response van and recovers to it,
## so the deck is a real collision surface the aircraft can sit on, marked
## clearly enough to aim at from a hundred metres up on the way home.
func launch_position() -> Vector3:
	var base := Vector3(PAD_CENTRE.x,
		terrain_height(PAD_CENTRE.x, PAD_CENTRE.y), PAD_CENTRE.y)
	return base + Basis(Vector3.UP, deg_to_rad(VAN_YAW_DEGREES)) * VAN_PAD_OFFSET


func _build_staging_area() -> void:
	var base := Vector3(PAD_CENTRE.x,
		terrain_height(PAD_CENTRE.x, PAD_CENTRE.y), PAD_CENTRE.y)
	var van := Node3D.new()
	van.name = "ResponseVan"
	van.position = base
	# Nose pointed into the site, so leaving the deck is flying forward.
	van.rotation_degrees.y = VAN_YAW_DEGREES
	_structures.add_child(van)

	_build_van_body(van)
	_build_van_deck(van)
	_build_van_lights(van)
	_dress_staging_area(base)


func _van_materials() -> Dictionary:
	var shell := StandardMaterial3D.new()
	shell.albedo_color = Color(0.86, 0.87, 0.88)
	shell.roughness = 0.45
	shell.metallic = 0.35

	var trim := StandardMaterial3D.new()
	trim.albedo_color = Color(0.86, 0.33, 0.06)
	trim.roughness = 0.42
	trim.metallic = 0.1

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.07, 0.10, 0.12)
	glass.roughness = 0.12
	glass.metallic = 0.85

	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.06, 0.06, 0.07)
	rubber.roughness = 0.95

	var deck := StandardMaterial3D.new()
	deck.albedo_color = Color(0.14, 0.15, 0.17)
	deck.roughness = 0.8

	return {"shell": shell, "trim": trim, "glass": glass, "rubber": rubber,
		"deck": deck}


func _build_van_body(van: Node3D) -> void:
	var m := _van_materials()

	# Box body, cab, and the sill that ties them together.
	_slab(Vector3(2.16, 1.78, 3.70), Vector3(0.0, 1.50, 0.75), Vector3.ZERO,
		m.shell, van)
	_slab(Vector3(2.04, 1.22, 1.78), Vector3(0.0, 1.22, -1.94), Vector3.ZERO,
		m.shell, van)
	_slab(Vector3(2.10, 0.30, 5.40), Vector3(0.0, 0.66, -0.25), Vector3.ZERO,
		m.rubber, van)

	# Windscreen and cab side glass.
	_slab(Vector3(1.86, 0.86, 0.10), Vector3(0.0, 1.46, -2.80),
		Vector3(-16.0, 0.0, 0.0), m.glass, van)
	for side in [-1.0, 1.0]:
		_slab(Vector3(0.06, 0.62, 1.10), Vector3(1.02 * side, 1.46, -1.96),
			Vector3.ZERO, m.glass, van)

	# Livery: an orange band down each flank and across the tail.
	for side in [-1.0, 1.0]:
		_slab(Vector3(0.05, 0.34, 3.66), Vector3(1.09 * side, 1.20, 0.75),
			Vector3.ZERO, m.trim, van)
	_slab(Vector3(2.12, 0.34, 0.05), Vector3(0.0, 1.20, 2.62), Vector3.ZERO,
		m.trim, van)

	# Wheels.
	for wheel in [Vector3(-1.02, 0.44, -1.62), Vector3(1.02, 0.44, -1.62),
			Vector3(-1.02, 0.44, 1.62), Vector3(1.02, 0.44, 1.62)]:
		var tyre := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.44
		cyl.bottom_radius = 0.44
		cyl.height = 0.28
		cyl.radial_segments = 18
		tyre.mesh = cyl
		tyre.material_override = m.rubber
		tyre.position = wheel
		tyre.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		tyre.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		van.add_child(tyre)

	# A warm engine bay: the van is the first thing the thermal camera sees, and
	# a vehicle that has just been driven in reads hot across the bonnet.
	if not Engine.is_editor_hint():
		Hazards.register_heat_capsule(van, Vector3(0.0, 0.9, -2.2),
			Vector3(0.0, 0.9, -1.4), 0.55, 38.0, true, 0.25,
			Hazards.HeatKind.MACHINE)


## The landing deck: a raised plate on the box roof with a marked touchdown
## circle, so it is obvious both where to take off from and what to aim at on
## the way back.
func _build_van_deck(van: Node3D) -> void:
	var m := _van_materials()
	var y := VAN_DECK_HEIGHT

	_slab(Vector3(2.24, 0.10, 3.80), Vector3(0.0, y - 0.05, 0.75), Vector3.ZERO,
		m.deck, van)

	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.94, 0.58, 0.14)
	paint.roughness = 0.9
	paint.emission_enabled = true
	paint.emission = Color(0.9, 0.5, 0.12)
	paint.emission_energy_multiplier = 0.35

	# Touchdown circle, drawn as a ring of short segments.
	var segments := 28
	for i in segments:
		var a := TAU * float(i) / float(segments)
		var seg := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.11, 0.012, 0.030)
		seg.mesh = box
		seg.material_override = paint
		seg.position = Vector3(cos(a) * 0.80, y + 0.01, 0.75 + sin(a) * 0.80)
		seg.rotation.y = -a
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		van.add_child(seg)

	# Cross hairs through the middle of the circle.
	for cross in [Vector3(0.78, 0.012, 0.045), Vector3(0.045, 0.012, 0.78)]:
		var bar := MeshInstance3D.new()
		var box2 := BoxMesh.new()
		box2.size = cross
		bar.mesh = box2
		bar.material_override = paint
		bar.position = Vector3(0.0, y + 0.01, 0.75)
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		van.add_child(bar)

	# Corner posts, so the deck has an edge you can see against the ground.
	for corner in [Vector3(-1.0, 0.0, -0.95), Vector3(1.0, 0.0, -0.95),
			Vector3(-1.0, 0.0, 2.45), Vector3(1.0, 0.0, 2.45)]:
		var post := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.055, 0.22, 0.055)
		post.mesh = pb
		post.material_override = paint
		post.position = corner + Vector3(0.0, y + 0.11, 0.0)
		post.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		van.add_child(post)


func _build_van_lights(van: Node3D) -> void:
	# Light bar over the cab.
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.08, 0.08, 0.09)
	bar_mat.roughness = 0.6
	_slab(Vector3(1.70, 0.12, 0.26), Vector3(0.0, 1.90, -1.94), Vector3.ZERO,
		bar_mat, van)

	for lamp in [[-0.52, Color(1.0, 0.18, 0.16)], [0.52, Color(0.25, 0.45, 1.0)]]:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = lamp[1]
		mat.emission_enabled = true
		mat.emission = lamp[1]
		mat.emission_energy_multiplier = 4.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.44, 0.10, 0.22)
		mi.mesh = box
		mi.material_override = mat
		mi.position = Vector3(lamp[0], 1.90, -1.94)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		van.add_child(mi)

		var light := OmniLight3D.new()
		light.position = Vector3(lamp[0], 1.94, -1.94)
		light.light_color = lamp[1]
		light.light_energy = 2.2
		light.omni_range = 7.0
		light.shadow_enabled = false
		light.add_to_group(NIGHT_LIGHT_GROUP)
		van.add_child(light)

	# A worklight throwing the staging area into relief, aimed into the site.
	var work := SpotLight3D.new()
	work.name = "Worklight"
	work.position = Vector3(0.0, 2.12, -2.70)
	work.rotation_degrees = Vector3(-11.0, 0.0, 0.0)
	work.light_color = Color(1.0, 0.95, 0.86)
	work.light_energy = 4.0
	work.spot_range = 38.0
	work.spot_angle = 36.0
	work.spot_attenuation = 1.4
	work.shadow_enabled = false
	work.add_to_group(NIGHT_LIGHT_GROUP)
	van.add_child(work)


## Cordon and kit around the van. Deliberately sparse: the point of the staging
## area is that it reads as the one tidy place on the site.
func _dress_staging_area(base: Vector3) -> void:
	var arc := [-62.0, -34.0, 34.0, 62.0, 118.0, 152.0, 208.0, 242.0]
	for a in arc:
		var r := deg_to_rad(a)
		var x := base.x + sin(r) * 8.5
		var z := base.z + cos(r) * 8.5
		_place_model("concrete_road_barrier", _ground(x, z), a + 90.0, 1.0, true)

	var kit := [
		["portable_searchlight", Vector3(-4.2, 0.0, 93.2), 42.0],
		["portable_generator", Vector3(-5.0, 0.0, 95.4), 100.0],
		["wooden_crate_01", Vector3(4.4, 0.0, 94.0), 18.0],
		["plastic_crate_01", Vector3(4.9, 0.0, 95.6), 200.0],
		["metal_toolbox", Vector3(3.9, 0.0, 96.8), 72.0],
		["tool_cart", Vector3(-4.6, 0.0, 99.0), 140.0],
		["street_lamp_01", Vector3(-11.5, 0.0, 103.0), 18.0],
	]
	for entry in kit:
		var pos: Vector3 = entry[1]
		_place_model(entry[0], _ground(pos.x, pos.z), entry[2], 1.0, true)


## The rest of the response.
##
## Everything here exists to answer a question the operator would otherwise
## have to ask over the radio: where do casualties go, where can a vehicle
## actually reach, which way is the wind, and what is the fire crew already
## dealing with. It is set dressing that carries information, which is the
## only kind worth the draw calls.
func _build_forward_operating_points() -> void:
	_build_casualty_point(Vector3(26.0, 0.0, 78.0), -24.0)
	_build_fire_appliance(Vector3(38.0, 0.0, 32.0), 158.0)
	_build_access_route()
	_build_wind_mast(Vector3(-20.0, 0.0, 84.0))
	_build_hazard_boards()
	_build_collapsed_crane()


# --------------------------------------------------------------- vehicles

## A boxed-body emergency vehicle: chassis, cab, glass, livery band, wheels and
## a light bar. The response van, the ambulance and the fire appliance are all
## this shape at different sizes and colours, so there is one thing to fix when
## a vehicle looks wrong.
func _build_box_vehicle(parent: Node3D, length: float, width: float,
		body_height: float, livery: Color, shell_colour: Color,
		bar_colours: Array) -> void:
	var shell := StandardMaterial3D.new()
	shell.albedo_color = shell_colour
	shell.roughness = 0.45
	shell.metallic = 0.3

	var trim := StandardMaterial3D.new()
	trim.albedo_color = livery
	trim.roughness = 0.42

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.07, 0.10, 0.12)
	glass.roughness = 0.12
	glass.metallic = 0.85

	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.06, 0.06, 0.07)
	rubber.roughness = 0.95

	var box_len := length * 0.62
	var cab_len := length * 0.30
	var floor_y := 0.66
	var box_z := length * 0.5 - box_len * 0.5 - 0.1
	var cab_z := -length * 0.5 + cab_len * 0.5 + 0.1

	_slab(Vector3(width, body_height, box_len),
		Vector3(0.0, floor_y + body_height * 0.5, box_z), Vector3.ZERO, shell, parent)
	_slab(Vector3(width * 0.94, body_height * 0.70, cab_len),
		Vector3(0.0, floor_y + body_height * 0.35, cab_z), Vector3.ZERO, shell, parent)
	_slab(Vector3(width * 0.97, 0.30, length),
		Vector3(0.0, floor_y, 0.0), Vector3.ZERO, rubber, parent)

	_slab(Vector3(width * 0.86, body_height * 0.48, 0.10),
		Vector3(0.0, floor_y + body_height * 0.52, cab_z - cab_len * 0.5),
		Vector3(-16.0, 0.0, 0.0), glass, parent)

	for side in [-1.0, 1.0]:
		_slab(Vector3(0.05, body_height * 0.20, box_len * 0.99),
			Vector3(width * 0.5 * side, floor_y + body_height * 0.30, box_z),
			Vector3.ZERO, trim, parent)
	_slab(Vector3(width, body_height * 0.20, 0.05),
		Vector3(0.0, floor_y + body_height * 0.30, box_z + box_len * 0.5),
		Vector3.ZERO, trim, parent)

	var axle := length * 0.30
	for wheel in [Vector3(-width * 0.47, 0.44, -axle), Vector3(width * 0.47, 0.44, -axle),
			Vector3(-width * 0.47, 0.44, axle), Vector3(width * 0.47, 0.44, axle)]:
		var tyre := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.44
		cyl.bottom_radius = 0.44
		cyl.height = 0.28
		cyl.radial_segments = 16
		tyre.mesh = cyl
		tyre.material_override = rubber
		tyre.position = wheel
		tyre.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		tyre.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(tyre)

	_build_light_bar(parent, Vector3(0.0, floor_y + body_height * 0.72, cab_z),
		width * 0.8, bar_colours)


## A roof light bar. The lamps are always lit as emissive panels; the actual
## OmniLights only exist after dark, where they are worth their cost.
func _build_light_bar(parent: Node3D, pos: Vector3, width: float,
		colours: Array) -> void:
	var housing := StandardMaterial3D.new()
	housing.albedo_color = Color(0.08, 0.08, 0.09)
	housing.roughness = 0.6
	_slab(Vector3(width, 0.12, 0.26), pos, Vector3.ZERO, housing, parent)

	for i in colours.size():
		var colour: Color = colours[i]
		var offset := (float(i) - (colours.size() - 1) * 0.5) * (width * 0.52)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colour
		mat.emission_enabled = true
		mat.emission = colour
		mat.emission_energy_multiplier = 4.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(width * 0.42, 0.10, 0.22)
		mi.mesh = box
		mi.material_override = mat
		mi.position = pos + Vector3(offset, 0.0, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)

		var light := OmniLight3D.new()
		light.position = mi.position + Vector3(0.0, 0.05, 0.0)
		light.light_color = colour
		light.light_energy = 2.4
		light.omni_range = 8.0
		light.shadow_enabled = false
		light.add_to_group(NIGHT_LIGHT_GROUP)
		parent.add_child(light)


# ------------------------------------------------------- casualty point

## Where the people you find are going to end up. A canopy, stretchers laid out
## in triage order, and a lit ground square, so the operator can see that the
## survivors they are tagging have somewhere to be taken to.
func _build_casualty_point(pos: Vector3, yaw: float) -> void:
	var root := Node3D.new()
	root.name = "CasualtyCollectionPoint"
	root.position = _ground(pos.x, pos.z)
	root.rotation_degrees.y = yaw
	_structures.add_child(root)

	var canvas := StandardMaterial3D.new()
	canvas.albedo_color = Color(0.88, 0.86, 0.78)
	canvas.roughness = 0.95
	canvas.cull_mode = BaseMaterial3D.CULL_DISABLED

	var frame := StandardMaterial3D.new()
	frame.albedo_color = Color(0.55, 0.57, 0.60)
	frame.metallic = 0.6
	frame.roughness = 0.4

	# canopy roof and its four legs
	# A shallow pitched roof rather than a flat slab - a flat white square
	# hanging on four wires reads as a floating table from the air.
	for pitch in [-1.0, 1.0]:
		_slab(Vector3(6.2, 0.09, 3.3), Vector3(0.0, 2.80 + 0.18 * 0.0, 1.55 * pitch),
			Vector3(7.0 * pitch, 0.0, 0.0), canvas, root)
	for leg in [Vector3(-2.9, 0.0, -2.9), Vector3(2.9, 0.0, -2.9),
			Vector3(-2.9, 0.0, 2.9), Vector3(2.9, 0.0, 2.9)]:
		_slab(Vector3(0.12, 2.78, 0.12), leg + Vector3(0.0, 1.39, 0.0),
			Vector3.ZERO, frame, root)
	# waist rails, so the frame is legible from above
	for rail in [-2.9, 2.9]:
		_slab(Vector3(0.07, 0.07, 5.8), Vector3(rail, 1.55, 0.0), Vector3.ZERO,
			frame, root)

	# Triage stretchers, in the standard order: immediate, delayed, minor.
	var triage := [Color(0.85, 0.12, 0.12), Color(0.95, 0.75, 0.12),
		Color(0.20, 0.72, 0.30)]
	for i in triage.size():
		var mat := StandardMaterial3D.new()
		mat.albedo_color = triage[i]
		mat.roughness = 0.85
		# Laid out in front of the canopy rather than under it: triage bays
		# work in the open, and from the air a stretcher under a roof is a
		# stretcher nobody can see.
		var x := -2.4 + float(i) * 2.4
		_slab(Vector3(0.78, 0.09, 2.10), Vector3(x, 0.46, 5.0), Vector3.ZERO,
			mat, root)
		for end in [-0.9, 0.9]:
			_slab(Vector3(0.70, 0.42, 0.06), Vector3(x, 0.21, 5.0 + end),
				Vector3.ZERO, frame, root)
		# A painted bay square, so the triage order reads from directly above.
		var paint := mat.duplicate() as StandardMaterial3D
		paint.emission_enabled = true
		paint.emission = triage[i]
		paint.emission_energy_multiplier = 0.5
		_slab(Vector3(2.10, 0.03, 0.14), Vector3(x, 0.02, 3.8), Vector3.ZERO,
			paint, root)

	# A lit square so it reads as somewhere staffed, not an abandoned tent.
	var glow := SpotLight3D.new()
	glow.position = Vector3(0.0, 2.55, 0.0)
	glow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	glow.light_color = Color(1.0, 0.96, 0.88)
	glow.light_energy = 5.0
	glow.spot_range = 12.0
	glow.spot_angle = 58.0
	glow.shadow_enabled = false
	glow.add_to_group(NIGHT_LIGHT_GROUP)
	root.add_child(glow)

	# The ambulance waiting to take them off site.
	var amb := Node3D.new()
	amb.name = "Ambulance"
	amb.position = Vector3(-7.2, 0.0, 1.5)
	amb.rotation_degrees.y = 12.0
	root.add_child(amb)
	_build_box_vehicle(amb, 5.2, 2.05, 1.70, Color(0.85, 0.20, 0.16),
		Color(0.90, 0.91, 0.92),
		[Color(1.0, 0.18, 0.16), Color(0.25, 0.45, 1.0)])

	if Engine.is_editor_hint():
		return

	var sign := Detectable.new()
	sign.kind = Sim.FindingKind.MARKER
	sign.label = "Casualty collection point"
	sign.detail = ("Triage and ambulance loading. Every survivor you tag is "
		+ "extracted to here, so the access route between this point and the "
		+ "rubble is the one that has to stay open.")
	sign.recommended_action = "Keep the marked route clear for stretcher parties."
	sign.severity = Sim.Severity.INFO
	sign.detection_radius = 3.2
	sign.max_detect_range = 95.0
	sign.position = root.position + Vector3(0.0, 2.9, 0.0)
	_hazards.add_child(sign)


func _build_fire_appliance(pos: Vector3, yaw: float) -> void:
	var truck := Node3D.new()
	truck.name = "FireAppliance"
	truck.position = _ground(pos.x, pos.z)
	truck.rotation_degrees.y = yaw
	_structures.add_child(truck)
	_build_box_vehicle(truck, 7.2, 2.40, 2.10, Color(0.80, 0.12, 0.10),
		Color(0.62, 0.10, 0.09),
		[Color(1.0, 0.16, 0.14), Color(1.0, 0.16, 0.14)])

	# Ladder along the roof, and the deck monitor it is working the fire with.
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.70, 0.72, 0.74)
	steel.metallic = 0.75
	steel.roughness = 0.35
	for rail in [-0.55, 0.55]:
		_slab(Vector3(0.07, 0.07, 5.4), Vector3(rail, 2.95, 0.6), Vector3.ZERO,
			steel, truck)
	for i in 9:
		_slab(Vector3(1.10, 0.05, 0.05),
			Vector3(0.0, 2.95, -1.9 + float(i) * 0.62), Vector3.ZERO, steel, truck)

	var monitor := SpotLight3D.new()
	monitor.position = Vector3(0.0, 3.2, -1.0)
	monitor.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	monitor.light_color = Color(1.0, 0.94, 0.84)
	monitor.light_energy = 6.0
	monitor.spot_range = 46.0
	monitor.spot_angle = 30.0
	monitor.shadow_enabled = false
	monitor.add_to_group(NIGHT_LIGHT_GROUP)
	truck.add_child(monitor)

	if not Engine.is_editor_hint():
		Hazards.register_heat_capsule(truck, Vector3(0.0, 1.0, -2.6),
			Vector3(0.0, 1.0, -1.6), 0.6, 41.0, true, 0.3,
			Hazards.HeatKind.MACHINE)


# --------------------------------------------------------- access route

## The only route a vehicle can take from the staging area to the collapse,
## marked on the ground in cones - and the point where it is blocked, which is
## the single most useful thing an assessment flight can report.
func _build_access_route() -> void:
	var waypoints := [
		Vector2(4.0, 88.0), Vector2(10.0, 76.0), Vector2(14.0, 62.0),
		Vector2(12.0, 48.0), Vector2(2.0, 36.0), Vector2(-14.0, 28.0),
		Vector2(-26.0, 22.0),
	]
	var cone := StandardMaterial3D.new()
	cone.albedo_color = Color(0.95, 0.42, 0.08)
	cone.roughness = 0.8
	cone.emission_enabled = true
	cone.emission = Color(0.9, 0.35, 0.05)
	cone.emission_energy_multiplier = 0.3

	# Every cone in one MultiMesh: there are a hundred of them along the route
	# and they are identical, so they cost one draw call instead of a hundred.
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.03
	mesh.bottom_radius = 0.21
	mesh.height = 0.56
	mesh.radial_segments = 8
	mesh.rings = 1
	mesh.material = cone

	var placements: Array[Vector3] = []
	for i in waypoints.size() - 1:
		var a: Vector2 = waypoints[i]
		var b: Vector2 = waypoints[i + 1]
		var steps := int(maxf(a.distance_to(b) / 4.5, 1.0))
		for k in steps:
			var t := float(k) / float(steps)
			var p := a.lerp(b, t)
			for side: float in [-1.6, 1.6]:
				var n: Vector2 = (b - a).normalized().orthogonal() * side
				placements.append(_ground(p.x + n.x, p.y + n.y, 0.28))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = placements.size()
	for i in placements.size():
		mm.set_instance_transform(i, Transform3D(Basis(), placements[i]))

	var cones := MultiMeshInstance3D.new()
	cones.name = "RouteCones"
	cones.multimesh = mm
	cones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cones.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_props.add_child(cones)

	# Where the route dies: a slab across it. This is a finding, not scenery.
	var block := Vector2(2.0, 36.0)
	var broken := Materials.broken_concrete()
	_slab(Vector3(7.6, 1.1, 2.4), _ground(block.x, block.y, 0.5),
		Vector3(6.0, 28.0, 9.0), broken)
	_slab(Vector3(5.2, 0.9, 2.0), _ground(block.x - 3.4, block.y + 1.6, 0.4),
		Vector3(-4.0, 52.0, -7.0), broken)

	if Engine.is_editor_hint():
		return

	var d := Detectable.new()
	d.kind = Sim.FindingKind.STRUCTURAL
	d.label = "Access route blocked"
	d.detail = ("A wall panel has come down across the only vehicle route "
		+ "between the staging area and the collapse. Until it is cleared, "
		+ "everything past this point is a carry, not a drive.")
	d.recommended_action = ("Plant and lifting gear to this point first. "
		+ "Clearing it is worth more than any other single task on site.")
	d.severity = Sim.Severity.WARNING
	d.detection_radius = 3.0
	d.max_detect_range = 85.0
	d.position = _ground(block.x, block.y, 2.2)
	_hazards.add_child(d)


## Wind mast at the staging area. The plumes drift downwind, so knowing which
## way the wind is blowing is the difference between flying around a cloud and
## flying through it - and the HUD number needs something in the world to
## agree with.
func _build_wind_mast(pos: Vector3) -> void:
	var mast := Node3D.new()
	mast.name = "WindMast"
	mast.position = _ground(pos.x, pos.z)
	_structures.add_child(mast)

	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.72, 0.74, 0.76)
	steel.metallic = 0.7
	steel.roughness = 0.35
	_slab(Vector3(0.10, 6.0, 0.10), Vector3(0.0, 3.0, 0.0), Vector3.ZERO,
		steel, mast)

	var sock_mat := StandardMaterial3D.new()
	sock_mat.albedo_color = Color(0.96, 0.45, 0.06)
	sock_mat.roughness = 0.9
	sock_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var sock := MeshInstance3D.new()
	sock.name = "Windsock"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.42
	cone.bottom_radius = 0.16
	cone.height = 2.2
	cone.radial_segments = 12
	sock.mesh = cone
	sock.material_override = sock_mat
	sock.position = Vector3(0.0, 5.7, 0.0)
	sock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mast.add_child(sock)
	_windsock = sock


# ------------------------------------------------------- hazard signage

## Warning boards at the two places where an unbriefed rescuer would walk into
## something that would kill them.
func _build_hazard_boards() -> void:
	var boards := [
		[Vector3(-44.0, 0.0, -50.0), 24.0, Color(0.95, 0.78, 0.10),
			"Silo exclusion zone"],
		[Vector3(-42.0, 0.0, 16.0), -68.0, Color(0.92, 0.20, 0.16),
			"Flammable atmosphere"],
		[Vector3(24.0, 0.0, 44.0), 150.0, Color(0.92, 0.20, 0.16),
			"Active fire - no entry"],
	]
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.45, 0.46, 0.48)
	post_mat.metallic = 0.5
	post_mat.roughness = 0.5

	for b in boards:
		var pos: Vector3 = b[0]
		var root := Node3D.new()
		root.name = "Sign_%s" % str(b[3]).replace(" ", "_")
		root.position = _ground(pos.x, pos.z)
		root.rotation_degrees.y = b[1]
		_structures.add_child(root)

		_slab(Vector3(0.08, 2.0, 0.08), Vector3(-0.7, 1.0, 0.0), Vector3.ZERO,
			post_mat, root)
		_slab(Vector3(0.08, 2.0, 0.08), Vector3(0.7, 1.0, 0.0), Vector3.ZERO,
			post_mat, root)

		var face := StandardMaterial3D.new()
		face.albedo_color = b[2]
		face.roughness = 0.75
		face.emission_enabled = true
		face.emission = b[2]
		face.emission_energy_multiplier = 0.45
		_slab(Vector3(1.9, 1.2, 0.07), Vector3(0.0, 2.1, 0.0), Vector3.ZERO,
			face, root)

		var bar := StandardMaterial3D.new()
		bar.albedo_color = Color(0.06, 0.06, 0.07)
		bar.roughness = 0.8
		for stripe in [-0.32, 0.0, 0.32]:
			_slab(Vector3(1.7, 0.12, 0.02), Vector3(0.0, 2.1 + stripe, 0.05),
				Vector3.ZERO, bar, root)


## The quay crane came down across the container yard. It is the biggest
## silhouette on the site after the silos and it is the reason the yard is an
## exclusion zone rather than a place to stage from.
##
## Built as one connected structure - portal legs, sill beams, a boom hinged at
## the top of the standing leg and dropped across the stacks - because a crane
## drawn as separate floating members reads as debris, not as a machine that
## has failed.
func _build_collapsed_crane() -> void:
	var steel := Materials.rusted_steel()
	var root := Node3D.new()
	root.name = "CollapsedCrane"
	root.position = _ground(38.0, 52.0)
	root.rotation_degrees.y = -12.0
	_structures.add_child(root)

	# Standing portal: two columns, a head beam across them, and the rail sill
	# they run on. This half is still up.
	for x in [-5.2, 5.2]:
		_slab(Vector3(1.1, 14.0, 1.1), Vector3(x, 7.0, 10.0),
			Vector3(0.0, 0.0, -3.0 * signf(x)), steel, root)
		_slab(Vector3(2.2, 0.9, 3.4), Vector3(x, 0.45, 10.0), Vector3.ZERO,
			steel, root)
	_slab(Vector3(12.4, 1.3, 1.6), Vector3(0.0, 14.3, 10.0), Vector3.ZERO,
		steel, root)
	# diagonal bracing between the legs, so the portal reads as a frame
	for sign in [-1.0, 1.0]:
		_slab(Vector3(11.6, 0.55, 0.55), Vector3(0.0, 7.6, 10.0),
			Vector3(0.0, 0.0, 34.0 * sign), steel, root)

	# The boom: hinged at the head beam, dropped across the stacks. One slab,
	# so both ends actually meet something.
	_slab(Vector3(1.8, 1.8, 32.0), Vector3(0.0, 8.6, -5.0),
		Vector3(-19.6, 0.0, 0.0), steel, root)
	# tie bars from the head down the length of the boom
	for x in [-1.3, 1.3]:
		_slab(Vector3(0.35, 0.35, 26.0), Vector3(x, 10.4, -2.0),
			Vector3(-19.6, 0.0, 0.0), steel, root)

	# Machinery house, sitting on the boom just outboard of the hinge.
	_slab(Vector3(3.8, 3.0, 4.6), Vector3(0.0, 14.0, 5.4),
		Vector3(-19.6, 0.0, 0.0), steel, root)

	# The far leg has buckled and is lying across the yard under the boom.
	_slab(Vector3(1.1, 12.0, 1.1), Vector3(-2.4, 1.4, -14.0),
		Vector3(74.0, 8.0, 0.0), steel, root)
	_slab(Vector3(2.2, 0.9, 3.4), Vector3(-5.0, 0.6, -19.4),
		Vector3(12.0, 26.0, 8.0), steel, root)

	if Engine.is_editor_hint():
		return

	var d := Detectable.new()
	d.kind = Sim.FindingKind.STRUCTURAL
	d.label = "Collapsed quay crane"
	d.detail = ("The gantry has folded across the container yard, the boom "
		+ "still under load and resting on the stacks. The standing leg is out "
		+ "of plumb and the whole structure is one aftershock from moving.")
	d.recommended_action = ("Treat the yard as an exclusion zone. Survey the "
		+ "containers underneath by air only.")
	d.severity = Sim.Severity.WARNING
	d.detection_radius = 7.0
	d.max_detect_range = 130.0
	d.position = root.position + Vector3(0.0, 9.0, 2.0)
	_hazards.add_child(d)


## The grain silos were the defining silhouette of the Beirut port after the
## blast, so a simplified mass is modelled even though the rest of the port is
## abstract. The near half is torn open - that is the entry the mission uses.
func _build_silos(concrete: StandardMaterial3D, broken: StandardMaterial3D) -> void:
	var base := Vector3(-54.0, 0.0, -66.0)
	for i in 8:
		var col := i % 4
		var row := i / 4
		var pos := base + Vector3(float(col) * 9.4, 0.0, float(row) * 9.4)
		var ground := terrain_height(pos.x, pos.z)
		var ruptured := i < 3
		var height := 17.0 if ruptured else 33.0
		var mat := broken if ruptured else concrete
		_cylinder(4.3, height, Vector3(pos.x, ground + height * 0.5 - 0.5, pos.z), mat)
		if ruptured:
			# torn concrete lip and spilled grain mass
			_slab(Vector3(9.0, 1.2, 4.0),
				Vector3(pos.x + 2.4, ground + height, pos.z - 1.0),
				Vector3(_rng.randf_range(-26.0, -8.0), _rng.randf_range(0.0, 90.0), 6.0),
				broken)


## Open steel shell with a partly collapsed roof - the obstacle course the
## pilot has to thread to reach the casualties inside.
func _build_warehouse(steel: StandardMaterial3D, concrete: StandardMaterial3D) -> void:
	var origin := Vector3(46.0, 0.0, -34.0)
	var ground := terrain_height(origin.x, origin.z)
	var bays := 5
	var span := 9.0
	var height := 11.0

	for i in bays + 1:
		for side in [-1.0, 1.0]:
			var x: float = origin.x + side * 11.0
			var z := origin.z + float(i) * span - float(bays) * span * 0.5
			var h := terrain_height(x, z)
			_cylinder(0.32, height, Vector3(x, h + height * 0.5, z), steel)
			# roof truss, dropped into the bay on the far end
			if i < bays:
				var fallen := i >= bays - 2
				var y := h + height + (-4.5 if fallen else 0.15)
				var tilt := Vector3(0.0, 0.0, _rng.randf_range(-34.0, 34.0) if fallen else 0.0)
				_slab(Vector3(23.0, 0.35, 0.9),
					Vector3(origin.x, y, z + span * 0.5), tilt, steel)

	# floor slab and a surviving end wall
	_slab(Vector3(23.0, 0.4, float(bays) * span),
		Vector3(origin.x, ground + 0.1, origin.z), Vector3.ZERO, concrete)
	_slab(Vector3(23.0, height, 0.5),
		Vector3(origin.x, ground + height * 0.5, origin.z - float(bays) * span * 0.5),
		Vector3.ZERO, concrete)


## Pancaked floor slabs with survivable voids between them.
func _build_collapsed_block(broken: StandardMaterial3D, stone: StandardMaterial3D) -> void:
	var origin := Vector3(-38.0, 0.0, 34.0)
	var ground := terrain_height(origin.x, origin.z)
	var y := ground + 0.4

	for level in 5:
		var lean := _rng.randf_range(-9.0, 9.0)
		var offset := Vector3(_rng.randf_range(-2.2, 2.2), 0.0, _rng.randf_range(-2.2, 2.2))
		_slab(Vector3(15.0, 0.42, 12.0), origin + offset + Vector3(0.0, y - ground, 0.0),
			Vector3(lean * 0.4, _rng.randf_range(-8.0, 8.0), lean), broken)
		# rubble columns hold the slab up and create the void underneath
		for c in 3:
			var cx := origin.x + _rng.randf_range(-6.0, 6.0)
			var cz := origin.z + _rng.randf_range(-5.0, 5.0)
			_slab(Vector3(1.1, 1.9, 1.1), Vector3(cx, y + 0.95, cz),
				Vector3(0.0, _rng.randf_range(0.0, 90.0), _rng.randf_range(-6.0, 6.0)),
				broken)
		y += 2.6

	# a surviving stone facade, the older Beirut construction
	_slab(Vector3(0.6, 9.0, 13.0), Vector3(origin.x - 8.4, ground + 4.5, origin.z),
		Vector3(0.0, 0.0, 6.0), stone)
	_slab(Vector3(11.0, 8.0, 0.6), Vector3(origin.x - 3.0, ground + 4.0, origin.z - 6.8),
		Vector3(-5.0, 0.0, 0.0), stone)


func _build_container_yard(steel: StandardMaterial3D) -> void:
	var origin := Vector3(24.0, 0.0, 48.0)
	var colours := [Color(0.62, 0.30, 0.24), Color(0.28, 0.42, 0.52),
		Color(0.55, 0.52, 0.30), Color(0.38, 0.45, 0.36)]
	for i in 14:
		var gx := origin.x + float(i % 5) * 7.0 + _rng.randf_range(-0.6, 0.6)
		var gz := origin.z + float(i / 5) * 3.4
		var stack := _rng.randi_range(1, 3)
		for s in stack:
			var mat := steel.duplicate() as StandardMaterial3D
			mat.albedo_color = colours[_rng.randi() % colours.size()]
			var h := terrain_height(gx, gz)
			var toppled := _rng.randf() < 0.22 and s == stack - 1
			_slab(Vector3(6.1, 2.6, 2.44),
				Vector3(gx, h + 1.35 + float(s) * 2.65, gz),
				Vector3(0.0, _rng.randf_range(-4.0, 4.0),
					_rng.randf_range(38.0, 86.0) if toppled else 0.0),
				mat)


## Two long pipe runs at low level - forces the pilot down into a slot where
## the gas actually pools.
func _build_pipe_corridor(steel: StandardMaterial3D, concrete: StandardMaterial3D) -> void:
	var z := 8.0
	for i in 9:
		var x := -70.0 + float(i) * 9.0
		var h := terrain_height(x, z)
		_slab(Vector3(1.0, 5.2, 1.0), Vector3(x, h + 2.6, z), Vector3.ZERO, concrete)
		_slab(Vector3(1.0, 5.2, 1.0), Vector3(x, h + 2.6, z + 6.0), Vector3.ZERO, concrete)
	for run in 3:
		var y := terrain_height(-40.0, z) + 4.2 + float(run) * 0.55
		_cylinder(0.34, 82.0, Vector3(-30.0, y, z + float(run) * 0.9),
			steel, Vector3(0.0, 0.0, 90.0))


func _build_quay_wall(concrete: StandardMaterial3D) -> void:
	for i in 12:
		var x := -100.0 + float(i) * 18.0
		var h := terrain_height(x, -122.0)
		_slab(Vector3(17.5, 4.0, 2.0), Vector3(x, h + 1.4, -122.0),
			Vector3(0.0, 0.0, _rng.randf_range(-3.0, 3.0)), concrete)


# ------------------------------------------------------------------ props

func _load_model(name: String) -> PackedScene:
	var path := "%s%s/%s_1k.gltf" % [MODEL_ROOT, name, name]
	if not ResourceLoader.exists(path):
		push_warning("WorldBuilder: missing model %s" % path)
		return null
	return load(path)


## Instances a downloaded prop with collision derived from its bounds.
func _place_model(name: String, pos: Vector3, yaw: float, scale := 1.0,
		collide := true, tilt := 0.0) -> Node3D:
	var packed := _load_model(name)
	if packed == null:
		return null
	var inst := packed.instantiate()
	var holder := StaticBody3D.new() if collide else Node3D.new()
	holder.position = pos
	holder.rotation_degrees = Vector3(tilt, yaw, tilt * 0.6)
	holder.add_child(inst)
	if inst is Node3D:
		inst.scale = Vector3.ONE * scale
	_props.add_child(holder)

	if collide and holder is StaticBody3D:
		var aabb := _aabb_of(inst)
		if aabb.size.length() > 0.01:
			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = aabb.size * scale
			col.shape = shape
			col.position = aabb.get_center() * scale
			holder.add_child(col)
	return holder


func _aabb_of(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for child in _all_descendants(node):
		if child is VisualInstance3D:
			var box: AABB = child.get_aabb()
			if child != node and child is Node3D:
				box = child.transform * box
			if first:
				out = box
				first = false
			else:
				out = out.merge(box)
	return out


func _all_descendants(node: Node) -> Array:
	var out := [node]
	for c in node.get_children():
		out.append_array(_all_descendants(c))
	return out


func _ground(x: float, z: float, lift := 0.0) -> Vector3:
	return Vector3(x, terrain_height(x, z) + lift, z)


func _scatter_props() -> void:
	# Heavy debris along the flight corridors, thinning out with distance.
	var scatter := {
		"boulder_01": 26,
		"rock_07": 30,
		"namaqualand_boulder_02": 22,
		"concrete_road_barrier": 16,
		"concrete_road_barrier_02": 12,
		"old_tyre": 18,
		"wooden_crate_01": 14,
		"plastic_crate_01": 12,
		"cardboard_box_01": 16,
		"cement_bag": 14,
		"dry_branches_medium_01": 18,
		"Barrel_01": 10,
		"Barrel_02": 8,
		"barrel_03": 8,
		"metal_jerrycan": 8,
	}
	for name in scatter:
		for i in int(scatter[name]) / 2:
			var angle := _rng.randf() * TAU
			var radius := sqrt(_rng.randf()) * 135.0 + 6.0
			var x := epicentre.x + cos(angle) * radius
			var z := epicentre.z + sin(angle) * radius
			# Nothing lands in the staging area: that ground is swept, and a
			# boulder spawned next to the van is the first thing the operator
			# flies into on take-off.
			if Vector2(x, z).distance_to(PAD_CENTRE) < PAD_CLEAR_RADIUS:
				continue
			_place_model(name, _ground(x, z, -0.05), _rng.randf_range(0.0, 360.0),
				_rng.randf_range(0.85, 1.5), radius < 90.0,
				_rng.randf_range(-16.0, 16.0))

	# Landmarks and set dressing, placed rather than scattered.
	var placed := [
		["covered_car", Vector3(14.0, 0.0, 62.0), 34.0, 1.0],
		["covered_car", Vector3(-22.0, 0.0, 74.0), 198.0, 1.0],
		["covered_car", Vector3(58.0, 0.0, 20.0), 96.0, 1.0],
		["portable_generator", Vector3(40.0, 0.0, -18.0), 12.0, 1.0],
		["steel_frame_shelves_01", Vector3(48.0, 0.0, -44.0), 90.0, 1.0],
		["steel_frame_shelves_01", Vector3(52.0, 0.0, -30.0), 90.0, 1.0],
		["modular_industrial_pipes_01", Vector3(-58.0, 0.0, 18.0), 0.0, 1.2],
		["modular_industrial_pipes_01", Vector3(-34.0, 0.0, 18.0), 0.0, 1.2],
		["fire_hydrant", Vector3(21.0, 0.0, 84.0), 0.0, 1.0],
		["street_lamp_01", Vector3(32.0, 0.0, 84.0), 200.0, 1.0],
		["modular_electricity_poles", Vector3(-70.0, 0.0, 66.0), 10.0, 1.0],
		["modular_electricity_poles", Vector3(-70.0, 0.0, 96.0), 10.0, 1.0],
		["dead_tree_trunk", Vector3(-16.0, 0.0, 58.0), 40.0, 1.3],
		["dead_tree_trunk_02", Vector3(66.0, 0.0, 52.0), 120.0, 1.1],
		["modular_chainlink_fence", Vector3(0.0, 0.0, 116.0), 0.0, 1.0],
		["modular_chainlink_fence", Vector3(12.0, 0.0, 116.0), 0.0, 1.0],
		["modular_chainlink_fence", Vector3(-12.0, 0.0, 116.0), 0.0, 1.0],
		["modular_chainlink_fence", Vector3(24.0, 0.0, 116.0), 0.0, 1.0],
		["modular_chainlink_fence", Vector3(-24.0, 0.0, 116.0), 0.0, 1.0],
	]
	for entry in placed:
		var pos: Vector3 = entry[1]
		if Vector2(pos.x, pos.z).distance_to(PAD_CENTRE) < PAD_CLEAR_RADIUS:
			continue
		_place_model(entry[0], _ground(pos.x, pos.z), entry[2], entry[3], true,
			_rng.randf_range(-6.0, 6.0))


## Drop-in point for models the rest of the team produces.
##
## Put .glb/.gltf files in assets/team/ and describe where they go in
## assets/team/placement.json. Nothing here is required - if the file is
## missing the scene builds exactly as before - so the two halves of the
## project can be worked on independently and merged by adding one file.
##
## placement.json:
##   [
##     {"model": "warehouse_ruin.glb", "position": [40, 0, -30], "yaw": 90,
##      "scale": 1.0, "collide": true, "snap_to_ground": true}
##   ]
func _place_team_assets() -> void:
	const MANIFEST := "res://assets/team/placement.json"
	if not ResourceLoader.exists(MANIFEST) and not FileAccess.file_exists(MANIFEST):
		return
	var text := FileAccess.get_file_as_string(MANIFEST)
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Array):
		push_warning("assets/team/placement.json: expected a JSON array")
		return

	var placed := 0
	for entry in parsed:
		if not (entry is Dictionary) or not entry.has("model"):
			continue
		var path: String = "res://assets/team/%s" % entry.model
		if not ResourceLoader.exists(path):
			push_warning("team asset not found: %s" % path)
			continue
		var packed: PackedScene = load(path)
		if packed == null:
			continue

		var pos_array: Array = entry.get("position", [0, 0, 0])
		var pos := Vector3(pos_array[0], pos_array[1], pos_array[2])
		if bool(entry.get("snap_to_ground", true)):
			pos.y += terrain_height(pos.x, pos.z)

		var holder: Node3D = (StaticBody3D.new() if bool(entry.get("collide", true))
			else Node3D.new())
		holder.name = String(entry.model).get_basename()
		holder.position = pos
		holder.rotation_degrees = Vector3(0.0, float(entry.get("yaw", 0.0)), 0.0)

		var inst := packed.instantiate()
		if inst is Node3D:
			inst.scale = Vector3.ONE * float(entry.get("scale", 1.0))
		holder.add_child(inst)
		_structures.add_child(holder)

		if holder is StaticBody3D:
			var aabb := _aabb_of(inst)
			if aabb.size.length() > 0.01:
				var col := CollisionShape3D.new()
				var shape := BoxShape3D.new()
				var sc := float(entry.get("scale", 1.0))
				shape.size = aabb.size * sc
				col.shape = shape
				col.position = aabb.get_center() * sc
				holder.add_child(col)
		placed += 1

	if placed > 0:
		print("[world] placed %d team assets" % placed)


# --------------------------------------------------------------- hazards

func _place_hazards() -> void:
	_place_gas_leaks()
	_scatter_minor_sources()
	_place_fires()
	_place_victims()
	_place_structural()


func _place_gas_leaks() -> void:
	# (model, gas, strength, radius, length, position, note)
	var leaks := [
		["small_lpg_tank", Hazards.Gas.LEL, 78.0, 3.4, 30.0, Vector3(-46.0, 0.0, 10.0),
			"Ruptured LPG line under the pipe rack"],
		["propane_tank", Hazards.Gas.LEL, 55.0, 2.6, 22.0, Vector3(44.0, 0.0, -22.0),
			"Propane cylinder venting inside the warehouse"],
		["", Hazards.Gas.NO2, 14.0, 9.0, 46.0, Vector3(-6.0, 0.0, -20.0),
			"Residual nitrogen dioxide over the detonation seat"],
		["", Hazards.Gas.H2S, 34.0, 4.2, 18.0, Vector3(-34.0, 0.0, 40.0),
			"Hydrogen sulphide from the drainage void under the collapse"],
		["metal_jerrycan", Hazards.Gas.CO, 260.0, 3.0, 26.0, Vector3(26.0, 0.0, 44.0),
			"Fuel fire smouldering in the container yard"],
		["", Hazards.Gas.O2, 3.8, 5.0, 8.0, Vector3(-52.0, 0.0, -60.0),
			"Oxygen-deficient atmosphere inside the ruptured silo"],
	]

	for leak in leaks:
		var pos: Vector3 = leak[5]
		var ground := _ground(pos.x, pos.z, 0.6)
		if leak[0] != "":
			_place_model(leak[0], _ground(pos.x, pos.z), _rng.randf_range(0.0, 360.0),
				1.0, true)

		# An O2 source is a pocket of inert gas: its strength is the %vol drop.
		var gas: int = leak[1]
		var strength: float = leak[2]

		var source := GasSource.new()
		source.name = "GasSource_%s" % Hazards.GAS_NAMES[leak[1]]
		source.gas = gas
		source.strength = strength
		source.plume_radius = leak[3]
		source.plume_length = leak[4]
		source.label = leak[6]
		source.visible_vapour = gas == Hazards.Gas.LEL or gas == Hazards.Gas.NO2
		source.position = ground
		_hazards.add_child(source)


## Dozens of small, unreported sources - smouldering piles, broken drains,
## fuel spills, nitrate residue round the crater. None is a finding on its
## own; together they are why the detector never reads a flat line, the way a
## real one flown over a disaster site does not.
func _scatter_minor_sources() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 77
	# [gas, count, strength range, radius range, length range, ring min/max from seat]
	var kinds := [
		[Hazards.Gas.CO, 16, Vector2(40, 160), Vector2(1.4, 2.4), Vector2(12, 22), Vector2(15, 110)],
		[Hazards.Gas.H2S, 10, Vector2(8, 30), Vector2(1.2, 2.0), Vector2(10, 16), Vector2(30, 120)],
		[Hazards.Gas.LEL, 10, Vector2(10, 32), Vector2(1.4, 2.2), Vector2(10, 16), Vector2(20, 120)],
		[Hazards.Gas.NO2, 12, Vector2(1.5, 6.0), Vector2(3.0, 5.0), Vector2(18, 30), Vector2(18, 70)],
	]
	for k in kinds:
		for i in int(k[1]):
			var a := rng.randf() * TAU
			var r := rng.randf_range(k[5].x, k[5].y)
			var x := epicentre.x + cos(a) * r
			var z := epicentre.z + sin(a) * r
			var node := Node3D.new()
			node.name = "Minor_%s_%d" % [Hazards.GAS_NAMES[k[0]], i]
			node.position = _ground(x, z, 0.5)
			_hazards.add_child(node)
			Hazards.register_plume(node, k[0], rng.randf_range(k[2].x, k[2].y),
				rng.randf_range(k[3].x, k[3].y), rng.randf_range(k[4].x, k[4].y), 1.6, true)
			if int(k[0]) == Hazards.Gas.CO:
				# smouldering debris: shows warm in thermal
				Hazards.register_heat_capsule(node, Vector3.ZERO, Vector3.ZERO,
					rng.randf_range(0.5, 1.0), rng.randf_range(55.0, 105.0), true, 0.6,
					Hazards.HeatKind.SMOULDER)
			elif int(k[0]) == Hazards.Gas.H2S and i % 2 == 0:
				_place_model("water_manhole_cover", node.position, rng.randf_range(0, 360),
					1.0, false, rng.randf_range(-20.0, 20.0))


func _place_fires() -> void:
	var fires := [
		[Vector3(30.0, 0.0, 40.0), 1.35, "Container yard fire"],
		[Vector3(-18.0, 0.0, -44.0), 0.9, "Burning debris on the silo apron"],
		[Vector3(52.0, 0.0, -8.0), 0.65, "Vehicle fire at the warehouse door"],
	]
	for f in fires:
		var pos: Vector3 = f[0]
		var fire := FireSource.new()
		fire.name = "Fire_%s" % str(f[2]).replace(" ", "_")
		fire.intensity = f[1]
		fire.label = f[2]
		fire.position = _ground(pos.x, pos.z, 0.1)
		_hazards.add_child(fire)


## Fallback placement, used only when the scene does not provide survivors of
## its own. The authored copies in scenes/main.tscn are the ones to edit.
func _place_victims() -> void:
	if not place_victims:
		return
	var casualties := [
		[Vector3(44.0, 0.0, -40.0), Victim.Pose.TRAPPED, 0.6,
			"Casualty under the collapsed warehouse truss"],
		[Vector3(-36.0, 0.0, 32.0), Victim.Pose.PRONE, 3.2,
			"Casualty in the void under the pancaked slabs"],
		[Vector3(-40.0, 0.0, 38.0), Victim.Pose.SEATED, 3.2,
			"Second casualty, same void"],
		[Vector3(22.0, 0.0, 52.0), Victim.Pose.WAVING, 2.8,
			"Ambulatory survivor on the container stack"],
		[Vector3(-56.0, 0.0, -62.0), Victim.Pose.SEATED, 0.5,
			"Casualty inside the ruptured silo"],
		[Vector3(-44.0, 0.0, 18.0), Victim.Pose.PRONE, 0.35,
			"Casualty beside the pipe rack"],
	]
	for c in casualties:
		var pos: Vector3 = c[0]
		var v := Victim.new()
		v.pose = c[1]
		v.label = c[3]
		v.responsive = c[1] != Victim.Pose.PRONE
		v.position = _ground(pos.x, pos.z, c[2])
		v.rotation_degrees.y = _rng.randf_range(0.0, 360.0)
		_hazards.add_child(v)


func _place_structural() -> void:
	var sites := [
		[Vector3(-46.0, 6.0, -66.0), "Ruptured silo wall",
			"Vertical crack running the full height of the silo shell. Any "
			+ "further movement drops several hundred tonnes onto the apron "
			+ "below, which is the only vehicle route into the site.",
			"Exclusion zone 30 m. Survey by air only."],
		[Vector3(-30.0, 9.0, 34.0), "Unsupported slab edge",
			"The upper floor slab is cantilevered over the void with no "
			+ "remaining column support on its northern edge.",
			"Prop before any rescuer enters the void beneath."],
		[Vector3(46.0, 8.0, -20.0), "Displaced roof truss",
			"Roof truss has dropped at one end and is resting on stacked "
			+ "material rather than its seat.",
			"Stabilise the truss before working under it."],
	]
	for s in sites:
		var d := Detectable.new()
		d.kind = Sim.FindingKind.STRUCTURAL
		d.label = s[1]
		d.detail = s[2]
		d.recommended_action = s[3]
		d.severity = Sim.Severity.WARNING
		d.detection_radius = 2.4
		d.max_detect_range = 85.0
		d.thermal_contrast = 0.0
		d.position = s[0]
		_hazards.add_child(d)


# ------------------------------------------------------- ambient effects

func _build_ambient_effects() -> void:
	# Airborne dust over the whole site - sells the scale in VR and gives the
	# volumetric fog something to catch the light on.
	var ramp := Vfx.ramp([
		Color(0.85, 0.80, 0.70, 0.0),
		Color(0.85, 0.80, 0.70, 0.11),
		Color(0.85, 0.80, 0.70, 0.0),
	], [0.0, 0.4, 1.0])

	var dust := GPUParticles3D.new()
	dust.name = "AmbientDust"
	dust.amount = 150
	dust.lifetime = 14.0
	dust.preprocess = 10.0
	dust.visibility_aabb = AABB(Vector3(-140.0, -4.0, -140.0), Vector3(280.0, 70.0, 280.0))
	dust.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(130.0, 26.0, 130.0)
	pm.direction = Vector3(1.0, 0.1, 0.2)
	pm.spread = 40.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 2.8
	pm.gravity = Vector3(0.6, -0.05, 0.2)
	pm.scale_min = 0.25
	pm.scale_max = 1.1
	pm.color_ramp = ramp
	dust.process_material = pm
	dust.draw_pass_1 = Vfx.quad(Vector2.ONE * 0.9)
	dust.material_override = Vfx.billboard_material(Vfx.soft_circle(64, 2.4), false)
	dust.position = Vector3(0.0, 22.0, 0.0)
	add_child(dust)
	_dust = dust
