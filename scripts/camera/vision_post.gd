class_name VisionPost
extends MeshInstance3D
## Full-screen payload post-process. Add as a child of any Camera3D - including
## the XRCamera3D, where it runs per eye and the plume integration therefore
## comes out correctly in stereo.

const SHADER := preload("res://shaders/vision_post.gdshader")

## Automatic gain window, relative to ambient air temperature.
##
## The window has to be narrow enough that the few degrees of variation across
## the ground actually fill the palette. A wide window is what makes a thermal
## image look "plain with the fires cut out": if the scene only spans 6 degrees
## and the window spans 34, every surface lands in the bottom sixth of the LUT
## and nothing but the fires has any contrast at all.
const GAIN_FLOOR := -2.5
const GAIN_HEADROOM := 1.5
const GAIN_MIN_SPAN := 12.0
const GAIN_MAX_SPAN := 26.0

## A fire is hundreds of degrees hotter than anything else on site. Letting it
## set the top of the scale would compress every person in frame into one flat
## colour, so fires only nudge the gain and are otherwise allowed to clip -
## exactly what a real camera in automatic gain does.
const FIRE_GAIN_CEILING := 7.0

## How often the core closes its shutter for a flat-field correction.
const NUC_INTERVAL := 75.0

@export var auto_gain := true

var material := ShaderMaterial.new()
var _blend := 0.0
var _span := Vector2(18.0, 40.0)
var _target_span := Vector2(18.0, 40.0)
var _nuc := 0.0
var _nuc_timer := 0.0


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad

	material.shader = SHADER
	material.render_priority = 100
	material_override = material

	# POSITION is overwritten in the vertex stage, so the node's own bounds are
	# meaningless - stop the culler throwing the quad away.
	extra_cull_margin = 16384.0
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	sorting_offset = -1e5

	material.set_shader_parameter("epicentre_xz",
		Vector2(Hazards.epicentre.x, Hazards.epicentre.z))
	material.set_shader_parameter("alert_low", ThermalPalettes.PERSON_BAND.x)
	material.set_shader_parameter("alert_high", ThermalPalettes.PERSON_BAND.y)

	Sim.vision_mode_changed.connect(_on_mode_changed)
	Sim.palette_changed.connect(_on_palette_changed)
	_on_mode_changed(Sim.vision_mode)
	_on_palette_changed(Sim.thermal_palette)


func _process(delta: float) -> void:
	# Fade between modes rather than hard-cutting; it looks like a sensor
	# switching bands instead of a UI toggle.
	_blend = move_toward(_blend, 1.0, delta * 5.0)
	material.set_shader_parameter("blend", _blend)
	material.set_shader_parameter("mode", int(Sim.vision_mode))
	material.set_shader_parameter("sun_direction", Sim.sun_direction)
	material.set_shader_parameter("daylight", Sim.daylight)
	material.set_shader_parameter("noise_amount",
		1.0 if Sim.settings.sensor_noise else 0.25)

	if Sim.vision_mode == Sim.VisionMode.THERMAL:
		if auto_gain:
			_update_auto_gain(delta)
		_update_nuc(delta)
	material.set_shader_parameter("thermal_min", _span.x)
	material.set_shader_parameter("thermal_max", _span.y)
	material.set_shader_parameter("nuc", _nuc)

	var reference := global_position
	var cam := get_parent() as Node3D
	if cam:
		reference = cam.global_position
	Hazards.apply_to_material(material, reference)


