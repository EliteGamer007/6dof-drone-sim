class_name MenuLayer
extends CanvasLayer
## Pre-flight briefing and the in-flight settings menu.
##
## Navigable entirely with a stick and one button, so the same menu works on a
## keyboard, a gamepad and a VR controller without a pointer. In VR it is
## composited onto the cockpit panel along with the rest of the interface.

enum State { BRIEFING, HIDDEN, PAUSED }

const COL_BG := Color(0.02, 0.04, 0.05, 0.95)
const COL_EDGE := Color(0.30, 0.92, 0.80)
const COL_TEXT := Color(0.88, 0.96, 0.96)
const COL_DIM := Color(0.55, 0.68, 0.70)
const COL_WARN := Color(1.0, 0.72, 0.20)
const COL_SEL := Color(0.10, 0.30, 0.30, 0.85)

const BRIEFING_BODY := [
	["CONTENT NOTE", COL_WARN],
	["This scenario reconstructs the kind of assessment flight flown after a", COL_TEXT],
	["large industrial explosion, using the 2020 Port of Beirut disaster as its", COL_TEXT],
	["reference. It is a teaching model, not a forensic reproduction of that", COL_TEXT],
	["event, and it is built in acknowledgement of the people who were killed,", COL_TEXT],
	["injured and displaced by it. Casualties are represented only as far as is", COL_TEXT],
	["needed to practise locating them.", COL_TEXT],
	["", COL_TEXT],
	["YOUR TASK", COL_WARN],
	["You are flying the first aircraft into Sector 4. Nothing has been surveyed", COL_TEXT],
	["and no one can enter on foot until you report back. Find the survivors,", COL_TEXT],
	["map the atmosphere, and flag what will fall on the rescue teams.", COL_TEXT],
	["", COL_TEXT],
	["WHAT THE AIRCRAFT CARRIES", COL_WARN],
	["EO camera  -  what the eye would see. Good for structure, useless for", COL_TEXT],
	["            a grey person lying in grey rubble.", COL_DIM],
	["Thermal IR -  body heat against cold concrete. This is what finds people.", COL_TEXT],
	["Low-light  -  amplified image plus an IR illuminator for voids and dusk.", COL_TEXT],
	["Gas overlay-  paints the invisible plume so you can see its shape and", COL_TEXT],
	["            fly around rather than through it.", COL_DIM],
	["5-gas head -  CO, H2S, NO2, combustible gas and oxygen, with alarms at", COL_TEXT],
	["            real occupational exposure levels.", COL_DIM],
]

var state: State = State.BRIEFING
var main: Node

var _root: Control
var _font: Font
var _mono: Font
var _selected := 0
var _rows: Array[Dictionary] = []
var _repeat := 0.0


func setup(main_ref: Node) -> void:
	main = main_ref


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = _load_font("res://assets/fonts/ui.ttf")
	_mono = _load_font("res://assets/fonts/mono.ttf")

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.draw.connect(_draw_menu)
	add_child(_root)

	_build_rows()
	# Start on the first real row, not on the section heading above it, or the
	# menu opens with nothing highlighted and no hint showing.
	_selected = 0
	if not _selectable(_selected):
		_move(1)
	get_tree().paused = true


func _load_font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f := load(path)
		if f is Font:
			return f
	return ThemeDB.fallback_font


# -------------------------------------------------------------------- rows

