class_name Hud
extends CanvasLayer
## Ground-control interface.
##
## Drawn entirely in code so the same instrument set can be composited onto a
## flat screen or rendered into the VR cockpit panel without maintaining two
## layouts. Everything on it answers one of three questions: where am I, what
## have I found, and what should someone do about it.

const REF := Vector2(1920.0, 1080.0)
const MAX_LABELLED_CONTACTS := 4

const COL_BG := Color(0.03, 0.05, 0.06, 0.62)
const COL_EDGE := Color(0.35, 0.85, 0.80, 0.55)
const COL_TEXT := Color(0.86, 0.96, 0.96)
const COL_DIM := Color(0.55, 0.68, 0.70)
const COL_ACCENT := Color(0.30, 0.92, 0.80)
const COL_WARN := Color(1.0, 0.72, 0.20)
const COL_CRIT := Color(1.0, 0.30, 0.28)

var drone: Drone
var main: Node
var root: Control

var show_hud := true
var show_help := false
var show_report := false

## In VR the instrument panel is composited onto a cockpit surface, and the
## contact information lives in the world instead of on the glass.
var vr_mode := false
var camera_override: Camera3D = null

var _font: Font
var _mono: Font
var _toasts: Array[Dictionary] = []
var _alarm_text := ""
var _alarm_severity := Sim.Severity.INFO
var _alarm_timer := 0.0
var _post: VisionPost = null
var _spot := {"valid": false, "temp": 0.0, "distance": 0.0}
var _spot_timer := 0.0
var _blink := 0.0


func setup(drone_ref: Drone, main_ref: Node) -> void:
	drone = drone_ref
	main = main_ref


func _ready() -> void:
	layer = 10
	_font = _load_font("res://assets/fonts/ui.ttf")
	_mono = _load_font("res://assets/fonts/mono.ttf")

	root = Control.new()
	root.name = "HudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.draw.connect(_draw_hud)
	add_child(root)

	Sim.toast.connect(_on_toast)
	Sim.alarm_raised.connect(_on_alarm)
	Sim.mission_finished.connect(func(_s): show_report = true)


func _load_font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f := load(path)
		if f is Font:
			return f
	return ThemeDB.fallback_font


func _process(delta: float) -> void:
	_blink = fmod(_blink + delta, 1.0)

	if Input.is_action_just_pressed("toggle_hud"):
		show_hud = not show_hud
	if Input.is_action_just_pressed("toggle_help"):
		show_help = not show_help
		Sfx.play("ui_click")
	if Input.is_action_just_pressed("toggle_report"):
		show_report = not show_report
		Sfx.play("ui_click")

	_alarm_timer = maxf(_alarm_timer - delta, 0.0)
	for t in _toasts:
		t.life -= delta
	_toasts = _toasts.filter(func(t): return t.life > 0.0)

	_spot_timer += delta
	if _spot_timer > 0.1:
		_spot_timer = 0.0
		_update_spot()

	root.queue_redraw()


func _camera() -> Camera3D:
	if camera_override != null and is_instance_valid(camera_override):
		return camera_override
	return get_viewport().get_camera_3d()


func _update_spot() -> void:
	var camera := _camera()
	if camera == null:
		return
	if _post == null or not is_instance_valid(_post):
		for child in camera.get_children():
			if child is VisionPost:
				_post = child
				break
	if _post == null:
		return
	_spot = _post.spot_temperature(camera, get_viewport().get_visible_rect().size * 0.5)


func _on_toast(text: String, severity: Sim.Severity) -> void:
	_toasts.append({"text": text, "severity": severity, "life": 5.0})
	if _toasts.size() > 6:
		_toasts.pop_front()


func _on_alarm(severity: Sim.Severity, text: String) -> void:
	_alarm_text = text
	_alarm_severity = severity
	_alarm_timer = 4.5


# ------------------------------------------------------------------ drawing

func _scale() -> float:
	var size := root.size
	return minf(size.x / REF.x, size.y / REF.y)


func _draw_hud() -> void:
	if drone == null or not is_instance_valid(drone):
		return
	var s := _scale()
	var size := root.size
	var alpha: float = clampf(Sim.settings.hud_opacity, 0.15, 1.0)

	if show_report:
		_draw_report(size, s)
		return

	if not vr_mode:
		_draw_detections(size, s)

	if not show_hud:
		return

	root.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_top_bar(size, s, alpha)
	_draw_gas_panel(size, s, alpha)
	_draw_telemetry(size, s, alpha)
	if not vr_mode:
		_draw_reticle(size, s, alpha)
	_draw_horizon(size, s, alpha)
	_draw_radar(size, s, alpha)
	_draw_proximity(size, s, alpha)
	_draw_objectives(size, s, alpha)
	if not vr_mode:
		_draw_contact_panel(size, s, alpha)
		_draw_offscreen_arrows(size, s, alpha)
	_draw_sensor_legend(size, s, alpha)
	_draw_toasts(size, s)
	_draw_alarm(size, s)

	if show_help:
		_draw_help(size, s)


# ---- primitives -------------------------------------------------------------

func _panel(rect: Rect2, alpha: float, edge := COL_EDGE) -> void:
	# On the VR cockpit surface the panel sits on an opaque backing, so it can
	# afford to be lighter; on a flat screen it is floating over the feed and
	# needs to stay dark enough to read.
	var bg_alpha: float = (0.30 if vr_mode else COL_BG.a) * alpha
	root.draw_rect(rect, Color(COL_BG.r, COL_BG.g, COL_BG.b, bg_alpha), true)
	root.draw_rect(rect, Color(edge.r, edge.g, edge.b, edge.a * alpha), false, 1.5)
	# corner ticks, the cheapest way to make a panel read as an instrument
	var t := minf(rect.size.x, rect.size.y) * 0.08
	var c := Color(edge.r, edge.g, edge.b, alpha)
	for corner in [[rect.position, Vector2(1, 1)],
			[Vector2(rect.end.x, rect.position.y), Vector2(-1, 1)],
			[Vector2(rect.position.x, rect.end.y), Vector2(1, -1)],
			[rect.end, Vector2(-1, -1)]]:
		var p: Vector2 = corner[0]
		var d: Vector2 = corner[1]
		root.draw_line(p, p + Vector2(d.x * t, 0), c, 2.0)
		root.draw_line(p, p + Vector2(0, d.y * t), c, 2.0)


