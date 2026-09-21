shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, blend_mix;

// Head-locked comfort tunnel.
//
// Narrowing the field of view while the aircraft accelerates or yaws is the
// single most effective motion-sickness mitigation in VR: the peripheral
// vision that drives vection is masked, while the centre of the image - the
// part the operator is actually working with - is untouched.

uniform float aperture : hint_range(0.2, 1.4) = 1.2;   // 1.2 = fully open
uniform float feather : hint_range(0.01, 0.6) = 0.22;
uniform vec4 edge_colour : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	// per-eye centre, so the tunnel stays symmetric in stereo
	vec2 d = (SCREEN_UV - 0.5) * vec2(1.0, 0.62);
	float r = length(d) * 2.0;
	float a = smoothstep(aperture - feather, aperture + feather, r);
	ALBEDO = edge_colour.rgb;
	ALPHA = a * edge_colour.a;
}
