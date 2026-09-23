class_name XrRig
extends Node3D
## OpenXR pilot station - the configuration the assessed demo runs in.
##
## The operator sits *in* the aircraft: the origin tracks the drone's position
## and heading, the head is free to look anywhere, and the payload's sensor
## treatment is applied per eye so thermal and gas overlays come out in correct
## stereo.
##
## Comfort is designed in rather than bolted on:
##   - the origin never inherits pitch or roll, so the horizon stays level;
##   - a cockpit frame moves with the aircraft and gives the inner ear a fixed
##     reference;
##   - the field of view narrows under acceleration and yaw.

## Draw order inside the headset.
##
## The payload post-process is a full-screen quad with no depth test, so
## anything that must stay readable *through* the sensor image - the cockpit
## frame, the instrument panel, the wrist detector, contact cards - has to be
## drawn after it. These are the priorities that put them there.
const POST_PROCESS_PRIORITY := 100
const LASER_PRIORITY := 106
const CARD_PRIORITY := 110
const COCKPIT_PRIORITY := 112
const PANEL_PRIORITY := 118

const HUD_VIEWPORT_SIZE := Vector2i(1600, 900)
const WRIST_VIEWPORT_SIZE := Vector2i(560, 360)

var origin: XROrigin3D
var camera: XRCamera3D
var left: XRController3D
var right: XRController3D
var _was_lost := false
var vision: VisionPost

var hud_viewport: SubViewport
var hud_panel: MeshInstance3D
var wrist_viewport: SubViewport
var wrist_panel: MeshInstance3D
var contact_card: Label3D
var laser: MeshInstance3D

var _drone: Drone
var _input: XrInputBridge
var _vignette_material: ShaderMaterial
var _yaw := 0.0
var _hud: Hud
var _wrist: WristPanel


func setup(drone: Drone) -> void:
	_drone = drone


func _ready() -> void:
	# Moved every frame, so never interpolated itself.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	origin = XROrigin3D.new()
	origin.name = "XROrigin3D"
	add_child(origin)

	camera = XRCamera3D.new()
	camera.name = "XRCamera3D"
	camera.near = 0.05
	camera.far = 1200.0
	origin.add_child(camera)

	vision = VisionPost.new()
	vision.name = "VisionPost"
	camera.add_child(vision)

	_build_comfort_vignette()
	_build_cockpit()
	_build_controllers()
	_build_wrist_panel()
	_build_contact_card()

	_input = XrInputBridge.new()
	_input.name = "InputBridge"
	_input.setup(left, right)
	add_child(_input)

	if _drone:
		_yaw = deg_to_rad(-_drone.heading_degrees())
		# Haptics stand in for camera shake. Shaking the view in a headset is
		# the fastest way to make someone ill; a pulse in the hands carries the
		# same information without moving the horizon.
		_drone.collided.connect(func(speed: float):
			_pulse(clampf(speed / 10.0, 0.15, 1.0), 0.08 + speed * 0.01))
	Sim.camera_shake.connect(func(strength: float): _pulse(clampf(strength, 0.3, 1.0), 0.35))


func _process(delta: float) -> void:
	if _drone == null or not is_instance_valid(_drone):
		return
	_follow_aircraft(delta)
	_update_comfort(delta)
	_update_contact_card()
	_update_laser()


# ------------------------------------------------------------------ tracking

func _pulse(amplitude: float, seconds: float) -> void:
	for hand in [left, right]:
		if hand:
			hand.trigger_haptic_pulse("haptic", 0.0, amplitude, seconds, 0.0)


func _follow_aircraft(delta: float) -> void:
	# A crashed aircraft tumbles. Following its heading would spin the whole
	# world round the operator's head, so the view holds where it was and
	# watches it go down; the spare launch then cuts - never pans - to the van.
	if _drone.damage and _drone.damage.is_destroyed():
		_was_lost = true
		return
	if _was_lost:
		_was_lost = false
		_yaw = deg_to_rad(-_drone.heading_degrees())
	# Position follows exactly; heading follows with a little lag so a twitchy
	# yaw input does not whip the whole world around.
	var target_yaw := deg_to_rad(-_drone.heading_degrees())
	if Sim.settings.get("vr_follow_yaw", true):
		_yaw = _lerp_angle_capped(_yaw, target_yaw, delta * 3.2,
			deg_to_rad(90.0) * delta)
	# Interpolated, for the same reason as the flat camera rig: the headset
	# draws far faster than the physics tick, and a head-mounted view that
	# steps at 60 Hz is the fastest route to motion sickness there is.
	origin.global_position = _drone.camera_mount.get_global_transform_interpolated().origin
	origin.global_basis = Basis(Vector3.UP, _yaw)


func _lerp_angle_capped(from: float, to: float, weight: float, max_step: float) -> float:
	var target := lerp_angle(from, to, clampf(weight, 0.0, 1.0))
	var delta_angle := wrapf(target - from, -PI, PI)
	return from + clampf(delta_angle, -max_step, max_step)