func _text(pos: Vector2, text: String, size_px: float, colour: Color,
		mono := false, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	var font: Font = _mono if mono else _font
	root.draw_string(font, pos, text, align, width, int(size_px), colour)


func _text_width(text: String, size_px: float, mono := false) -> float:
	var font: Font = _mono if mono else _font
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size_px)).x


func _bar(rect: Rect2, fill: float, colour: Color, alpha: float,
		ticks: Array = []) -> void:
	root.draw_rect(rect, Color(0.08, 0.12, 0.13, 0.75 * alpha), true)
	var w := rect.size.x * clampf(fill, 0.0, 1.0)
	root.draw_rect(Rect2(rect.position, Vector2(w, rect.size.y)),
		Color(colour.r, colour.g, colour.b, alpha), true)
	for t in ticks:
		var x: float = rect.position.x + rect.size.x * clampf(float(t), 0.0, 1.0)
		root.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y),
			Color(1, 1, 1, 0.55 * alpha), 1.0)
	root.draw_rect(rect, Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.5 * alpha), false, 1.0)


# ---- panels ----------------------------------------------------------------

func _draw_top_bar(size: Vector2, s: float, alpha: float) -> void:
	var h := 44.0 * s
	var rect := Rect2(Vector2(16.0 * s, 12.0 * s), Vector2(size.x - 32.0 * s, h))
	_panel(rect, alpha)

	var y := rect.position.y + h * 0.66
	var pad := 20.0 * s
	var fs := 19.0 * s

	_text(Vector2(rect.position.x + pad, y), "PORT OF BEIRUT - SECTOR 4 ASSESSMENT",
		fs, COL_ACCENT)

	var mode_col := COL_ACCENT if Sim.vision_mode == Sim.VisionMode.NORMAL else COL_WARN
	var right := rect.end.x - pad
	var items := [
		["T+%s" % Sim.format_clock(Sim.mission_time), COL_TEXT],
		["%02d:%02d LOCAL" % [int(Sim.time_of_day),
			int(fmod(Sim.time_of_day, 1.0) * 60.0)], COL_DIM],
		[Sim.VISION_NAMES[Sim.vision_mode], mode_col],
	]
	if Sim.vision_mode == Sim.VisionMode.THERMAL:
		items.append([Sim.PALETTE_NAMES[Sim.thermal_palette], COL_DIM])
	items.reverse()
	for item in items:
		var w := _text_width(item[0], fs, true)
		_text(Vector2(right - w, y), item[0], fs, item[1], true)
		right -= w + 26.0 * s


func _draw_gas_panel(size: Vector2, s: float, alpha: float) -> void:
	var w := 424.0 * s
	var h := 262.0 * s
	var rect := Rect2(Vector2(16.0 * s, 70.0 * s), Vector2(w, h))
	var sensor := drone.gas_sensor
	var edge := COL_EDGE
	if sensor.alarm_level >= 3:
		edge = COL_CRIT
	elif sensor.alarm_level == 2:
		edge = COL_WARN
	_panel(rect, alpha, edge)

	var fs := 17.0 * s
	_text(Vector2(rect.position.x + 14.0 * s, rect.position.y + 24.0 * s),
		"ATMOSPHERE  -  5 CHANNEL", fs, COL_ACCENT)

	var status: String = ["CLEAR", "ALARM 1", "ALARM 2",
		"IDLH"][mini(sensor.alarm_level, 3)]
	var status_col: Color = [COL_ACCENT, COL_WARN, COL_WARN,
		COL_CRIT][mini(sensor.alarm_level, 3)]
	if sensor.alarm_level >= 2 and _blink < 0.5:
		status_col = COL_TEXT
	var sw := _text_width(status, fs, true)
	_text(Vector2(rect.end.x - 14.0 * s - sw, rect.position.y + 24.0 * s),
		status, fs, status_col, true)
	_text(Vector2(rect.position.x + 306.0 * s, rect.position.y + 42.0 * s),
		"LAST 60 s", 11.0 * s, COL_DIM, true)

	var row_h := 42.0 * s
	var y := rect.position.y + 48.0 * s
	for i in Hazards.GAS_COUNT:
		var value := sensor.readings[i]
		var level := Hazards.channel_alarm_level(i, value)
		var colour: Color = Hazards.GAS_COLORS[i]
		if level >= 3:
			colour = COL_CRIT
		elif level == 2:
			colour = COL_WARN

		_text(Vector2(rect.position.x + 14.0 * s, y + 16.0 * s),
			Hazards.GAS_NAMES[i], fs, COL_TEXT, true)

		var reading := "%.1f %s" % [value, Hazards.GAS_UNITS[i]]
		var rw := _text_width(reading, fs, true)
		_text(Vector2(rect.position.x + 150.0 * s - rw, y + 16.0 * s),
			reading, fs, colour, true)

		# trend arrow - is it getting worse as we fly?
		var arrow := ""
		if absf(sensor.trend[i]) > Hazards.GAS_FULL_SCALE[i] * 0.003:
			arrow = "^" if sensor.trend[i] > 0.0 else "v"
		var worsening := (arrow == "^") != (i == Hazards.Gas.O2)
		_text(Vector2(rect.position.x + 158.0 * s, y + 16.0 * s), arrow, fs,
			COL_WARN if worsening and arrow != "" else COL_DIM, true)

		var bar := Rect2(Vector2(rect.position.x + 176.0 * s, y + 6.0 * s),
			Vector2(118.0 * s, 13.0 * s))
		var ticks := []
		if i != Hazards.Gas.O2:
			ticks = [Hazards.GAS_ALARM_LOW[i] / Hazards.GAS_FULL_SCALE[i],
				Hazards.GAS_ALARM_HIGH[i] / Hazards.GAS_FULL_SCALE[i]]
		_bar(bar, Hazards.normalised(i, value), colour, alpha, ticks)
		_text(Vector2(bar.position.x, y + 34.0 * s), "pk %.1f" % sensor.peak[i],
			12.0 * s, COL_DIM, true)

		_sparkline(Rect2(Vector2(rect.position.x + 306.0 * s, y + 2.0 * s),
			Vector2(104.0 * s, 32.0 * s)), i, sensor.history(i), colour, alpha)
		y += row_h


