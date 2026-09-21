shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;

// Full-screen payload camera post-process.
//
// Reconstructs world position from the depth buffer, then evaluates the SAME
// hazard field the CPU sensors sample (scripts/autoload/hazards.gd), so the
// picture and the numbers on the HUD can never disagree.
//
//   mode 0  EO daylight   - clean sensor feed with a mild lens signature
//   mode 1  Thermal IR    - radiometric model, LUT palettes, isotherm alert
//   mode 2  Low-light NV  - gain-amplified phosphor green + IR illuminator
//   mode 3  Gas overlay   - analytic plume integration, wind-advected eddies

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_tex  : hint_depth_texture,  repeat_disable, filter_nearest;
uniform sampler2D palette_tex : repeat_disable, filter_linear;

uniform int mode : hint_range(0, 3) = 0;
uniform int palette_mode = 0;          // 0 = LUT, 1 = isotherm alert
uniform float blend : hint_range(0.0, 1.0) = 1.0;   // mode-change crossfade
uniform float nuc : hint_range(0.0, 1.0) = 0.0;     // flat-field calibration flash

// --- hazard field (packed by Hazards.apply_to_material) ----------------------
const int MAX_PLUMES = 48;
const int MAX_HEAT = 64;

uniform vec4 gas_a[MAX_PLUMES];   // xyz = plume origin, w = core radius
uniform vec4 gas_b[MAX_PLUMES];   // xyz = downwind axis, w = current strength
uniform vec4 gas_c[MAX_PLUMES];   // x = gas index, y = spread, z = full scale
uniform int gas_count = 0;

uniform vec4 heat_a[MAX_HEAT];    // xyz = capsule end A, w = radius
uniform vec4 heat_b[MAX_HEAT];    // xyz = capsule end B, w = surface temp (C)
uniform vec4 heat_c[MAX_HEAT];    // x = halo (m), y = kind
uniform int heat_count = 0;

uniform float ambient_temp = 29.0;
uniform vec3 wind = vec3(3.0, 0.0, 1.0);
uniform float sim_time = 0.0;

// --- sensor / scene parameters ----------------------------------------------
uniform vec3 sun_direction = vec3(-0.4, -0.8, -0.45);
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform float thermal_min = 18.0;     // deg C mapped to palette 0.0
uniform float thermal_max = 40.0;     // deg C mapped to palette 1.0
uniform float thermal_gamma = 1.34;   // >1 pushes the background into shadow
uniform float alert_low = 28.5;       // isotherm band, deg C
uniform float alert_high = 39.0;
uniform float solar_gain = 6.5;       // live solar heating on sun-facing faces
uniform float solar_storage = 4.2;    // heat still stored from the afternoon
uniform float sky_cooling = 3.6;      // radiative loss of sky-facing surfaces
uniform float thermal_mass_gain = 3.2;  // dark dense material holds its heat
uniform float ground_lapse = 0.055;   // deg C lost per metre above the ground
uniform float crater_heat = 2.0;      // residual warmth in the blast crater
uniform vec2 epicentre_xz = vec2(0.0, -12.0);
uniform float patch_amount = 1.0;     // scales the ground-patchiness term
uniform float noise_amount : hint_range(0.0, 1.0) = 1.0;
uniform float ir_range = 34.0;        // metres of usable IR illuminator
uniform float gas_opacity : hint_range(0.0, 4.0) = 0.9;
// Metres of plume at full-scale concentration that count as a full-strength
// overlay. Without this the integral is in ppm-metres and saturates instantly.
uniform float gas_reference_path = 30.0;
uniform float lens_vignette : hint_range(0.0, 1.0) = 0.55;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// Automatic gating for the intensifier. A real tube does not run a fixed
// gain: it opens up until the scene sits mid-grey and closes down when
// something bright enters the frame. A fixed gain is why this channel clipped
// to flat white at night and did nothing at all by day.
// The ground fills most of the frame and is far brighter than the scene
// average that includes the night sky, so the gate has to aim low or the one
// surface the operator is actually looking at is the one that clips.
const float NV_TARGET = 0.18;
const float NV_GAIN_MIN = 1.6;
const float NV_GAIN_MAX = 80.0;
const float TURBULENCE_SCALE = 0.14;

