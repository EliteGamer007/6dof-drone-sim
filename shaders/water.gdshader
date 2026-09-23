shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx;

// The harbour beyond the quay wall.
//
// Deliberately cheap: two scrolling normal waves and a Fresnel-weighted mix
// between a deep colour and the sky. No screen-space reflection, no refraction,
// no depth fade - at the distance this is ever seen, none of it would show, and
// all of it costs.

uniform vec3 deep_colour : source_color = vec3(0.010, 0.048, 0.090);
uniform vec3 shallow_colour : source_color = vec3(0.045, 0.145, 0.205);
uniform vec3 sky_tint : source_color = vec3(0.34, 0.46, 0.60);
uniform float wave_scale = 0.09;
uniform float wave_speed = 0.35;
uniform float wave_height = 0.34;
uniform float choppiness = 0.55;

float wave(vec2 p, vec2 dir, float freq, float phase) {
	return sin(dot(p, dir) * freq + phase);
}

// Three swells at unrelated angles and frequencies. Two alone interfere into
// a regular diamond grid that is obvious from altitude; the third, at a ratio
// that never repeats against the others, breaks the pattern up.
float surface(vec2 p, float t) {
	float a = wave(p, normalize(vec2(1.0, 0.35)), wave_scale, t * wave_speed);
	float b = wave(p, normalize(vec2(-0.4, 1.0)), wave_scale * 1.9,
		t * wave_speed * 1.45);
	float c = wave(p, normalize(vec2(0.83, -0.56)), wave_scale * 3.17,
		t * wave_speed * 2.3 + 1.7);
	return a * 0.52 + b * 0.30 + c * 0.18;
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	VERTEX.y += surface(world_xz, TIME) * wave_height;
}

void fragment() {
	vec2 world_xz = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;

	// Slope of the wave field, used directly as a normal perturbation.
	float e = 1.4;
	float h = surface(world_xz, TIME);
	float hx = surface(world_xz + vec2(e, 0.0), TIME);
	float hz = surface(world_xz + vec2(0.0, e), TIME);
	vec3 n = normalize(vec3(h - hx, 1.0 / max(choppiness, 0.01), h - hz));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	// Grazing angles show the sky, steep angles show the depth. That single
	// term is most of why water reads as water.
	float fresnel = pow(1.0 - clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0), 3.2);
	vec3 base = mix(deep_colour, shallow_colour, clamp(h * 0.5 + 0.5, 0.0, 1.0));

	ALBEDO = mix(base, sky_tint, min(fresnel, 0.55) * 0.55);
	ROUGHNESS = mix(0.06, 0.22, clamp(h * 0.5 + 0.5, 0.0, 1.0));
	METALLIC = 0.0;
	SPECULAR = 0.65;
}