## One channel's last minute, scaled so the alarm threshold sits at a fixed
## height - a reading crossing the dotted line means the same thing on every
## row. Oxygen is drawn as depletion, so "up" is always "worse".
func _sparkline(rect: Rect2, channel: int, values: PackedFloat32Array,
		colour: Color, alpha: float) -> void:
	root.draw_rect(rect, Color(0.05, 0.09, 0.10, 0.55 * alpha), true)
	if values.size() < 2:
		return

	var threshold: float
	var norm := PackedFloat32Array()
	norm.resize(values.size())
	if channel == Hazards.Gas.O2:
		threshold = Hazards.GAS_BASELINE[channel] - Hazards.GAS_ALARM_LOW[channel]
		for k in values.size():
			norm[k] = maxf(Hazards.GAS_BASELINE[channel] - values[k], 0.0)
	else:
		threshold = Hazards.GAS_ALARM_LOW[channel]
		for k in values.size():
			norm[k] = values[k]
	# threshold drawn at 55% of the height; the graph stretches above it
	var top := threshold / 0.55
	for v in norm:
		top = maxf(top, v * 1.08)

	var line_y := rect.end.y - rect.size.y * (threshold / top)
	var dash := 4.0
	var x := rect.position.x
	while x < rect.end.x:
		root.draw_line(Vector2(x, line_y), Vector2(minf(x + dash, rect.end.x), line_y),
			Color(1.0, 0.72, 0.2, 0.45 * alpha), 1.0)
		x += dash * 2.0

	var points := PackedVector2Array()
	points.resize(norm.size())
	var step := rect.size.x / float(GasSensor.HISTORY_LENGTH - 1)
	var offset := float(GasSensor.HISTORY_LENGTH - norm.size()) * step
	for k in norm.size():
		points[k] = Vector2(rect.position.x + offset + float(k) * step,
			rect.end.y - rect.size.y * clampf(norm[k] / top, 0.0, 1.0))
	root.draw_polyline(points, Color(colour.r, colour.g, colour.b, 0.9 * alpha),
		1.6, true)
	root.draw_circle(points[points.size() - 1], 2.2, Color(colour.r, colour.g, colour.b, alpha))


func _draw_telemetry(size: Vector2, s: float, alpha: float) -> void:
	var w := 290.0 * s
	var h := 268.0 * s
	var rect := Rect2(Vector2(size.x - w - 16.0 * s, 70.0 * s), Vector2(w, h))
	_panel(rect, alpha)

	var fs := 17.0 * s
	var x := rect.position.x + 14.0 * s
	var y := rect.position.y + 26.0 * s
	_text(Vector2(x, y), "FLIGHT TELEMETRY", fs, COL_ACCENT)
	y += 26.0 * s

	var rows := [
		["ALT AGL", "%.1f m" % drone.altitude_agl(), COL_TEXT],
		["ALT MSL", "%.1f m" % drone.global_position.y, COL_DIM],
		["GND SPD", "%.1f m/s" % drone.ground_speed(), COL_TEXT],
		["V SPD", "%+.1f m/s" % drone.vertical_speed(), COL_TEXT],
		["HDG", "%03d deg" % int(drone.heading_degrees()), COL_TEXT],
		["HOME", "%.0f m / %03d" % [drone.distance_to_home(), drone.bearing_to_home()],
			COL_TEXT],
		["WIND", "%.1f m/s" % Hazards.current_wind().length(), COL_DIM],
		["DIST FLOWN", "%.0f m" % drone.total_distance, COL_DIM],
	]
	for row in rows:
		_text(Vector2(x, y), row[0], fs * 0.88, COL_DIM, true)
		var vw := _text_width(row[1], fs, true)
		_text(Vector2(rect.end.x - 14.0 * s - vw, y), row[1], fs, row[2], true)
		y += 22.0 * s


	# motor health, only shown once something is wrong
	y += 34.0 * s
	var degraded := false
	for hlth in drone.motor_health:
		if hlth < 0.99:
			degraded = true
	if degraded:
		_text(Vector2(x, y), "MOTORS", fs * 0.88, COL_DIM, true)
		for i in 4:
			var mc := COL_ACCENT if drone.motor_health[i] > 0.9 else COL_CRIT
			_bar(Rect2(Vector2(x + 84.0 * s + float(i) * 44.0 * s, y - 10.0 * s),
				Vector2(36.0 * s, 10.0 * s)), drone.motor_health[i], mc, alpha)


func _draw_reticle(size: Vector2, s: float, alpha: float) -> void:
	var c := size * 0.5
	var r := 26.0 * s
	var col := Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.8 * alpha)
	for a in [0.0, PI * 0.5, PI, PI * 1.5]:
		var d := Vector2(cos(a), sin(a))
		root.draw_line(c + d * r * 0.45, c + d * r, col, 1.6)
	root.draw_arc(c, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.3), 1.0)

	# spot temperature, the FLIR-style centre readout
	if _spot.valid and Sim.vision_mode == Sim.VisionMode.THERMAL:
		var t := "%.1f C" % _spot.temp
		var tw := _text_width(t, 19.0 * s, true)
		_text(c + Vector2(-tw * 0.5, r + 24.0 * s), t, 19.0 * s, COL_WARN, true)
		var d := "%.1f m" % _spot.distance
		var dw := _text_width(d, 14.0 * s, true)
		_text(c + Vector2(-dw * 0.5, r + 42.0 * s), d, 14.0 * s, COL_DIM, true)
	elif _spot.valid:
		var d := "%.1f m" % _spot.distance
		var dw := _text_width(d, 14.0 * s, true)
		_text(c + Vector2(-dw * 0.5, r + 24.0 * s), d, 14.0 * s, COL_DIM, true)