// Where the afternoon sun sat (west-south-west, fairly high): surfaces that
// faced it are the ones still holding heat after sunset.
const vec3 AFTERNOON_SUN = vec3(-0.55, 0.62, 0.56);

const vec3 GAS_TINT[5] = {
	vec3(0.98, 0.50, 0.16),   // CO
	vec3(0.92, 0.90, 0.22),   // H2S
	vec3(0.72, 0.32, 0.95),   // NO2
	vec3(1.00, 0.24, 0.26),   // LEL
	vec3(0.30, 0.72, 1.00)    // O2
};

void vertex() {
	// Documented Godot full-screen trick: bypass the transform entirely and
	// emit the quad straight in clip space at the near plane (reverse-Z).
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// ----------------------------------------------------------------- noise

// PCG hash - mirrors Hazards._pcg() bit for bit, so the eddies the pilot sees
// in the overlay are the same eddies the detector is flying through.
uint pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float hash3i(ivec3 p) {
	uint h = pcg(uint(p.x) + pcg(uint(p.y) + pcg(uint(p.z))));
	return float(h) / 4294967295.0;
}

float vnoise3(vec3 p) {
	ivec3 i = ivec3(floor(p));
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float c000 = hash3i(i);
	float c100 = hash3i(i + ivec3(1, 0, 0));
	float c010 = hash3i(i + ivec3(0, 1, 0));
	float c110 = hash3i(i + ivec3(1, 1, 0));
	float c001 = hash3i(i + ivec3(0, 0, 1));
	float c101 = hash3i(i + ivec3(1, 0, 1));
	float c011 = hash3i(i + ivec3(0, 1, 1));
	float c111 = hash3i(i + ivec3(1, 1, 1));
	return mix(mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y),
	           mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	return vnoise3(p) * 0.65 + vnoise3(p * 2.03 + vec3(17.0, 9.0, 3.0)) * 0.35;
}

float turbulence(vec3 p) {
	vec3 q = (p - wind * sim_time) * TURBULENCE_SCALE;
	return clamp(0.25 + 1.1 * fbm3(q), 0.08, 1.45);
}

// Cheap screen-space grain.
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

// ------------------------------------------------------------- geometry

vec3 world_from_depth(vec2 uv, float raw_depth, mat4 inv_proj, mat4 inv_view) {
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
	vec4 view = inv_proj * vec4(ndc, 1.0);
	view.xyz /= max(view.w, 1e-6);
	return (inv_view * vec4(view.xyz, 1.0)).xyz;
}

float linear_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).x;
	vec4 view = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -view.z / max(view.w, 1e-6);
}

// Closest distance between a ray and a segment, plus the ray parameter there.
vec2 ray_segment(vec3 ro, vec3 rd, vec3 p0, vec3 p1) {
	vec3 u = rd;
	vec3 v = p1 - p0;
	vec3 w = ro - p0;
	float a = dot(u, u);
	float b = dot(u, v);
	float c = dot(v, v);
	float d = dot(u, w);
	float e = dot(v, w);
	float den = a * c - b * b;
	float t;
	if (den < 1e-5) {
		t = (b > c ? d / b : e / max(c, 1e-5));
	} else {
		t = (a * e - b * d) / den;
	}
	t = clamp(t, 0.0, 1.0);
	float s = dot(u, (p0 + v * t) - ro) / max(a, 1e-5);
	vec3 closest_ray = ro + u * max(s, 0.0);
	vec3 closest_seg = p0 + v * t;
	return vec2(distance(closest_ray, closest_seg), s);
}

float seg_distance(vec3 p, vec3 a, vec3 b) {
	vec3 ab = b - a;
	float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
	return distance(p, a + ab * t);
}

// ------------------------------------------------------------ hazard field

