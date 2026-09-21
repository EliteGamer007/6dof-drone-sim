extends Node3D
## Entry point. Assembles the world, the aircraft, the operator's view (flat or
## VR) and the interface, then owns the global hotkeys.

const DRONE_SCRIPT := preload("res://scripts/drone/drone.gd")

@export var quality: WorldBuilder.Quality = WorldBuilder.Quality.MEDIUM
@export var start_in_vr := true

var world: WorldBuilder
var drone: Drone
var rig: CameraRig
var xr_rig: XrRig
var hud: Hud
var mission: MissionDirector
var menus: MenuLayer
var beacons: Node3D

var _capture_path := ""
var _capture_frames := -1
var _frame := 0
var _debug_view := -1
var _debug_pos := Vector3.INF
var _debug_look := Vector3.INF
var _debug_freeze := false
var _capture_done := false
var _skip_briefing := false
var _open_settings := false
var _force_xr_rig := false
var _selftest := false
var _flighttest := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_command_line()
	var t0 := Time.get_ticks_msec()

	# World and Drone live in scenes/main.tscn so they can be seen and edited
	# in the Godot editor; fall back to building them if the scene lacks them.
	world = get_node_or_null("World") as WorldBuilder
	if world == null:
		world = WorldBuilder.new()
		world.name = "World"
		add_child(world)
	var saved := int(Sim.settings.get("quality", -1))
	if saved >= 0 and saved < WorldBuilder.Quality.size() 			and saved != WorldBuilder.Quality.VR:
		quality = saved as WorldBuilder.Quality
	world.apply_quality(quality)

	beacons = Node3D.new()
	beacons.name = "Beacons"
	add_child(beacons)

	_spawn_drone()

	# --force-xr-rig builds the whole VR station with no headset attached: the
	# XR camera then behaves like an ordinary camera, which is enough to prove
	# the cockpit, wrist panel and HUD surface all assemble and render.
	if (start_in_vr and _try_start_xr()) or _force_xr_rig:
		xr_rig = XrRig.new()
		xr_rig.name = "XrRig"
		xr_rig.setup(drone)
		add_child(xr_rig)
		world.apply_quality(WorldBuilder.Quality.VR)
	else:
		rig = CameraRig.new()
		rig.name = "CameraRig"
		rig.setup(drone)
		add_child(rig)

	hud = Hud.new()
	hud.name = "Hud"
	hud.setup(drone, self)
	if xr_rig:
		xr_rig.attach_hud(hud)
	else:
		add_child(hud)

	mission = MissionDirector.new()
	mission.name = "Mission"
	mission.setup(drone, world)
	add_child(mission)

	menus = MenuLayer.new()
	menus.name = "Menus"
	menus.setup(self)
	if xr_rig:
		xr_rig.attach_menus(menus)
	else:
		add_child(menus)

	Sim.finding_logged.connect(_on_finding_logged)
	Sim.start_mission()
	_apply_debug_state()
	if OS.is_stdout_verbose():
		print("[boot] scene assembled in %d ms" % (Time.get_ticks_msec() - t0))


func _spawn_drone() -> void:
	drone = get_node_or_null("Drone") as Drone
	if drone == null:
		drone = Drone.new()
		drone.name = "Drone"
		drone.set_script(DRONE_SCRIPT)
		drone.body_scene = load("res://assets/drone/dji_fpv.glb")
		add_child(drone)
	# Wherever the scene file left it, the aircraft starts on the response
	# van's deck - the same place the RTL objective sends it back to.
	drone.position = world.launch_position()
	# The aircraft's _ready has already latched its start pose by now, so
	# re-latch it here or "reset" and "return home" both point at the old spot.
	drone.start_transform = drone.global_transform
	drone.linear_velocity = Vector3.ZERO
	Sim.home_position = drone.global_position