func _draw_horizon(size: Vector2, s: float, alpha: float) -> void:
	var att := drone.attitude_degrees()
	var c := size * 0.5
	var half := 150.0 * s
	var pitch_px := att.x * 3.4 * s
	var roll := deg_to_rad(-att.y)

	var dir := Vector2(cos(roll), sin(roll))
	var offset := Vector2(-dir.y, dir.x) * pitch_px
	var col := Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.45 * alpha)

	root.draw_line(c - dir * half + offset, c - dir * half * 0.22 + offset, col, 2.0)
	root.draw_line(c + dir * half * 0.22 + offset, c + dir * half + offset, col, 2.0)
	# roll pointer
	root.draw_line(c + offset - dir * half, c + offset - dir * half
		+ Vector2(-dir.y, dir.x) * 10.0 * s, col, 2.0)
	root.draw_line(c + offset + dir * half, c + offset + dir * half
		+ Vector2(-dir.y, dir.x) * 10.0 * s, col, 2.0)

	var label := "P%+.0f  R%+.0f" % [att.x, att.y]
	_text(c + Vector2(half * 0.6, -half * 0.5), label, 14.0 * s, COL_DIM, true)


func _draw_proximity(size: Vector2, s: float, alpha: float) -> void:
	var c := Vector2(size.x * 0.5, size.y - 120.0 * s)
	var r := 54.0 * s
	var prox := drone.proximity
	if prox == null:
		return

	root.draw_arc(c, r * 0.42, 0.0, TAU, 24,
		Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.5 * alpha), 1.2)

	for i in ProximityArray.SECTORS:
		var pressure := prox.sector_pressure(i)
		if pressure <= 0.02:
			continue
		var colour := COL_ACCENT
		if prox.distances[i] < prox.critical_distance:
			colour = COL_CRIT
		elif prox.distances[i] < prox.caution_distance:
			colour = COL_WARN
		var a0 := TAU * (float(i) - 0.42) / float(ProximityArray.SECTORS) - PI * 0.5
		var a1 := TAU * (float(i) + 0.42) / float(ProximityArray.SECTORS) - PI * 0.5
		var inner := r * 0.5
		var outer := inner + r * 0.5 * pressure
		root.draw_arc(c, (inner + outer) * 0.5, a0, a1, 12,
			Color(colour.r, colour.g, colour.b, alpha * (0.35 + 0.65 * pressure)),
			maxf(outer - inner, 2.0))

	_text(c + Vector2(-r - 14.0 * s, r + 18.0 * s),
		"PROX %.1f m" % prox.closest_distance, 14.0 * s,
		COL_CRIT if prox.closest_distance < prox.critical_distance else COL_DIM, true)

	if Sim.settings.obstacle_assist:
		var t := "ASSIST"
		_text(c + Vector2(r * 0.55, r + 18.0 * s), t, 14.0 * s,
			COL_WARN if drone.obstacle_assist_active else COL_ACCENT, true)


func _draw_radar(size: Vector2, s: float, alpha: float) -> void:
	var box := 250.0 * s
	var rect := Rect2(Vector2(16.0 * s, size.y - box - 16.0 * s), Vector2(box, box))
	_panel(rect, alpha)
	var c := rect.get_center()
	var world_span := 150.0
	var scale := (box * 0.46) / world_span

	var mission: MissionDirector = main.get("mission") if main else null

	# coverage grid - what has actually been surveyed
	if mission:
		for cell in mission.covered.keys():
			var centre: Vector2 = mission._cell_centre(cell)
			var p := c + (centre - Vector2(drone.global_position.x,
				drone.global_position.z)) * scale
			if not rect.has_point(p):
				continue
			var cs := MissionDirector.CELL * scale
			root.draw_rect(Rect2(p - Vector2(cs, cs) * 0.5, Vector2(cs, cs)),
				Color(0.18, 0.55, 0.50, 0.22 * alpha), true)

	# gas survey layer - what the air was like where the aircraft has been
	if mission:
		for cell in mission.gas_cells.keys():
			var info: Dictionary = mission.gas_cells[cell]
			var level: float = info.level
			if level < 0.35:
				continue
			var centre2: Vector2 = mission._cell_centre(cell)
			var p2 := c + (centre2 - Vector2(drone.global_position.x,
				drone.global_position.z)) * scale
			if not rect.has_point(p2):
				continue
			var gc: Color = Hazards.GAS_COLORS[int(info.gas)]
			var cs2 := MissionDirector.CELL * scale
			root.draw_rect(Rect2(p2 - Vector2(cs2, cs2) * 0.5, Vector2(cs2, cs2)),
				Color(gc.r, gc.g, gc.b, clampf(level / 2.4, 0.18, 0.7) * alpha), true)

	# range rings
	for ring in [50.0, 100.0, 150.0]:
		root.draw_arc(c, ring * scale, 0.0, TAU, 48,
			Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.22 * alpha), 1.0)

	# contacts
	for f in Sim.findings:
		var p := c + (Vector2(f.position.x, f.position.z)
			- Vector2(drone.global_position.x, drone.global_position.z)) * scale
		if not rect.has_point(p):
			continue
		var colour: Color = Sim.SEVERITY_COLORS[int(f.severity)]
		var marker_size := 4.0 * s
		match int(f.kind):
			Sim.FindingKind.VICTIM:
				root.draw_circle(p, marker_size, Color(colour.r, colour.g, colour.b, alpha))
				root.draw_arc(p, marker_size + 3.0 * s + sin(_blink * TAU) * 2.0 * s,
					0.0, TAU, 16, Color(colour.r, colour.g, colour.b, 0.6 * alpha), 1.2)
			Sim.FindingKind.GAS_LEAK:
				_diamond(p, marker_size + 1.0, Color(colour.r, colour.g, colour.b, alpha))
			Sim.FindingKind.FIRE:
				root.draw_rect(Rect2(p - Vector2(marker_size, marker_size),
					Vector2(marker_size, marker_size) * 2.0),
					Color(colour.r, colour.g, colour.b, alpha), true)
			_:
				root.draw_rect(Rect2(p - Vector2(marker_size, marker_size) * 0.8,
					Vector2(marker_size, marker_size) * 1.6),
					Color(colour.r, colour.g, colour.b, alpha), false, 1.5)

	# home
	var home := c + (Vector2(Sim.home_position.x, Sim.home_position.z)
		- Vector2(drone.global_position.x, drone.global_position.z)) * scale
	if rect.has_point(home):
		_text(home + Vector2(-4.0 * s, 4.0 * s), "H", 15.0 * s, COL_ACCENT, true)

	# the aircraft itself, always centred and pointing up the screen
	var heading := deg_to_rad(drone.heading_degrees())
	var nose := Vector2(0, -10.0 * s)
	var pts := PackedVector2Array([c + nose, c + Vector2(6.0 * s, 7.0 * s),
		c + Vector2(0, 3.0 * s), c + Vector2(-6.0 * s, 7.0 * s)])
	root.draw_colored_polygon(pts, Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, alpha))

	_text(rect.position + Vector2(12.0 * s, 20.0 * s),
		"SURVEY MAP  %.0f%% COVERED" % Sim.coverage_percent, 14.0 * s, COL_ACCENT, true)
	_text(Vector2(rect.position.x + 12.0 * s, rect.end.y - 10.0 * s),
		Sim.format_latlon(drone.global_position), 13.0 * s, COL_DIM, true)
	_text(Vector2(rect.end.x - 40.0 * s, rect.position.y + 20.0 * s),
		"%03d" % int(rad_to_deg(heading)), 13.0 * s, COL_DIM, true)