// Analytic line integral of a Gaussian plume along the view ray, broken up by
// the same wind-advected eddies the CPU sampler applies.
float plume_integral(vec3 ro, vec3 rd, float tmax, int i) {
	vec3 origin = gas_a[i].xyz;
	float radius = max(gas_a[i].w, 0.05);
	vec3 axis = gas_b[i].xyz;
	float strength = gas_b[i].w;
	float spread = gas_c[i].y;

	vec2 rs = ray_segment(ro, rd, origin, origin + axis);
	float d = rs.x;
	float s = rs.y;
	float r = radius * (1.0 + 0.5 * spread);
	if (d > r * 3.2) {
		return 0.0;
	}
	float visible = smoothstep(-r * 0.3, r * 0.3, s) * smoothstep(-r * 0.3, r * 0.3, tmax - s);
	float peak = exp(-(d * d) / (2.0 * r * r));
	vec3 at = ro + rd * clamp(s, 0.0, tmax);
	float core = exp(-distance(at, origin) / max(radius * 1.5, 0.3));
	float eddies = mix(turbulence(at), 1.0, core);
	return strength * peak * r * 2.5066 * visible * eddies;   // sqrt(2*pi)
}

// Applies every nearby heat capsule to a surface. A warm source can only
// raise a surface toward its own temperature and a cold one only lower it, so
// a faint warm halo never cools concrete that is already warmer than it.
// Mirrors Hazards.sample_temperature().
float apply_heat(vec3 p, float t_env) {
	float t = t_env;
	for (int i = 0; i < heat_count; i++) {
		float halo = max(heat_c[i].x, 0.02);
		float d = seg_distance(p, heat_a[i].xyz, heat_b[i].xyz) - heat_a[i].w;
		if (d > halo * 4.0) { continue; }
		float dd = max(d, 0.0);
		float w = exp(-(dd * dd) / (2.0 * halo * halo));
		float ts = heat_b[i].w;
		if (int(heat_c[i].y) == 5) {
			t = mix(t, min(t, ts), w);   // cold source: water, evaporative cooling
		} else {
			t = mix(t, max(t, ts), w);
		}
	}
	return t;
}

// ---------------------------------------------------------------- thermal

// Ground-temperature patchiness: damp ground against dry, asphalt against
// dust, rubble that is still shedding the day's heat against rubble that is
// not. Two octaves over world XZ. Without this the whole site reads as one
// flat temperature and the image looks like a cartoon with the fires cut out.
// Mirrored by Hazards.thermal_patch() using the same PCG value noise.
float thermal_patch(vec3 p) {
	float a = vnoise3(vec3(p.x * 0.042, 0.0, p.z * 0.042));
	float b = vnoise3(vec3(p.x * 0.155 + 31.7, 0.0, p.z * 0.155 - 11.3));
	return ((a - 0.5) * 1.9 + (b - 0.5) * 0.85) * patch_amount;
}

// Surface temperature of the environment itself, before any heat source.
// The terms are the ones that dominate a real dusk thermal image of rubble:
// heat banked from the afternoon on the faces that saw the sun, radiative
// loss to a clear sky on anything facing up, and thermal mass - dark, dense
// material holds its heat longer than pale, porous material.
float environment_temperature(vec3 p, vec3 nrm, float albedo_lum, float dist) {
	float t = ambient_temp;
	// Heat banked from the afternoon, on the faces that saw the sun.
	float stored = max(dot(nrm, normalize(AFTERNOON_SUN)), 0.0);
	t += stored * solar_storage * (1.0 - daylight * 0.45);
	// Live solar heating, by day.
	t += max(dot(nrm, -normalize(sun_direction)), 0.0) * solar_gain * daylight;
	// Radiative loss to a clear sky: strongest on flat upward faces after
	// dark, which is why a road is colder than a wall at night.
	t -= max(nrm.y, 0.0) * sky_cooling * (1.0 - daylight * 0.7);
	// Thermal mass: dark dense material holds heat, pale porous material sheds
	// it. The albedo is the only material cue the post-process has.
	t += (0.42 - albedo_lum) * thermal_mass_gain * clamp(daylight * 2.2, 0.0, 1.0);
	// The ground is the reservoir; anything up in the air sits closer to the
	// air temperature it is bathed in.
	t -= clamp(p.y * ground_lapse, 0.0, 2.8);
	// The crater floor is still giving back what the blast put into it.
	t += crater_heat * exp(-distance(p.xz, epicentre_xz) / 46.0);
	t += thermal_patch(p);
	// The atmosphere pulls distant surfaces toward air temperature.
	return mix(t, ambient_temp, clamp(dist / 480.0, 0.0, 0.7));
}

