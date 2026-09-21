shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Ground surface for the blast zone.
//
// Three CC0 material sets blended by where you are: asphalt on the access
// corridor, pulverised rubble inside the crater lip, damaged concrete
// everywhere else. Blending in the shader rather than baking it means the
// crater can be moved without re-authoring a single texture.

uniform sampler2D concrete_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D concrete_normal : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D concrete_orm : hint_default_white, filter_linear_mipmap_anisotropic;

uniform sampler2D rubble_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D rubble_normal : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rubble_orm : hint_default_white, filter_linear_mipmap_anisotropic;

uniform sampler2D road_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D road_normal : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D road_orm : hint_default_white, filter_linear_mipmap_anisotropic;

uniform float uv_scale = 0.16;
uniform float detail_scale = 0.021;      // second, larger tiling to hide repeats
uniform vec3 epicentre = vec3(0.0, 0.0, 0.0);
uniform float crater_radius = 62.0;
uniform float crater_feather = 34.0;
uniform vec2 road_axis = vec2(1.0, 0.18);
uniform float road_offset = 46.0;
uniform float road_half_width = 7.5;
uniform float road_feather = 4.0;
uniform vec3 dust_tint : source_color = vec3(0.80, 0.74, 0.63);
uniform float dust_amount : hint_range(0.0, 1.0) = 0.22;

varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz * uv_scale;
	vec2 uv_far = world_pos.xz * detail_scale;

	// --- masks ---------------------------------------------------------------
	float d = length(world_pos.xz - epicentre.xz);
	float rubble_mask = 1.0 - smoothstep(crater_radius, crater_radius + crater_feather, d);
	// break the circle up so the transition does not read as a drawn ring
	rubble_mask = clamp(rubble_mask + (vnoise(world_pos.xz * 0.05) - 0.5) * 0.55, 0.0, 1.0);

	vec2 axis = normalize(road_axis);
	float along = dot(world_pos.xz, vec2(-axis.y, axis.x)) - road_offset;
	float road_mask = 1.0 - smoothstep(road_half_width, road_half_width + road_feather, abs(along));
	road_mask *= 1.0 - rubble_mask * 0.85;   // the road is destroyed near ground zero

	// --- samples -------------------------------------------------------------
	vec3 a_con = texture(concrete_albedo, uv).rgb;
	vec3 a_rub = texture(rubble_albedo, uv).rgb;
	vec3 a_road = texture(road_albedo, uv).rgb;

	vec3 n_con = texture(concrete_normal, uv).rgb;
	vec3 n_rub = texture(rubble_normal, uv).rgb;
	vec3 n_road = texture(road_normal, uv).rgb;

	vec3 o_con = texture(concrete_orm, uv).rgb;
	vec3 o_rub = texture(rubble_orm, uv).rgb;
	vec3 o_road = texture(road_orm, uv).rgb;

	vec3 albedo = mix(a_con, a_rub, rubble_mask);
	albedo = mix(albedo, a_road, road_mask);
	vec3 nrm = mix(n_con, n_rub, rubble_mask);
	nrm = mix(nrm, n_road, road_mask);
	vec3 orm = mix(o_con, o_rub, rubble_mask);
	orm = mix(orm, o_road, road_mask);

	// large-scale variation so the tiling does not march off to the horizon
	float macro = vnoise(uv_far * 6.0) * 0.5 + vnoise(uv_far * 17.0) * 0.5;
	albedo *= 0.76 + macro * 0.34;

	// everything within the blast radius is under a layer of concrete dust
	float dust = dust_amount * (0.35 + 0.65 * rubble_mask);
	albedo = mix(albedo, dust_tint * (0.75 + macro * 0.4), dust);

	ALBEDO = albedo;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = mix(1.0, 1.6, rubble_mask);
	AO = orm.r;
	ROUGHNESS = clamp(orm.g * mix(1.0, 1.12, dust), 0.25, 1.0);
	METALLIC = orm.b * 0.35;
}