## Every row here changes something you can see without leaving the menu.
## Anything that nothing read any more was removed rather than left sitting
## there looking functional.
func _build_rows() -> void:
	_rows = [
		{"kind": "header", "label": "SCENE"},
		{"kind": "action", "id": "timeofday", "label": "Time of day",
			"hint": "Night is the thermal and low-light demo"},
		{"kind": "action", "id": "quality", "label": "Graphics",
			"hint": "Low for integrated graphics, High for the recording"},
		{"kind": "header", "label": "PAYLOAD"},
		{"kind": "toggle", "key": "show_detection_boxes", "label": "Detection overlays",
			"hint": "Brackets and labels over contacts"},
		{"kind": "toggle", "key": "sensor_noise", "label": "Sensor noise",
			"hint": "Grain and fixed-pattern noise on every sensor"},
		{"kind": "toggle", "key": "gas_trail", "label": "Air-sample trail",
			"hint": "Leaves a coloured breadcrumb at every sample point"},
		{"kind": "header", "label": "FLIGHT"},
		{"kind": "action", "id": "flightmodel", "label": "Flight model",
			"hint": "Arcade: stick is velocity.  Flight sim: point the nose, RT to fly, LT to brake"},
		{"kind": "toggle", "key": "obstacle_assist", "label": "Obstacle braking assist",
			"hint": "Slows the aircraft as it closes on an obstacle"},
		{"kind": "slider", "key": "hud_opacity", "label": "HUD opacity",
			"min": 0.2, "max": 1.0, "step": 0.05},
		{"kind": "slider", "key": "master_volume", "label": "Volume",
			"min": 0.0, "max": 1.0, "step": 0.05},
		{"kind": "header", "label": "VR COMFORT"},
		{"kind": "toggle", "key": "vr_comfort_vignette", "label": "Motion vignette"},
		{"kind": "toggle", "key": "vr_follow_yaw", "label": "View follows aircraft heading"},
		{"kind": "header", "label": ""},
		{"kind": "action", "id": "export", "label": "Export mission report"},
		{"kind": "action", "id": "reset", "label": "Reset aircraft to the van"},
		{"kind": "action", "id": "resume", "label": "Resume flight"},
		{"kind": "action", "id": "quit", "label": "Quit"},
	]


func _selectable(i: int) -> bool:
	return i >= 0 and i < _rows.size() and _rows[i].kind != "header"


func _move(step: int) -> void:
	var i := _selected
	for _n in _rows.size():
		i = wrapi(i + step, 0, _rows.size())
		if _selectable(i):
			_selected = i
			Sfx.play("ui_click", -12.0)
			return


# ------------------------------------------------------------------- input

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("pause_menu"):
		if state == State.BRIEFING:
			_start_flight()
		elif state == State.PAUSED:
			_resume()
		else:
			_pause()
		_root.queue_redraw()
		return

	if state == State.BRIEFING:
		if Input.is_action_just_pressed("drop_marker") \
				or Input.is_action_just_pressed("capture_photo") \
				or Input.is_action_just_pressed("throttle_up") \
				or Input.is_action_just_pressed("vision_next"):
			_start_flight()
		_root.queue_redraw()
		return

	if state != State.PAUSED:
		return

	_repeat = maxf(_repeat - delta, 0.0)
	var vertical := Input.get_action_strength("pitch_down") \
		- Input.get_action_strength("pitch_up")
	if absf(vertical) > 0.5 and _repeat <= 0.0:
		_move(1 if vertical > 0.0 else -1)
		_repeat = 0.18
	var horizontal := Input.get_action_strength("roll_right") \
		- Input.get_action_strength("roll_left")
	if absf(horizontal) > 0.5 and _repeat <= 0.0:
		_adjust(1 if horizontal > 0.0 else -1)
		_repeat = 0.14
	if Input.is_action_just_pressed("drop_marker"):
		_activate()

	_root.queue_redraw()


func _adjust(step: int) -> void:
	var row := _rows[_selected]
	match row.kind:
		"toggle":
			Sim.set_setting(row.key, not bool(Sim.settings[row.key]))
			Sfx.play("ui_switch", -10.0)
		"slider":
			var value := float(Sim.settings[row.key]) + float(row.step) * step
			Sim.set_setting(row.key, clampf(value, row.min, row.max))
			Sfx.play("ui_click", -14.0)
		"action":
			match row.get("id", ""):
				"quality":
					_cycle_quality(step)
				"timeofday":
					_cycle_time(step)
				"flightmodel":
					_cycle_flight_model()
				_:
					_activate()