vec3 thermal(vec2 uv, vec3 base, vec3 world, vec3 nrm, float dist, bool is_sky,
		vec2 px, mat4 inv_proj, vec3 ray_dir) {
	float temp;
	if (is_sky) {
		// Clear sky reads far below ambient; warmer toward the horizon, where
		// the path through the atmosphere is longest.
		float elev = clamp(ray_dir.y, 0.0, 1.0);
		temp = mix(ambient_temp - 9.0, ambient_temp - 30.0, sqrt(elev));
	} else {
		// Albedo from a low mip, so fine texture detail does not leak into
		// what is supposed to be a temperature image.
		float lum = dot(textureLod(screen_tex, uv, 3.0).rgb, LUMA);
		temp = environment_temperature(world, nrm, lum, dist);
		temp = apply_heat(world, temp);

		// Open flame is optically thick in the long-wave band: where the
		// visible image shows bright flame, the thermal image sees hundreds of
		// degrees, and it sees *through* the smoke above it.
		float flame = smoothstep(0.55, 0.9, base.r) * smoothstep(0.25, 0.55, base.r - base.b)
			* smoothstep(0.5, 0.85, dot(base, LUMA));
		temp = mix(temp, 380.0, flame * 0.85);
	}

	// Map into the display window. The gamma pushes ambient-temperature
	// surfaces down into the dark end of the palette, which is what makes a
	// real thermal image readable: warm things stand out of shadow.
	float span = max(thermal_max - thermal_min, 0.001);
	float v = clamp((temp - thermal_min) / span, 0.0, 1.0);
	v = pow(v, thermal_gamma);

	// Digital detail enhancement: a high-pass on depth, which is where a real
	// microbolometer sees edges - at the silhouettes where one surface's
	// temperature meets another's.
	if (!is_sky) {
		float d0 = linear_depth(uv, inv_proj);
		float dl = linear_depth(uv - vec2(px.x, 0.0), inv_proj);
		float dr = linear_depth(uv + vec2(px.x, 0.0), inv_proj);
		float du = linear_depth(uv - vec2(0.0, px.y), inv_proj);
		float dd = linear_depth(uv + vec2(0.0, px.y), inv_proj);
		float lap = abs(dl + dr + du + dd - 4.0 * d0) / max(d0, 0.5);
		v += clamp(lap * 1.6, 0.0, 0.07);
	}

	// Sensor signature: very light temporal noise (NETD) and a faint column
	// pattern (fixed-pattern noise) - enough to read as a real core.
	float grain = vnoise2(uv * vec2(640.0, 512.0) + sim_time * 43.0) - 0.5;
	float fpn = hash12(vec2(floor(uv.x * 640.0), 3.0)) - 0.5;
	v += (grain * 0.010 + fpn * 0.006) * noise_amount;
	v = clamp(v, 0.0, 1.0);

	vec3 col;
	if (palette_mode == 1) {
		// Isotherm alert: the scene in subdued grey, and every surface in the
		// human skin / clothed-body band painted, on absolute temperature. At
		// any gain setting, colour means "this is the temperature of a person".
		col = texture(palette_tex, vec2(v, 0.5)).rgb;
		float in_band = smoothstep(alert_low - 0.6, alert_low + 0.4, temp)
			* (1.0 - smoothstep(alert_high, alert_high + 3.0, temp));
		float band_t = clamp((temp - alert_low) / max(alert_high - alert_low, 0.01), 0.0, 1.0);
		vec3 band = mix(vec3(1.0, 0.88, 0.22), vec3(1.0, 0.36, 0.08), band_t);
		col = mix(col, band, in_band);
		// hotter than any person: fire and machinery, in red
		col = mix(col, vec3(1.0, 0.14, 0.10), smoothstep(alert_high + 3.0, alert_high + 12.0, temp));
	} else {
		col = texture(palette_tex, vec2(v, 0.5)).rgb;
	}

	// cold-shield vignette of an uncooled core
	float r = length(uv - 0.5) * 1.42;
	col *= 1.0 - 0.16 * r * r;
	// flat-field correction flash when the shutter closes
	col = mix(col, vec3(dot(col, LUMA) * 0.35 + 0.18), nuc);
	return col;
}