## Mimics a microbolometer's automatic gain control: the window re-ranges to
## what is actually in front of the camera, which is why a real thermal image
## "breathes" when a warm body enters the frame.
func _update_auto_gain(delta: float) -> void:
	var ambient := Hazards.ambient_temp
	# The scene's own hottest surfaces: banked afternoon heat after sunset,
	# live solar heating by day.
	var hottest := ambient + 9.5 * (1.0 - Sim.daylight * 0.45) + 11.0 * Sim.daylight

	var cam := get_parent() as Camera3D
	if cam:
		for h in Hazards.heat_sources:
			var node: Node3D = h.node
			if not is_instance_valid(node):
				continue
			var pos := node.global_position
			if not cam.is_position_in_frustum(pos):
				continue
			var d := cam.global_position.distance_to(pos)
			if d > 140.0:
				continue
			var temp: float = h.temp if h.absolute else ambient + float(h.temp)
			# far-away sources occupy a few pixels and should not steer the gain
			var weight: float = clampf(18.0 / maxf(d, 1.0), 0.15, 1.0)
			var contribution := (temp - ambient) * weight
			if int(h.kind) == Hazards.HeatKind.FIRE or int(h.kind) == Hazards.HeatKind.SMOULDER:
				contribution = minf(contribution, FIRE_GAIN_CEILING)
			hottest = maxf(hottest, ambient + contribution)

	var span := clampf(hottest + GAIN_HEADROOM - (ambient + GAIN_FLOOR),
		GAIN_MIN_SPAN, GAIN_MAX_SPAN)
	_target_span = Vector2(ambient + GAIN_FLOOR, ambient + GAIN_FLOOR + span)
	# slow, like the real thing - a gain that snaps is visibly synthetic
	_span = _span.lerp(_target_span, clampf(delta * 0.9, 0.0, 1.0))


## Flat-field correction: the shutter drops across the core, the image goes
## briefly uniform, and the camera clicks. Every thermal drone does this, and
## pilots notice immediately when a simulator does not.
func _update_nuc(delta: float) -> void:
	_nuc_timer += delta
	if _nuc_timer >= NUC_INTERVAL:
		_trigger_nuc()
	_nuc = move_toward(_nuc, 0.0, delta * 3.2)


func _trigger_nuc() -> void:
	_nuc_timer = 0.0
	_nuc = 1.0
	Sfx.play("ui_click", -14.0, 0.7)


## The temperature window currently mapped across the palette, for the legend.
func span() -> Vector2:
	return _span


func _on_mode_changed(mode: Sim.VisionMode) -> void:
	_blend = 0.0
	if mode == Sim.VisionMode.THERMAL:
		# snap the gain on entry, then calibrate - same as powering a core up
		_update_auto_gain(10.0)
		_span = _target_span
		_trigger_nuc()


func _on_palette_changed(palette: Sim.ThermalPalette) -> void:
	_blend = maxf(_blend, 0.6)
	material.set_shader_parameter("palette_tex", ThermalPalettes.texture(palette))
	material.set_shader_parameter("palette_mode",
		1 if palette == Sim.ThermalPalette.ALERT else 0)


## Point temperature under a screen position - the FLIR-style spot readout.
## Uses the same environment model as the shader so the number matches the
## colour under the reticle.
func spot_temperature(camera: Camera3D, screen_pos: Vector2, max_range := 220.0) -> Dictionary:
	if camera == null:
		return {"valid": false, "temp": Hazards.ambient_temp, "distance": 0.0}
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * max_range)
	if Sim.drone and Sim.drone is PhysicsBody3D:
		params.exclude = [Sim.drone.get_rid()]
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		# pointing at the sky
		var elev := clampf(dir.y, 0.0, 1.0)
		return {"valid": true, "temp": lerpf(Hazards.ambient_temp - 9.0,
			Hazards.ambient_temp - 30.0, sqrt(elev)), "distance": max_range}

	var normal: Vector3 = hit.normal
	var distance := from.distance_to(hit.position)
	var env := Hazards.environment_temperature(hit.position, normal, 0.42, distance)

	# heat sources applied to that surface exactly as the shader does
	var temp := Hazards.sample_temperature(hit.position, env)
	return {
		"valid": true,
		"temp": temp,
		"distance": distance,
		"position": hit.position,
	}