# ------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return

	if Input.is_action_just_pressed("vision_next"):
		Sim.cycle_vision_mode(1)
		Sfx.play("ui_switch", -6.0)
	elif Input.is_action_just_pressed("vision_prev"):
		Sim.cycle_vision_mode(-1)
		Sfx.play("ui_switch", -6.0)
	elif Input.is_action_just_pressed("vision_normal"):
		Sim.set_vision_mode(Sim.VisionMode.NORMAL)
	elif Input.is_action_just_pressed("toggle_thermal"):
		# Straight to thermal, and pressing it again comes straight back.
		Sim.set_vision_mode(Sim.VisionMode.NORMAL
			if Sim.vision_mode == Sim.VisionMode.THERMAL
			else Sim.VisionMode.THERMAL)
		Sfx.play("ui_switch", -6.0)
		Sim.toast.emit("SENSOR: %s" % Sim.VISION_NAMES[Sim.vision_mode],
			Sim.Severity.INFO)
	elif Input.is_action_just_pressed("vision_night"):
		Sim.set_vision_mode(Sim.VisionMode.NIGHT)
	elif Input.is_action_just_pressed("vision_gas"):
		Sim.set_vision_mode(Sim.VisionMode.GAS)
	elif Input.is_action_just_pressed("thermal_palette"):
		Sim.cycle_palette()
		Sim.toast.emit("PALETTE: %s" % Sim.PALETTE_NAMES[Sim.thermal_palette],
			Sim.Severity.INFO)
	elif Input.is_action_just_pressed("drop_marker"):
		drop_marker()
	elif Input.is_action_just_pressed("capture_photo"):
		capture_evidence()
	elif Input.is_action_just_pressed("detonate"):
		detonate_nearest()


func _process(_delta: float) -> void:
	_handle_capture()


# ----------------------------------------------------------------- actions

## Tags whatever the payload is pointed at - a contact if one is in the
## reticle, otherwise the ground point being looked at.
func drop_marker() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var target: Detectable = drone.detector.focused
	if target == null or not is_instance_valid(target):
		# The detector only lists contacts it is confident about, and it drops
		# confidence hard when the line of sight is obstructed. That is right
		# for the automatic log, but it is wrong for the tag button: if the
		# operator can see a survivor through a gap in a pipe rack and puts the
		# reticle on them, pressing tag has to work.
		target = _contact_under_reticle(camera)
	if target != null and is_instance_valid(target):
		_tag_contact(target)
	else:
		_drop_reference_point(camera)


## The contact closest to the line the reticle is pointing down, ignoring
## confidence and line of sight entirely. Purely a "what am I aiming at".
func _contact_under_reticle(camera: Camera3D) -> Detectable:
	var origin := camera.global_position
	var dir := -camera.global_basis.z
	var best: Detectable = null
	var best_miss := INF

	for node in get_tree().get_nodes_in_group("detectable"):
		var candidate := node as Detectable
		if candidate == null or not is_instance_valid(candidate):
			continue
		var to_target := candidate.global_position - origin
		var along := to_target.dot(dir)
		if along <= 0.5 or along > candidate.max_detect_range:
			continue
		# Perpendicular distance from the aiming line, in metres.
		var miss := (to_target - dir * along).length()
		# Tolerance grows with range so a distant contact is not impossible to
		# put the reticle on, but never gets so wide that aiming stops meaning
		# anything.
		var tolerance := maxf(candidate.detection_radius * 2.0, along * 0.05)
		if miss > tolerance:
			continue
		if miss < best_miss:
			best_miss = miss
			best = candidate
	return best