// ------------------------------------------------------------------- main

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 base = texture(screen_tex, uv).rgb;
	vec2 px = 1.0 / VIEWPORT_SIZE;

	float raw_depth = texture(depth_tex, uv).x;
	bool is_sky = raw_depth < 1e-6;

	vec3 world = world_from_depth(uv, raw_depth, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	vec3 cam = CAMERA_POSITION_WORLD;
	// The view ray comes from the near plane, which is well defined even where
	// the depth buffer is empty (sky), unlike the reconstructed far point.
	vec3 near_point = world_from_depth(uv, 1.0, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	vec3 ray_dir = normalize(near_point - cam);
	float dist = is_sky ? 4000.0 : length(world - cam);

	// Surface normal from the reconstructed position - good enough for the
	// heating terms and free of an extra G-buffer fetch.
	vec3 nrm = normalize(cross(dFdx(world), dFdy(world)));
	if (dot(nrm, -ray_dir) < 0.0) { nrm = -nrm; }

	float grain = vnoise2(uv * vec2(920.0, 520.0) + TIME * 37.0);
	float vign = 1.0 - lens_vignette * pow(length(uv - 0.5) * 1.42, 2.4);

	vec3 outc = base;

	// ---------------------------------------------------------------- EO feed
	if (mode == 0) {
		vec2 dir = (uv - 0.5);
		float amt = 0.0016 * dot(dir, dir) * 4.0;
		outc.r = texture(screen_tex, uv + dir * amt).r;
		outc.b = texture(screen_tex, uv - dir * amt).b;
		outc += (grain - 0.5) * 0.020 * noise_amount;
		outc *= mix(1.0, vign, 0.75);
	}

	// --------------------------------------------------------------- thermal
	else if (mode == 1) {
		outc = thermal(uv, base, world, nrm, dist, is_sky, px, INV_PROJECTION_MATRIX, ray_dir);
	}

	// ---------------------------------------------------------- night vision
	else if (mode == 2) {
		float lum = dot(base, LUMA);
		// A deep mip of the screen is a free approximation of the scene's
		// average brightness, which is all the gate needs.
		float scene = dot(textureLod(screen_tex, vec2(0.5), 9.0).rgb, LUMA);
		float gain = clamp(NV_TARGET / max(scene, 0.004), NV_GAIN_MIN, NV_GAIN_MAX);
		float v = 1.0 - exp(-lum * gain);
		if (!is_sky) {
			float cone = smoothstep(0.85, 0.15, length((uv - 0.5) * vec2(1.7, 1.0)));
			float falloff = exp(-dist / ir_range);
			v += cone * falloff * 0.40 * max(dot(nrm, -ray_dir), 0.0);
		}
		v += (grain - 0.5) * 0.17 * noise_amount;
		v += smoothstep(0.82, 1.0, v) * 0.16;
		v = clamp(v, 0.0, 1.35);
		outc = vec3(0.24, 1.0, 0.42) * v;
		outc *= 1.0 - 0.07 * sin(uv.y * 1500.0);
		outc *= mix(1.0, vign * vign, 0.95);
	}

	// ------------------------------------------------------------ gas overlay
	else {
		float lum = dot(base, LUMA);
		outc = mix(vec3(lum), base, 0.18) * 0.72;

		vec3 tint = vec3(0.0);
		float total = 0.0;
		for (int i = 0; i < gas_count; i++) {
			float amount = plume_integral(cam, ray_dir, dist, i)
				/ max(gas_c[i].z * gas_reference_path, 1.0);
			if (amount <= 0.0) { continue; }
			tint += GAS_TINT[int(gas_c[i].x)] * amount;
			total += amount;
		}
		if (total > 0.0) {
			tint /= total;
			float a = 1.0 - exp(-total * gas_opacity);
			// Capped so the scene is always still readable underneath.
			a = clamp(a, 0.0, 0.72);
			outc = mix(outc, tint * 0.85, a);
			outc += tint * smoothstep(0.55, 1.6, total) * 0.3;
		}
		outc += (grain - 0.5) * 0.015 * noise_amount;
		outc *= mix(1.0, vign, 0.6);
	}

	ALBEDO = mix(base, outc, clamp(blend, 0.0, 1.0));
	// Opaque write, but flagged transparent so the quad is drawn after the
	// scene (together with render_priority) and gets a fresh screen copy.
	ALPHA = 1.0;
}