func _activate() -> void:
	var row := _rows[_selected]
	if row.kind in ["toggle", "slider"]:
		_adjust(1)
		return
	match row.get("id", ""):
		"resume":
			_resume()
		"reset":
			if main and main.drone:
				main.drone.reset_to_start()
			_resume()
		"export":
			_export_report()
		"quality":
			_cycle_quality(1)
		"timeofday":
			_cycle_time(1)
		"flightmodel":
			_cycle_flight_model()
		"quit":
			get_tree().quit()


## Steps through LOW / MEDIUM / HIGH. VR is skipped: it is selected
## automatically when OpenXR initialises and is not a thing to pick by hand.
func _cycle_quality(step: int) -> void:
	if main == null or main.world == null:
		return
	var count: int = WorldBuilder.Quality.VR       # LOW, MEDIUM, HIGH
	var current: int = clampi(int(main.world.quality), 0, count - 1)
	var next: int = wrapi(current + step, 0, count)
	main.world.apply_quality(next as WorldBuilder.Quality)
	Sim.set_setting("quality", next)
	Sim.toast.emit("GRAPHICS: %s" % WorldBuilder.Quality.keys()[next], Sim.Severity.INFO)
	Sfx.play("ui_switch", -8.0)


func _cycle_flight_model() -> void:
	var next := 1 - int(Sim.settings.get("flight_model", 0))
	Sim.set_setting("flight_model", next)
	Sim.toast.emit("FLIGHT MODEL: %s" % Drone.FLIGHT_MODEL_NAMES[next],
		Sim.Severity.INFO)
	Sfx.play("ui_switch", -8.0)


func _cycle_time(step: int) -> void:
	if main == null or main.world == null:
		return
	var label: String = main.world.cycle_time_preset(step)
	Sim.toast.emit("TIME: %s  %02d:%02d" % [label, int(Sim.time_of_day),
		int(fmod(Sim.time_of_day, 1.0) * 60.0)], Sim.Severity.INFO)
	Sfx.play("ui_switch", -8.0)


## Writes the findings out as CSV so the flight can be handed to someone who
## was not in the headset.
func _export_report() -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "user://reports/mission_%s.csv" % stamp
	DirAccess.make_dir_recursive_absolute("user://reports")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		Sim.toast.emit("REPORT EXPORT FAILED", Sim.Severity.WARNING)
		return
	file.store_line("id,type,severity,finding,latitude,longitude,x,y,z,mission_time")
	for f in Sim.findings:
		var ll := Sim.to_latlon(f.position)
		file.store_line("%d,%s,%s,\"%s\",%.6f,%.6f,%.2f,%.2f,%.2f,%s" % [
			int(f.id), Sim.KIND_NAMES[int(f.kind)], Sim.SEVERITY_NAMES[int(f.severity)],
			str(f.text).replace("\"", "'"), ll.x, ll.y,
			f.position.x, f.position.y, f.position.z,
			Sim.format_clock(float(f.time))])
	file.close()
	Sim.toast.emit("REPORT EXPORTED: %s" % path.get_file(), Sim.Severity.INFO)
	Sfx.play("marker_drop", -6.0)


func _start_flight() -> void:
	state = State.HIDDEN
	get_tree().paused = false
	Sfx.play("ui_switch", -4.0)
	Sim.toast.emit("CLEARED FOR LAUNCH  -  F1 FOR CONTROLS", Sim.Severity.INFO)


func _pause() -> void:
	state = State.PAUSED
	get_tree().paused = true
	Sfx.play("ui_click")


func _resume() -> void:
	state = State.HIDDEN
	get_tree().paused = false
	Sfx.play("ui_click")


# ----------------------------------------------------------------- drawing

func _draw_menu() -> void:
	match state:
		State.BRIEFING:
			_draw_briefing()
		State.PAUSED:
			_draw_settings()


func _scale() -> float:
	return minf(_root.size.x / 1920.0, _root.size.y / 1080.0)


func _text(pos: Vector2, text: String, px: float, colour: Color, mono := false) -> void:
	var font: Font = _mono if mono else _font
	_root.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(px), colour)