## Logs a contact exactly once.
##
## Both the automatic detector and this button go through the same contact key,
## so tagging a survivor you have already tagged tells you so and changes
## nothing - the count on the objectives panel cannot be inflated by holding
## the button down on one person.
func _tag_contact(target: Detectable) -> void:
	if target.tagged:
		Sfx.play("ui_click", -7.0)
		Sim.toast.emit("ALREADY TAGGED  #%02d  %s" %
			[target.finding_id, target.label.to_upper()], Sim.Severity.INFO)
		return

	var detection := drone.detector.detection_for(target)
	var confidence := float(detection.get("confidence", 1.0))
	var extra := {
		"detail": target.detail,
		"action": target.recommended_action,
		"confidence": confidence,
	}
	if target is GasSource:
		extra["gas"] = (target as GasSource).gas

	# Flagged as tagged *before* the finding is logged. Logging emits
	# finding_logged, and anything that recounts on that signal reads the
	# contacts themselves - so marking afterwards left every counter exactly
	# one behind. Tag the last survivor and the objectives panel would sit at
	# five of six forever.
	target.first_detected_at = Sim.mission_time
	target.mark_tagged()
	var finding := Sim.log_finding(target.kind,
		"%s (%d%% confidence)" % [target.label, int(confidence * 100.0)],
		target.severity, target.global_position, target.contact_key(), extra)
	target.finding_id = finding.id
	Sim.marker_dropped.emit(finding)
	Sfx.play("marker_drop", -4.0)