func _diamond(p: Vector2, r: float, colour: Color) -> void:
	root.draw_colored_polygon(PackedVector2Array([
		p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)]),
		colour)


func _draw_objectives(size: Vector2, s: float, alpha: float) -> void:
	var mission: MissionDirector = main.get("mission") if main else null
	if mission == null:
		return
	var w := 380.0 * s
	var h := 232.0 * s
	var rect := Rect2(Vector2(size.x - w - 16.0 * s, size.y - h - 16.0 * s),
		Vector2(w, h))
	_panel(rect, alpha)

	var fs := 15.0 * s
	var x := rect.position.x + 14.0 * s
	var y := rect.position.y + 24.0 * s
	_text(Vector2(x, y), "MISSION OBJECTIVES", 17.0 * s, COL_ACCENT)
	y += 24.0 * s

	for o in mission.objectives:
		var mark := "[x]" if o.done else "[ ]"
		var colour: Color = COL_ACCENT if o.done else COL_TEXT
		_text(Vector2(x, y), mark, fs, colour, true)
		_text(Vector2(x + 30.0 * s, y), o.text, fs, colour)
		var prog := "%d/%d" % [o.progress, o.target]
		var pw := _text_width(prog, fs, true)
		_text(Vector2(rect.end.x - 14.0 * s - pw, y), prog, fs, COL_DIM, true)
		y += 20.0 * s

	y += 8.0 * s
	root.draw_line(Vector2(x, y - 6.0 * s), Vector2(rect.end.x - 14.0 * s, y - 6.0 * s),
		Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.35 * alpha), 1.0)
	_text(Vector2(x, y + 8.0 * s), "RECENT FINDINGS", 15.0 * s, COL_ACCENT)
	y += 26.0 * s

	var recent := Sim.findings.slice(maxi(Sim.findings.size() - 4, 0))
	recent.reverse()
	for f in recent:
		var colour: Color = Sim.SEVERITY_COLORS[int(f.severity)]
		_text(Vector2(x, y), "#%02d" % int(f.id), 13.0 * s, COL_DIM, true)
		_text(Vector2(x + 34.0 * s, y), str(f.text).left(42), 13.0 * s, colour)
		y += 17.0 * s


## The contact briefing. This is the panel that turns "there is a hot blob on
## the screen" into something an assessor can write down and act on.
func _draw_contact_panel(size: Vector2, s: float, alpha: float) -> void:
	var target: Detectable = drone.detector.focused
	if target == null or not is_instance_valid(target):
		return
	var detection := drone.detector.detection_for(target)
	if detection.is_empty():
		return

	var w := 560.0 * s
	var h := 150.0 * s
	var rect := Rect2(Vector2((size.x - w) * 0.5, size.y - h - 200.0 * s), Vector2(w, h))
	var colour: Color = Sim.SEVERITY_COLORS[int(target.severity)]
	_panel(rect, alpha, colour)

	var x := rect.position.x + 16.0 * s
	var y := rect.position.y + 26.0 * s
	var meta := "%.0f m   %d%% conf   %s" % [detection.distance,
		int(float(detection.confidence) * 100.0),
		"CLEAR LOS" if detection.clear_los else "OBSTRUCTED"]
	var mw := _text_width(meta, 14.0 * s, true)

	# Trim the heading to whatever is left after the range readout has taken
	# its space, so a long contact name can never run underneath it.
	var heading := "%s  -  %s" % [Sim.KIND_NAMES[int(target.kind)],
		target.label.to_upper()]
	var available := rect.size.x - 32.0 * s - mw - 18.0 * s
	while _text_width(heading, 18.0 * s) > available and heading.length() > 8:
		heading = heading.substr(0, heading.length() - 2)
	_text(Vector2(x, y), heading, 18.0 * s, colour)
	_text(Vector2(rect.end.x - 16.0 * s - mw, y), meta, 14.0 * s, COL_DIM, true)
	y += 22.0 * s

	for line in _wrap(target.detail, 74):
		_text(Vector2(x, y), line, 14.0 * s, COL_TEXT)
		y += 17.0 * s

	if target.recommended_action != "":
		y += 4.0 * s
		_text(Vector2(x, y), "ACTION: %s" % target.recommended_action, 14.0 * s, COL_WARN)

	_text(Vector2(x, rect.end.y - 10.0 * s), Sim.format_latlon(target.global_position),
		13.0 * s, COL_DIM, true)

	# The one thing the operator needs to know about a contact they are looking
	# at: is it on the list yet, or is it still on them to put it there?
	var status := "TAGGED  #%02d" % target.finding_id if target.tagged \
		else "PRESS  A / X  TO TAG"
	var status_col := COL_ACCENT if target.tagged else COL_WARN
	var sw := _text_width(status, 14.0 * s, true)
	_text(Vector2(rect.end.x - 16.0 * s - sw, rect.end.y - 10.0 * s), status,
		14.0 * s, status_col, true)