func _draw_briefing() -> void:
	var s := _scale()
	var size := _root.size
	_root.draw_rect(Rect2(Vector2.ZERO, size), COL_BG, true)

	var x := size.x * 0.12
	var y := size.y * 0.09

	_text(Vector2(x, y), "PORT OF BEIRUT  -  SECTOR 4", 40.0 * s, COL_EDGE)
	y += 34.0 * s
	_text(Vector2(x, y), "SEARCH AND RESCUE DRONE ASSESSMENT", 22.0 * s, COL_DIM)
	y += 46.0 * s

	for line in BRIEFING_BODY:
		var px := 17.0 * s
		if line[1] == COL_WARN:
			px = 19.0 * s
			y += 6.0 * s
		_text(Vector2(x, y), line[0], px, line[1])
		y += 23.0 * s

	y = size.y - 96.0 * s
	_root.draw_line(Vector2(x, y - 26.0 * s), Vector2(size.x - x, y - 26.0 * s),
		Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.4), 1.0)
	_text(Vector2(x, y), "Space, A or X to launch    -    F1 controls    -    Esc settings",
		20.0 * s, COL_EDGE, true)
	_text(Vector2(x, y + 28.0 * s),
		"Built with CC0 assets. Full credits in assets/CREDITS.md.", 15.0 * s, COL_DIM)


func _draw_settings() -> void:
	var s := _scale()
	var size := _root.size
	_root.draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.02, 0.03, 0.82), true)

	var w := 760.0 * s
	var h := 700.0 * s
	var rect := Rect2((size - Vector2(w, h)) * 0.5, Vector2(w, h))
	_root.draw_rect(rect, COL_BG, true)
	_root.draw_rect(rect, COL_EDGE, false, 2.0)

	var x := rect.position.x + 36.0 * s
	var y := rect.position.y + 52.0 * s
	_text(Vector2(x, y), "SETTINGS", 30.0 * s, COL_EDGE)
	y += 40.0 * s

	for i in _rows.size():
		var row := _rows[i]
		if row.kind == "header":
			y += 12.0 * s
			_text(Vector2(x, y), row.label, 17.0 * s, COL_WARN, true)
			y += 26.0 * s
			continue

		if i == _selected:
			_root.draw_rect(Rect2(Vector2(x - 12.0 * s, y - 17.0 * s),
				Vector2(w - 48.0 * s, 26.0 * s)), COL_SEL, true)

		var colour: Color = COL_TEXT if i == _selected else COL_DIM
		_text(Vector2(x, y), row.label, 18.0 * s, colour)

		var value := ""
		match row.kind:
			"toggle":
				value = "ON" if bool(Sim.settings[row.key]) else "OFF"
			"slider":
				value = "%.2f" % float(Sim.settings[row.key])
			"action":
				match row.get("id", ""):
					"quality":
						value = (WorldBuilder.Quality.keys()[main.world.quality]
							if main and main.world else "-")
					"timeofday":
						value = (main.world.time_preset_name()
							if main and main.world else "-")
					"flightmodel":
						value = Drone.FLIGHT_MODEL_NAMES[
							int(Sim.settings.get("flight_model", 0))]
					_:
						value = ">"
		var font: Font = _mono
		var vw := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(18.0 * s)).x
		_text(Vector2(rect.end.x - 36.0 * s - vw, y), value, 18.0 * s,
			COL_EDGE if i == _selected else COL_DIM, true)
		y += 28.0 * s

	# A one-line explanation of whatever is highlighted, so the menu says what
	# each switch does instead of assuming you already know.
	var hint := str(_rows[_selected].get("hint", "")) if _selectable(_selected) else ""
	if hint != "":
		_text(Vector2(x, rect.end.y - 56.0 * s), hint, 15.0 * s, COL_WARN)

	_text(Vector2(x, rect.end.y - 28.0 * s),
		"W / S to move   A / D to change   X or A to select   Esc to close",
		14.0 * s, COL_DIM)