## No contact in the reticle: drop a plain reference point on the ground being
## looked at, stamped with the air reading there. These are free-form notes, so
## unlike contacts they are deliberately not de-duplicated.
func _drop_reference_point(camera: Camera3D) -> void:
	var position := drone.global_position
	var from := camera.global_position
	var dir := -camera.global_basis.z
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * 240.0)
	params.exclude = [drone.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if not hit.is_empty():
		position = hit.position

	var readings := drone.gas_sensor.readings
	var worst := drone.gas_sensor.worst_channel()
	var text := "Reference point (%s %.1f %s)" % [Hazards.GAS_NAMES[worst],
		readings[worst], Hazards.GAS_UNITS[worst]]
	Sim.marker_dropped.emit(Sim.log_finding(Sim.FindingKind.MARKER, text,
		Sim.Severity.INFO, position, "", {
			"detail": "Operator-placed reference point.",
			"action": "",
			"gas": worst,
			"value": readings[worst],
		}))
	Sfx.play("marker_drop", -4.0)


## Sets off a fuel drum: whichever one the reticle is pointing at, or failing
## that the nearest live one to the aircraft. Aiming wins, so a cluster can be
## taken apart one barrel at a time.
func detonate_nearest() -> void:
	var camera := get_viewport().get_camera_3d()
	var barrel: ExplosiveBarrel = null
	if camera:
		barrel = ExplosiveBarrel.under_reticle(get_tree(), camera.global_position,
			-camera.global_basis.z)
	if barrel == null:
		barrel = ExplosiveBarrel.nearest(get_tree(), drone.global_position, 70.0)
	if barrel == null:
		Sim.toast.emit("NO DRUM IN RANGE", Sim.Severity.INFO)
		Sfx.play("ui_click", -8.0)
		return
	barrel.detonate()


## Saves a framed still with the mission metadata burnt into the filename, the
## way an assessment flight logs evidence.
func capture_evidence() -> void:
	Sfx.play("shutter", -5.0)
	Sim.photos_taken += 1
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null or DisplayServer.get_name() == "headless":
		return       # headless: nothing to grab, but the log entry still counts
	var image := viewport_texture.get_image()
	if image == null:
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var pos := drone.global_position
	var path := "user://captures/%s_%s_%s.png" % [stamp,
		Sim.VISION_NAMES[Sim.vision_mode].replace(" / ", "-").replace(" ", "-"),
		Sim.format_latlon(pos).replace(" ", "_")]
	DirAccess.make_dir_recursive_absolute("user://captures")
	image.save_png(path)
	Sim.toast.emit("EVIDENCE CAPTURED  %s" % Sim.format_latlon(pos),
		Sim.Severity.INFO)


func _on_finding_logged(finding: Dictionary) -> void:
	var beacon := HazardBeacon.create(finding)
	beacon.position = finding.position
	beacons.add_child(beacon)


# ---------------------------------------------------------------------- XR

func _try_start_xr() -> bool:
	var iface := XRServer.find_interface("OpenXR")
	if iface == null:
		print("[XR] OpenXR interface not available - running flat.")
		return false
	if not iface.is_initialized() and not iface.initialize():
		print("[XR] OpenXR failed to initialise (no headset/runtime) - running flat.")
		return false
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Sim.xr_active = true
	print("[XR] OpenXR active.")
	return true


# ------------------------------------------------------- headless capture

func _parse_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			_capture_path = arg.substr(10)
		elif arg.begins_with("--capture-after="):
			_capture_frames = int(arg.substr(16))
		elif arg == "--no-vr":
			start_in_vr = false
		elif arg.begins_with("--quality="):
			var name := arg.substr(10).to_upper()
			if name in WorldBuilder.Quality.keys():
				quality = WorldBuilder.Quality[name]
		elif arg.begins_with("--vision="):
			var v := arg.substr(9).to_upper()
			if v in Sim.VisionMode.keys():
				Sim.vision_mode = Sim.VisionMode[v]
		elif arg.begins_with("--palette="):
			var v := arg.substr(10).to_upper()
			if v in Sim.ThermalPalette.keys():
				Sim.thermal_palette = Sim.ThermalPalette[v]
		elif arg.begins_with("--view="):
			var v := arg.substr(7).to_upper()
			if v in CameraRig.View.keys():
				_debug_view = CameraRig.View[v]
		elif arg.begins_with("--time="):
			Sim.time_of_day = float(arg.substr(7))
		elif arg.begins_with("--pos="):
			_debug_pos = _parse_vec3(arg.substr(6))
		elif arg.begins_with("--look="):
			_debug_look = _parse_vec3(arg.substr(7))
		elif arg == "--freeze":
			_debug_freeze = true
		elif arg == "--skip-briefing":
			_skip_briefing = true
		elif arg == "--settings":
			# Test hook: brings up the settings page so it can be captured.
			_open_settings = true
		elif arg == "--force-xr-rig":
			_force_xr_rig = true
		elif arg == "--flighttest":
			_flighttest = true
			_skip_briefing = true
			start_in_vr = false
		elif arg == "--selftest":
			_selftest = true
			_skip_briefing = true
			start_in_vr = false


func _parse_vec3(text: String) -> Vector3:
	var parts := text.split(",")
	if parts.size() != 3:
		return Vector3.INF
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


## Test-harness only: puts the aircraft somewhere specific so a screenshot can
## be compared run to run.
func _apply_debug_state() -> void:
	if _debug_pos != Vector3.INF:
		drone.global_position = _debug_pos
		drone.start_transform = drone.global_transform
		drone.linear_velocity = Vector3.ZERO
	if _debug_look != Vector3.INF:
		var flat := _debug_look - drone.global_position
		flat.y = 0.0
		if flat.length() > 0.01:
			drone.global_basis = Basis(Vector3.UP, atan2(-flat.x, -flat.z))
		var pitch := rad_to_deg(atan2(_debug_look.y - drone.global_position.y,
			Vector2(flat.x, flat.z).length()))
		drone.gimbal_pitch = clampf(pitch, -90.0, 32.0)
	if _debug_view >= 0 and rig:
		rig.view = _debug_view as CameraRig.View
	if _debug_freeze:
		drone.freeze = true
	if _skip_briefing and menus:
		menus.state = MenuLayer.State.HIDDEN
		get_tree().paused = false
	if _open_settings and menus:
		menus.state = MenuLayer.State.PAUSED
		get_tree().paused = true
	if _flighttest:
		var ft := FlightTest.new()
		ft.setup(self)
		add_child(ft)
	if _selftest:
		var test := SelfTest.new()
		test.name = "SelfTest"
		test.setup(self)
		add_child(test)
	world.set_time_of_day(Sim.time_of_day)


func _handle_capture() -> void:
	if _capture_path == "" or _capture_done:
		return
	_frame += 1
	if _frame < maxi(_capture_frames, 1):
		return
	_capture_done = true
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_capture_path)
	print("[capture] frame %d -> %s (err %d)" % [_frame, _capture_path, err])
	get_tree().quit()