func _update_comfort(delta: float) -> void:
	if _vignette_material == null:
		return
	var open := 1.25
	if bool(Sim.settings.get("vr_comfort_vignette", true)):
		var speed := _drone.linear_velocity.length()
		var yaw_rate := absf(_drone.angular_velocity.y)
		var intensity := clampf(speed / 14.0, 0.0, 1.0) * 0.55 \
			+ clampf(yaw_rate / 2.6, 0.0, 1.0) * 0.45
		open = lerpf(1.25, 0.55, clampf(intensity, 0.0, 1.0))
	var current: float = _vignette_material.get_shader_parameter("aperture")
	_vignette_material.set_shader_parameter("aperture",
		lerpf(current, open, clampf(delta * 3.0, 0.0, 1.0)))


# --------------------------------------------------------------- construction

func _build_comfort_vignette() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)

	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = load("res://shaders/comfort_vignette.gdshader")
	_vignette_material.set_shader_parameter("aperture", 1.25)
	_vignette_material.render_priority = 120

	var mi := MeshInstance3D.new()
	mi.name = "ComfortVignette"
	mi.mesh = quad
	mi.material_override = _vignette_material
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(mi)


## A minimal canopy. It is not decoration - a frame that stays put relative to
## the aircraft is what stops the brain reading the moving world as self-motion.
func _build_cockpit() -> void:
	var frame := Node3D.new()
	frame.name = "CockpitFrame"
	origin.add_child(frame)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.12, 0.14, 0.92)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = COCKPIT_PRIORITY
	mat.no_depth_test = true

	# Deliberately sparse: enough fixed structure in the lower periphery to
	# anchor the inner ear, not so much that it eats the field of view.
	var struts := [
		# [size, position, rotation]
		[Vector3(1.30, 0.030, 0.030), Vector3(0.0, -0.50, -0.95), Vector3(-8, 0, 0)],
		[Vector3(0.030, 0.50, 0.030), Vector3(-0.66, -0.30, -0.95), Vector3(0, 0, 14)],
		[Vector3(0.030, 0.50, 0.030), Vector3(0.66, -0.30, -0.95), Vector3(0, 0, -14)],
	]
	for s in struts:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = s[0]
		mi.mesh = box
		mi.material_override = mat
		mi.position = s[1]
		mi.rotation_degrees = s[2]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		frame.add_child(mi)


func _build_controllers() -> void:
	left = XRController3D.new()
	left.name = "LeftHand"
	left.tracker = &"left_hand"
	origin.add_child(left)

	right = XRController3D.new()
	right.name = "RightHand"
	right.tracker = &"right_hand"
	origin.add_child(right)

	for c in [left, right]:
		var mi := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = 0.028
		mesh.height = 0.13
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.10, 0.11, 0.13)
		mat.roughness = 0.5
		mi.material_override = mat
		mi.rotation_degrees = Vector3(-70.0, 0.0, 0.0)
		c.add_child(mi)

	# Right-hand pointer for tagging contacts in the world.
	laser = MeshInstance3D.new()
	laser.name = "Laser"
	var beam := CylinderMesh.new()
	beam.top_radius = 0.0032
	beam.bottom_radius = 0.0032
	beam.height = 1.0
	laser.mesh = beam
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	lm.albedo_color = Color(0.3, 1.0, 0.85, 0.65)
	lm.render_priority = LASER_PRIORITY
	lm.no_depth_test = true
	laser.material_override = lm
	laser.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	right.add_child(laser)


## Wrist-mounted gas readout: glance at your left hand, exactly like the
## detector a hazmat operator wears.
func _build_wrist_panel() -> void:
	wrist_viewport = SubViewport.new()
	wrist_viewport.name = "WristViewport"
	wrist_viewport.size = WRIST_VIEWPORT_SIZE
	wrist_viewport.transparent_bg = true
	wrist_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	wrist_viewport.disable_3d = true
	add_child(wrist_viewport)

	_wrist = WristPanel.new()
	_wrist.drone = _drone
	wrist_viewport.add_child(_wrist)

	wrist_panel = MeshInstance3D.new()
	wrist_panel.name = "WristPanel"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.15, 0.096)
	wrist_panel.mesh = quad

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = wrist_viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = PANEL_PRIORITY + 1
	wrist_panel.material_override = mat
	var wrist_backing := MeshInstance3D.new()
	wrist_backing.name = "WristBacking"
	var wb := QuadMesh.new()
	wb.size = Vector2(0.158, 0.104)
	wrist_backing.mesh = wb
	var wb_mat := StandardMaterial3D.new()
	wb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wb_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wb_mat.albedo_color = Color(0.01, 0.02, 0.03, 0.96)
	wb_mat.no_depth_test = true
	wb_mat.render_priority = PANEL_PRIORITY
	wb_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wrist_backing.material_override = wb_mat
	wrist_backing.position = Vector3(0.0, 0.0, -0.003)
	wrist_panel.add_child(wrist_backing)

	wrist_panel.position = Vector3(0.0, 0.03, 0.06)
	wrist_panel.rotation_degrees = Vector3(-52.0, 0.0, 0.0)
	wrist_panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	left.add_child(wrist_panel)