func _wrap(text: String, chars: int) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		if line.length() + word.length() + 1 > chars:
			out.append(line)
			line = word
		else:
			line = word if line == "" else line + " " + word
	if line != "":
		out.append(line)
	return out


## Boxes over live contacts, plus a label so the viewer knows what they are
## looking at without being told.
func _draw_detections(size: Vector2, s: float) -> void:
	if not Sim.settings.show_detection_boxes:
		return
	var camera := _camera()
	if camera == null:
		return

	var centre := size * 0.5
	var ordered := drone.detector.detections.duplicate()
	ordered.sort_custom(func(a, b):
		return a.screen_pos.distance_to(centre) < b.screen_pos.distance_to(centre))

	var label_slots: Array[float] = []
	var index := 0
	for d in ordered:
		var target: Detectable = d.target
		if not is_instance_valid(target):
			continue
		var contact_centre: Vector2 = d.screen_pos
		var distance: float = d.distance
		var half := maxf(target.detection_radius / maxf(distance, 0.5)
			* size.y / (2.0 * tan(deg_to_rad(camera.fov * 0.5))), 16.0 * s)
		var rect := Rect2(contact_centre - Vector2(half, half * 1.25),
			Vector2(half * 2.0, half * 2.5))

		var colour: Color = Sim.SEVERITY_COLORS[int(target.severity)]
		colour.a = clampf(float(d.confidence), 0.3, 1.0)

		# corner brackets read better than a full box against busy rubble
		var t := minf(rect.size.x, rect.size.y) * 0.26
		for corner in [[rect.position, Vector2(1, 1)],
				[Vector2(rect.end.x, rect.position.y), Vector2(-1, 1)],
				[Vector2(rect.position.x, rect.end.y), Vector2(1, -1)],
				[rect.end, Vector2(-1, -1)]]:
			var p: Vector2 = corner[0]
			var dv: Vector2 = corner[1]
			root.draw_line(p, p + Vector2(dv.x * t, 0), colour, 2.0)
			root.draw_line(p, p + Vector2(0, dv.y * t), colour, 2.0)

		# Only the few contacts nearest the reticle get written out in full. Any
		# more and the labels stack on top of each other exactly when the operator
		# most needs to read one of them.
		index += 1
		if index > MAX_LABELLED_CONTACTS:
			continue

		var tag := "%s  %d%%" % [target.label.to_upper().left(30),
			int(float(d.confidence) * 100.0)]
		if target.tagged:
			tag = "[x] " + tag
		var label_y := rect.position.y - 8.0 * s
		for used in label_slots:
			if absf(used - label_y) < 17.0 * s:
				label_y = used - 18.0 * s
		label_slots.append(label_y)
		_text(Vector2(rect.position.x, label_y), tag, 14.0 * s, colour, true)
		if not d.clear_los:
			_text(Vector2(rect.position.x, rect.end.y + 16.0 * s), "PARTIAL RETURN",
				12.0 * s, COL_WARN, true)


## Arrows around the screen edge for confirmed findings that are currently out
## of frame - so nothing that has been found can be lost again.
func _draw_offscreen_arrows(size: Vector2, s: float, alpha: float) -> void:
	var camera := _camera()
	if camera == null:
		return
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.40

	for f in Sim.findings:
		if int(f.severity) < Sim.Severity.WARNING:
			continue
		var pos: Vector3 = f.position
		var on_screen := camera.is_position_in_frustum(pos)
		if on_screen:
			continue
		var local := camera.global_transform.affine_inverse() * pos
		var dir := Vector2(local.x, -local.y)
		if local.z > 0.0:
			dir = -dir     # behind the camera
		if dir.length() < 0.001:
			continue
		dir = dir.normalized()

		var colour: Color = Sim.SEVERITY_COLORS[int(f.severity)]
		colour.a = 0.85 * alpha
		var p := centre + dir * radius
		var tip := p + dir * 14.0 * s
		var side := Vector2(-dir.y, dir.x) * 7.0 * s
		root.draw_colored_polygon(PackedVector2Array([tip, p + side, p - side]), colour)
		var dist := "%.0f" % Vector3(pos - drone.global_position).length()
		_text(p - dir * 20.0 * s - Vector2(8.0 * s, -4.0 * s), dist, 12.0 * s, colour, true)


