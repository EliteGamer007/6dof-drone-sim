class_name Materials
extends RefCounted
## Builds the shared PBR materials from the downloaded CC0 texture sets.
##
## Poly Haven ships ARM maps (ambient occlusion / roughness / metallic), which
## is exactly Godot's ORM channel layout, so they plug straight into
## StandardMaterial3D without repacking.

const TEX_ROOT := "res://assets/polyhaven/textures/"

const SETS := {
	"concrete_debris": "2k",
	"rubble": "2k",
	"damaged_concrete_floor": "2k",
	"asphalt_02": "2k",
	"cracked_concrete": "1k",
	"rust_coarse_01": "1k",
	"rustic_stone_wall": "1k",
}

static var _cache := {}


static func texture(set_name: String, map: String) -> Texture2D:
	var res: String = SETS.get(set_name, "1k")
	var path := "%s%s/%s_%s_%s.jpg" % [TEX_ROOT, set_name, set_name, map, res]
	if not ResourceLoader.exists(path):
		push_warning("Materials: missing %s" % path)
		return null
	return load(path)


## `uv_scale` is in tiles per metre - the mesh is expected to carry world-ish UVs.
static func pbr(set_name: String, uv_scale := 0.5, tint := Color.WHITE,
		roughness_scale := 1.0) -> StandardMaterial3D:
	var key := "%s_%.3f_%s_%.2f" % [set_name, uv_scale, tint.to_html(false), roughness_scale]
	if _cache.has(key):
		return _cache[key]

	var m := StandardMaterial3D.new()
	m.albedo_texture = texture(set_name, "diff")
	m.albedo_color = tint
	var nor := texture(set_name, "nor_gl")
	if nor:
		m.normal_enabled = true
		m.normal_texture = nor
	var orm := texture(set_name, "arm")
	if orm:
		m.ao_enabled = true
		m.ao_texture = orm
		m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.roughness_texture = orm
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		m.metallic_texture = orm
		m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		m.metallic = 1.0
	m.roughness = clampf(roughness_scale, 0.0, 1.0)
	m.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_cache[key] = m
	return m


static func concrete(tint := Color(0.86, 0.84, 0.80)) -> StandardMaterial3D:
	return pbr("damaged_concrete_floor", 0.28, tint)


static func broken_concrete() -> StandardMaterial3D:
	return pbr("cracked_concrete", 0.30, Color(0.82, 0.79, 0.74))


static func stone() -> StandardMaterial3D:
	return pbr("rustic_stone_wall", 0.34, Color(0.92, 0.86, 0.72))


static func rusted_steel() -> StandardMaterial3D:
	return pbr("rust_coarse_01", 0.45, Color(0.78, 0.72, 0.66))


static func asphalt() -> StandardMaterial3D:
	return pbr("asphalt_02", 0.24)


static func rubble() -> StandardMaterial3D:
	return pbr("rubble", 0.35)
