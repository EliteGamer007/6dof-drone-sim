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
const CRATER_RADIUS := Terrain.CRATER_RADIUS
const CRATER_DEPTH := Terrain.CRATER_DEPTH

## The staging area. The drone launches from, and recovers to, the roof of the
## response van parked here, so this one point drives the launch transform, the
## RTL objective, and the clear radius the prop scatter has to respect.
const PAD_CENTRE := Terrain.PAD_CENTRE
const PAD_CLEAR_RADIUS := 19.0
## Nothing random lands within this of a survivor. Rubble has no collision, so
## a slab dropped on someone hid them completely while the detector - whose ray
## passes straight through collision-free debris - still reported a clear line
## of sight.
const SURVIVOR_CLEAR_RADIUS := 5.0

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
var _clearings: Array[Vector2] = []


func _ready() -> void:
	_rng.seed = world_seed
	_structures = _group("Structures")
	_props = _group("Props")
	_hazards = _group("Hazards")
	_clearings = _survivor_clearings()

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


# ---------------------------------------------------------------- terrain

## Crater profile plus multi-octave noise. Kept as a pure function so the
## prop scatter can ask for ground height without a physics query.
## Cached wrapper round Terrain.height(), which every hand-placed scene piece
## also uses - so the mesh and the pieces sitting on it can never disagree.
func terrain_height(x: float, z: float) -> float:
	var key := Vector2i(int(x * 4.0), int(z * 4.0))
	if _height_cache.has(key):
		return _height_cache[key]

	var h := Terrain.height(x, z)
	_height_cache[key] = h
	return h


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
## Where the aircraft launches: the touchdown circle on whichever vehicle has
## a landing deck. Move the response van in the editor and the start moves
## with it. Falls back to the staging-area centre if there is no van.
func launch_position() -> Vector3:
	if is_inside_tree():
		for node in get_tree().get_nodes_in_group(EmergencyVehicle.LAUNCH_PAD_GROUP):
			if node is EmergencyVehicle:
				return (node as EmergencyVehicle).deck_point()
	return Vector3(PAD_CENTRE.x, terrain_height(PAD_CENTRE.x, PAD_CENTRE.y) + 0.5,
		PAD_CENTRE.y)


static func is_night(hours: float) -> bool:
	var h := fposmod(hours, 24.0)
	return h < 5.6 or h > 19.4


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

	var night := is_night(Sim.time_of_day)
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

## Only what is generated rather than placed lives here now: the skyline and
## the rubble field. Every building, vehicle and site feature is its own scene
## under scenes/, instanced in scenes/main.tscn where it can be seen and moved.
## Where the survivors are, read from the Survivors node beside this one in
## the main scene. Their own _ready has not run yet - the world is built first -
## but the nodes and their transforms already exist.
func _survivor_clearings() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var survivors := get_parent().get_node_or_null("Survivors") if get_parent() else null
	if survivors == null:
		return out
	for child in survivors.get_children():
		if child is Node3D:
			var p: Vector3 = (child as Node3D).global_position
			out.append(Vector2(p.x, p.z))
	return out


## True where random debris must not go: the swept staging area, and a
## clearing round every survivor.
func _keep_clear(x: float, z: float) -> bool:
	if Vector2(x, z).distance_to(PAD_CENTRE) < PAD_CLEAR_RADIUS:
		return true
	for c in _clearings:
		if Vector2(x, z).distance_to(c) < SURVIVOR_CLEAR_RADIUS:
			return true
	return false


func _build_structures() -> void:
	_build_background_city()
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
		# Spread around the landward sides rather than piled up behind the
		# launch pad. The heaviest weighting is now the western quarter, which
		# is the ground behind the silos - that horizon was empty.
		var roll := _rng.randf()
		if roll < 0.34:
			angle = lerpf(-PI * 0.34, PI * 0.34, _rng.randf()) + PI      # behind the silos
		elif roll < 0.58:
			angle = lerpf(-PI * 0.30, PI * 0.30, _rng.randf())           # east flank
		elif roll < 0.76:
			angle = lerpf(-PI * 0.28, PI * 0.28, _rng.randf()) + PI * 0.5
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
			if _keep_clear(x, z):
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
# ------------------------------------------------------------------ props

## Instances a downloaded prop with collision derived from its bounds.
func _place_model(name: String, pos: Vector3, yaw: float, scale := 1.0,
		collide := true, tilt := 0.0) -> Node3D:
	return BuildKit.model(_props, name, pos, yaw, scale, collide, tilt)


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
			if _keep_clear(x, z):
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
			var aabb := BuildKit.aabb_of(inst)
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

## The named hazards - gas leaks, fires, structural warnings - are scenes under
## Hazards in scenes/main.tscn. What is left here is the background: dozens of
## minor sources no one would place by hand, plus the survivor fallback.
func _place_hazards() -> void:
	_scatter_minor_sources()
	_place_victims()


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