## Without a scale, false colour is decoration. The legend is what lets
## someone who is not flying read the image: what the colours mean, what range
## the camera is currently stretched over, and which channel a cloud belongs to.
func _draw_sensor_legend(size: Vector2, s: float, alpha: float) -> void:
	if Sim.vision_mode == Sim.VisionMode.NORMAL:
		return

	var w := 300.0 * s
	var h := 78.0 * s
	var rect := Rect2(Vector2((size.x - w) * 0.5, 74.0 * s), Vector2(w, h))
	_panel(rect, alpha)
	var x := rect.position.x + 12.0 * s
	var y := rect.position.y + 22.0 * s

	if Sim.vision_mode == Sim.VisionMode.THERMAL:
		_text(Vector2(x, y), "THERMAL  -  %s" % Sim.PALETTE_NAMES[Sim.thermal_palette],
			14.0 * s, COL_ACCENT, true)
		var bar := Rect2(Vector2(x, y + 12.0 * s), Vector2(w - 24.0 * s, 16.0 * s))
		var lo := 12.0
		var hi := 60.0
		if _post:
			lo = _post.span().x
			hi = _post.span().y
		var steps := 64
		for i in steps:
			var t := float(i) / float(steps - 1)
			var seg := Rect2(bar.position + Vector2(bar.size.x * t, 0.0),
				Vector2(bar.size.x / float(steps) + 1.0, bar.size.y))
			var colour := ThermalPalettes.sample(Sim.thermal_palette, pow(t, 1.25))
			if Sim.thermal_palette == Sim.ThermalPalette.ALERT:
				var temp := lerpf(lo, hi, t)
				if temp >= ThermalPalettes.PERSON_BAND.x and temp <= ThermalPalettes.PERSON_BAND.y:
					colour = ThermalPalettes.alert_colour(temp)
			root.draw_rect(seg, colour, true)
		root.draw_rect(bar, Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.6 * alpha),
			false, 1.0)

		_text(Vector2(bar.position.x, bar.end.y + 15.0 * s), "%.0f C" % lo,
			13.0 * s, COL_DIM, true)
		var hi_text := "%.0f C" % hi
		_text(Vector2(bar.end.x - _text_width(hi_text, 13.0 * s, true), bar.end.y + 15.0 * s),
			hi_text, 13.0 * s, COL_DIM, true)
		if Sim.thermal_palette == Sim.ThermalPalette.ALERT:
			var band_text := "PERSON %.0f-%.0f C" % [ThermalPalettes.PERSON_BAND.x,
				ThermalPalettes.PERSON_BAND.y]
			_text(Vector2(bar.position.x + (bar.size.x - _text_width(band_text, 12.0 * s, true)) * 0.5,
				bar.end.y + 15.0 * s), band_text, 12.0 * s, Color(1.0, 0.8, 0.3), true)
		# where the reticle sample sits on the scale
		if _spot.valid:
			var t2: float = clampf((float(_spot.temp) - lo) / maxf(hi - lo, 0.01), 0.0, 1.0)
			var px := bar.position.x + bar.size.x * t2
			root.draw_line(Vector2(px, bar.position.y - 3.0 * s),
				Vector2(px, bar.end.y + 3.0 * s), Color(1, 1, 1, alpha), 2.0)
		return

	if Sim.vision_mode == Sim.VisionMode.GAS:
		_text(Vector2(x, y), "GAS OVERLAY  -  COLUMN CONCENTRATION", 14.0 * s,
			COL_ACCENT, true)
		var chip := 14.0 * s
		var cx := x
		var cy := y + 16.0 * s
		for i in Hazards.GAS_COUNT:
			if i == Hazards.Gas.O2:
				continue
			var gc: Color = Hazards.GAS_COLORS[i]
			root.draw_rect(Rect2(Vector2(cx, cy), Vector2(chip, chip)),
				Color(gc.r, gc.g, gc.b, alpha), true)
			_text(Vector2(cx + chip + 5.0 * s, cy + chip * 0.85),
				Hazards.GAS_NAMES[i], 13.0 * s, COL_TEXT, true)
			cx += chip + 5.0 * s + _text_width(Hazards.GAS_NAMES[i], 13.0 * s, true) + 14.0 * s
		_text(Vector2(x, rect.end.y - 9.0 * s),
			"Brightness = how much gas the line of sight passes through",
			12.0 * s, COL_DIM)
		return

	_text(Vector2(x, y), "LOW-LIGHT INTENSIFIER", 14.0 * s, COL_ACCENT, true)
	_text(Vector2(x, y + 20.0 * s), "Gain AUTO-GATED   IR illuminator ON",
		13.0 * s, COL_DIM, true)
	_text(Vector2(x, rect.end.y - 12.0 * s),
		"Brightness is amplified light, not temperature", 12.0 * s, COL_DIM)


func _draw_toasts(size: Vector2, s: float) -> void:
	# Left-hand message stack: never over the picture, never over a contact
	# briefing, and in the place the eye already goes for the gas panel.
	var y := 364.0 * s
	for i in _toasts.size():
		var t := _toasts[_toasts.size() - 1 - i]
		var colour: Color = Sim.SEVERITY_COLORS[int(t.severity)]
		colour.a = clampf(float(t.life) / 1.2, 0.0, 1.0)
		_text(Vector2(20.0 * s, y), str(t.text).left(44), 15.0 * s, colour, true)
		y += 20.0 * s


func _draw_alarm(size: Vector2, s: float) -> void:
	if _alarm_timer <= 0.0:
		return
	var colour: Color = Sim.SEVERITY_COLORS[int(_alarm_severity)]
	var flash := _blink < 0.5
	var h := 42.0 * s
	var text_w := _text_width(_alarm_text, 22.0 * s, true)
	var w := clampf(text_w + 64.0 * s, 320.0 * s, size.x * 0.62)
	var rect := Rect2(Vector2((size.x - w) * 0.5, size.y * 0.135), Vector2(w, h))
	root.draw_rect(rect, Color(colour.r, colour.g, colour.b,
		0.30 if flash else 0.16), true)
	root.draw_rect(rect, colour, false, 2.0)
	_text(Vector2((size.x - text_w) * 0.5, rect.position.y + h * 0.66), _alarm_text,
		22.0 * s, Color.WHITE if flash else colour, true)


# ---- overlays --------------------------------------------------------------