## Floating briefing card that parks itself beside whatever the pilot is
## looking at. In VR this replaces the flat-screen contact panel.
func _build_contact_card() -> void:
	contact_card = Label3D.new()
	contact_card.name = "ContactCard"
	contact_card.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	contact_card.no_depth_test = true
	contact_card.fixed_size = false
	contact_card.pixel_size = 0.0022
	contact_card.font_size = 48
	contact_card.outline_size = 14
	contact_card.outline_modulate = Color(0, 0, 0, 0.85)
	contact_card.render_priority = CARD_PRIORITY
	contact_card.outline_render_priority = CARD_PRIORITY - 1
	contact_card.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	contact_card.width = 640.0
	contact_card.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	contact_card.visible = false
	add_child(contact_card)


func attach_hud(hud: Hud) -> void:
	_hud = hud
	hud.vr_mode = true

	hud_viewport = SubViewport.new()
	hud_viewport.name = "HudViewport"
	hud_viewport.size = HUD_VIEWPORT_SIZE
	hud_viewport.transparent_bg = true
	hud_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	hud_viewport.disable_3d = true
	add_child(hud_viewport)
	hud_viewport.add_child(hud)
	hud.camera_override = camera

	hud_panel = MeshInstance3D.new()
	hud_panel.name = "HudPanel"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.30, 1.29)
	quad.subdivide_width = 24
	hud_panel.mesh = quad

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = hud_viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = PANEL_PRIORITY
	hud_panel.material_override = mat
	hud_panel.position = Vector3(0.0, -0.68, -1.16)
	hud_panel.rotation_degrees = Vector3(-34.0, 0.0, 0.0)
	hud_panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	origin.add_child(hud_panel)

	# Opaque backing. Without it the instruments sit directly on top of a
	# bright thermal image and become unreadable exactly when they matter.
	var backing := MeshInstance3D.new()
	backing.name = "HudBacking"
	var back_quad := QuadMesh.new()
	back_quad.size = quad.size * 1.02
	backing.mesh = back_quad
	var back_mat := StandardMaterial3D.new()
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	back_mat.albedo_color = Color(0.012, 0.025, 0.032, 0.94)
	back_mat.no_depth_test = true
	back_mat.render_priority = PANEL_PRIORITY - 1
	back_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	backing.material_override = back_mat
	backing.position = Vector3(0.0, 0.0, -0.004)
	backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hud_panel.add_child(backing)


## The briefing and settings share the cockpit panel's viewport, so they are
## readable in the headset without a second surface to aim at.
func attach_menus(menus: CanvasLayer) -> void:
	if hud_viewport:
		hud_viewport.add_child(menus)
	else:
		add_child(menus)


# -------------------------------------------------------------------- update

func _update_contact_card() -> void:
	var target: Detectable = _drone.detector.focused if _drone.detector else null
	if target == null or not is_instance_valid(target):
		contact_card.visible = false
		return

	var detection := _drone.detector.detection_for(target)
	if detection.is_empty():
		contact_card.visible = false
		return

	var colour: Color = Sim.SEVERITY_COLORS[int(target.severity)]
	contact_card.modulate = colour
	contact_card.text = "%s\n%s\n\n%.0f m  -  %d%% confidence\n\n%s\n\nACTION: %s" % [
		Sim.KIND_NAMES[int(target.kind)],
		target.label,
		detection.distance,
		int(float(detection.confidence) * 100.0),
		target.detail,
		target.recommended_action,
	]
	contact_card.visible = true

	# park it beside the contact, offset toward the viewer so it never clips
	var to_cam := (camera.global_position - target.global_position).normalized()
	var side := to_cam.cross(Vector3.UP).normalized()
	var distance: float = clampf(float(detection.distance) * 0.12, 0.6, 3.5)
	contact_card.global_position = target.global_position \
		+ to_cam * distance * 0.5 + side * distance + Vector3.UP * distance * 0.4
	contact_card.pixel_size = clampf(float(detection.distance) * 0.00018, 0.0012, 0.01)


func _update_laser() -> void:
	if laser == null:
		return
	var length := 30.0
	var from := right.global_position
	var dir := -right.global_basis.z
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * length)
	params.exclude = [_drone.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if not hit.is_empty():
		length = from.distance_to(hit.position)
	laser.scale.y = length
	laser.position = Vector3(0.0, 0.0, -length * 0.5)
