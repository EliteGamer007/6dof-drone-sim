class_name Vfx
extends RefCounted
## Procedural textures, materials and particle rigs.
##
## Everything visual that is not a downloaded model is generated here at load
## time, so the project carries no stray PNGs and every effect can be retuned
## from one place.

static var _circle_cache := {}


## Soft radial blob used for smoke, dust, flame and marker glows.
static func soft_circle(size: int = 128, softness: float = 1.7,
		inner: float = 0.0) -> ImageTexture:
	var key := "%d_%.2f_%.2f" % [size, softness, inner]
	if _circle_cache.has(key):
		return _circle_cache[key]

	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var centre := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - centre, float(y) - centre).length() / centre
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = pow(a, softness)
			if inner > 0.0:
				a *= smoothstep(0.0, inner, d)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	var tex := ImageTexture.create_from_image(img)
	_circle_cache[key] = tex
	return tex


## Annulus used for the ground danger rings projected under each hazard.
static func ring_texture(size: int = 256, inner: float = 0.70,
		outer: float = 0.95, softness: float = 0.06) -> ImageTexture:
	var key := "ring_%d_%.2f_%.2f_%.2f" % [size, inner, outer, softness]
	if _circle_cache.has(key):
		return _circle_cache[key]
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var centre := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - centre, float(y) - centre).length() / centre
			var a := smoothstep(inner - softness, inner + softness, d) \
				* (1.0 - smoothstep(outer - softness, outer + softness, d))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	var tex := ImageTexture.create_from_image(img)
	_circle_cache[key] = tex
	return tex


## Hazard boundary drawn on the ground as a flat annulus.
##
## This started out as a projected Decal, which is the tidier answer on uneven
## rubble - but a decal's emission is not masked by the ring's alpha, so each
## hazard painted a solid slab of colour across half the screen. An explicit
## ring mesh cannot do that, and at these radii the ground is flat enough that
## nothing is lost.
static func ground_ring(radius: float, colour: Color, thickness := 0.55,
		segments := 72) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	var inner: float = maxf(radius - thickness, 0.05)
	for i in segments + 1:
		var a := TAU * float(i) / float(segments)
		var dir := Vector3(cos(a), 0.0, sin(a))
		verts.append(dir * inner)
		verts.append(dir * radius)
		# fade the outer edge so the ring does not end on a hard line
		colours.append(Color(colour.r, colour.g, colour.b, 0.85))
		colours.append(Color(colour.r, colour.g, colour.b, 0.0))

	for i in segments:
		var a := i * 2
		indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.55)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


static func ramp(colors: Array, offsets: Array = []) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for i in colors.size():
		var off: float = offsets[i] if i < offsets.size() else float(i) / maxf(colors.size() - 1, 1)
		g.add_point(off, colors[i])
	# Gradient starts with two default points; strip them.
	while g.get_point_count() > colors.size():
		g.remove_point(0)
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = 128
	return t


static func billboard_material(texture: Texture2D, additive: bool,
		vertex_color: bool = true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = (BaseMaterial3D.BLEND_MODE_ADD if additive
		else BaseMaterial3D.BLEND_MODE_MIX)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = 1
	mat.particles_anim_v_frames = 1
	mat.albedo_texture = texture
	mat.vertex_color_use_as_albedo = vertex_color
	mat.disable_receive_shadows = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return mat


static func quad(size: Vector2) -> QuadMesh:
	var m := QuadMesh.new()
	m.size = size
	return m


## Rising, expanding plume - used for gas leaks and smoke columns.
static func plume_particles(colour_ramp: GradientTexture1D, radius: float,
		rise: float, lifetime: float, amount: int, scale_range: Vector2,
		additive: bool = false) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = lifetime * 0.8
	p.explosiveness = 0.0
	p.randomness = 0.6
	p.fixed_fps = 30
	p.interpolate = true
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-radius * 6.0, -1.0, -radius * 6.0),
		Vector3(radius * 12.0, rise * lifetime + 8.0, radius * 12.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius * 0.35
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 24.0
	pm.initial_velocity_min = rise * 0.5
	pm.initial_velocity_max = rise
	pm.gravity = Vector3(0.0, 0.35, 0.0)
	pm.damping_min = 0.1
	pm.damping_max = 0.5
	pm.scale_min = scale_range.x
	pm.scale_max = scale_range.y
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.9
	pm.turbulence_noise_scale = 1.6
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.3

	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.25))
	scale_curve.add_point(Vector2(0.35, 0.8))
	scale_curve.add_point(Vector2(1.0, 1.0))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex

	pm.color_ramp = colour_ramp
	p.process_material = pm

	p.draw_pass_1 = quad(Vector2.ONE * radius)
	p.material_override = billboard_material(soft_circle(128, 2.1), additive)
	return p