func _draw_help(size: Vector2, s: float) -> void:
	var w := 880.0 * s
	var h := 640.0 * s
	var rect := Rect2((size - Vector2(w, h)) * 0.5, Vector2(w, h))
	root.draw_rect(rect, Color(0.02, 0.04, 0.05, 0.94), true)
	root.draw_rect(rect, COL_ACCENT, false, 2.0)

	var x := rect.position.x + 32.0 * s
	var y := rect.position.y + 44.0 * s
	_text(Vector2(x, y), "CONTROLS", 26.0 * s, COL_ACCENT)
	y += 34.0 * s

	var groups := [
		["FLIGHT", [
			["Forward / back", "Left stick   W / S"],
			["Strafe left / right", "Left stick   A / D"],
			["Up / down", "RT / LT      Space / Shift"],
			["Turn", "Right stick  Q / E, arrows"],
			["Slow (precision)", "L3           Ctrl"],
			["Reset airframe", "Start        Backspace"],
		]],
		["PAYLOAD", [
			["THERMAL on / off", "LB           2 or T"],
			["Cycle vision mode", "Y            V"],
			["Direct: EO/NV/Gas", "-            1 3 4"],
			["Thermal palette", "-            B"],
			["Gimbal tilt / centre", "Right stick Y  R / F / G"],
			["Spotlight", "D-pad up     L"],
		]],
		["VIEW", [
			["Chase / close / FPV", "RB           C"],
			["Zoom", "-            PgUp / PgDn"],
		]],
		["MISSION", [
			["Tag contact / point", "A            X"],
			["Capture evidence", "X            P"],
			["Report", "-            Tab"],
			["Air-sample trail", "-            K"],
			["Time of day", "-            [ / ]"],
			["Toggle HUD / help", "D-pad R      F2 / F1"],
		]],
	]

	var col_x := [x, x + 440.0 * s]
	var col_y := [y, y]
	var col := 0
	for g in groups:
		var gy: float = col_y[col]
		_text(Vector2(col_x[col], gy), g[0], 18.0 * s, COL_WARN, true)
		gy += 24.0 * s
		for row in g[1]:
			_text(Vector2(col_x[col], gy), row[0], 15.0 * s, COL_TEXT)
			_text(Vector2(col_x[col] + 210.0 * s, gy), row[1], 14.0 * s, COL_DIM, true)
			gy += 20.0 * s
		gy += 16.0 * s
		col_y[col] = gy
		if col == 0 and gy > rect.position.y + h * 0.55:
			col = 1

	_text(Vector2(x, rect.end.y - 66.0 * s),
		"VR: left stick throttle + yaw, right stick pitch + roll, right trigger tags a",
		14.0 * s, COL_DIM)
	_text(Vector2(x, rect.end.y - 48.0 * s),
		"contact, A cycles the sensor, and the gas readout is on your left wrist.",
		14.0 * s, COL_DIM)
	_text(Vector2(x, rect.end.y - 22.0 * s), "F1 to close", 15.0 * s, COL_ACCENT, true)


## After-action summary - the deliverable an assessment flight is actually for.
func _draw_report(size: Vector2, s: float) -> void:
	root.draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.035, 0.045, 0.96), true)
	var x := 80.0 * s
	var y := 70.0 * s

	_text(Vector2(x, y), "POST-FLIGHT ASSESSMENT REPORT", 30.0 * s, COL_ACCENT)
	y += 34.0 * s
	_text(Vector2(x, y), "Port of Beirut, Sector 4  -  educational reconstruction",
		16.0 * s, COL_DIM)
	y += 40.0 * s

	var stats := [
		["Flight time", Sim.format_clock(Sim.mission_time)],
		["Distance flown", "%.0f m" % drone.total_distance],
		["Max altitude", "%.1f m AGL" % drone.max_altitude],
		["Area surveyed", "%.0f%%" % Sim.coverage_percent],
		["Findings logged", str(Sim.findings.size())],
		["Evidence captures", str(Sim.photos_taken)],
	]
	for i in stats.size():
		var col := i / 3
		var row := i % 3
		var px := x + float(col) * 320.0 * s
		var py := y + float(row) * 24.0 * s
		_text(Vector2(px, py), stats[i][0], 15.0 * s, COL_DIM)
		_text(Vector2(px + 180.0 * s, py), stats[i][1], 15.0 * s, COL_TEXT, true)
	y += 96.0 * s

	root.draw_line(Vector2(x, y), Vector2(size.x - x, y),
		Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.5), 1.0)
	y += 28.0 * s

	var headers := ["#", "TYPE", "FINDING", "POSITION", "TIME", "SEVERITY"]
	var cols := [0.0, 46.0, 170.0, 640.0, 930.0, 1060.0]
	for i in headers.size():
		_text(Vector2(x + cols[i] * s, y), headers[i], 14.0 * s, COL_ACCENT, true)
	y += 22.0 * s

	for f in Sim.findings:
		if y > size.y - 90.0 * s:
			_text(Vector2(x, y), "... %d more" % (Sim.findings.size()
				- Sim.findings.find(f)), 14.0 * s, COL_DIM)
			break
		var colour: Color = Sim.SEVERITY_COLORS[int(f.severity)]
		var values := [
			"%02d" % int(f.id),
			Sim.KIND_NAMES[int(f.kind)],
			str(f.text).left(58),
			Sim.format_latlon(f.position),
			Sim.format_clock(float(f.time)),
			Sim.SEVERITY_NAMES[int(f.severity)],
		]
		for i in values.size():
			_text(Vector2(x + cols[i] * s, y), values[i], 13.5 * s,
				colour if i == 5 else COL_TEXT, i != 2)
		y += 19.0 * s

	_text(Vector2(x, size.y - 54.0 * s),
		"Tab to return to flight.  Captures are saved to the user data folder.",
		15.0 * s, COL_DIM)
	_text(Vector2(x, size.y - 30.0 * s),
		"This is a training reconstruction, not a forensic record of the 2020 explosion.",
		14.0 * s, COL_WARN)
