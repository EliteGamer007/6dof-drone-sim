class_name WristPanel
extends Control
## Compact atmosphere readout rendered onto the left controller.
##
## A pilot in a headset should not have to hunt across a large panel to answer
## "is the air here safe". Putting the five channels on the wrist means the
## check is a glance at your own hand, which is also how the physical
## instrument is worn.

const COL_BG := Color(0.02, 0.05, 0.06, 0.88)
const COL_EDGE := Color(0.30, 0.92, 0.80, 0.8)
const COL_TEXT := Color(0.88, 0.97, 0.97)
const COL_DIM := Color(0.55, 0.68, 0.70)
const COL_WARN := Color(1.0, 0.72, 0.20)
const COL_CRIT := Color(1.0, 0.32, 0.30)

var drone: Drone

var _font: Font
var _blink := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	var mono := "res://assets/fonts/mono.ttf"
	if ResourceLoader.exists(mono):
		var f := load(mono)
		if f is Font:
			_font = f


func _process(delta: float) -> void:
	_blink = fmod(_blink + delta, 1.0)
	queue_redraw()


func _draw() -> void:
	if drone == null or not is_instance_valid(drone) or drone.gas_sensor == null:
		return
	var s := size
	var sensor := drone.gas_sensor

	var edge := COL_EDGE
	if sensor.alarm_level >= 3:
		edge = COL_CRIT
	elif sensor.alarm_level == 2:
		edge = COL_WARN

	draw_rect(Rect2(Vector2.ZERO, s), COL_BG, true)
	draw_rect(Rect2(Vector2(2, 2), s - Vector2(4, 4)), edge, false, 3.0)

	var pad := 16.0
	var fs := 26

	var header: String = ["AIR CLEAR", "ALARM 1", "ALARM 2",
		"IDLH - ABORT"][mini(sensor.alarm_level, 3)]
	var header_col: Color = [COL_EDGE, COL_WARN, COL_WARN,
		COL_CRIT][mini(sensor.alarm_level, 3)]
	if sensor.alarm_level >= 2 and _blink < 0.5:
		header_col = Color.WHITE
	draw_string(_font, Vector2(pad, 34), header, HORIZONTAL_ALIGNMENT_LEFT, -1,
		fs, header_col)

	var alt := "%.0f m" % drone.altitude_agl()
	draw_string(_font, Vector2(s.x - pad - 90, 34), alt, HORIZONTAL_ALIGNMENT_RIGHT,
		90, fs, COL_DIM)

	var y := 60.0
	var row := 52.0
	for i in Hazards.GAS_COUNT:
		var value := sensor.readings[i]
		var level := Hazards.channel_alarm_level(i, value)
		var colour: Color = Hazards.GAS_COLORS[i]
		if level >= 3:
			colour = COL_CRIT
		elif level == 2:
			colour = COL_WARN

		draw_string(_font, Vector2(pad, y + 26), Hazards.GAS_NAMES[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)
		draw_string(_font, Vector2(pad + 70, y + 26),
			"%6.1f %s" % [value, Hazards.GAS_UNITS[i]],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)

		var bar := Rect2(Vector2(s.x - pad - 180.0, y + 8.0), Vector2(180.0, 20.0))
		draw_rect(bar, Color(0.09, 0.13, 0.14, 0.9), true)
		draw_rect(Rect2(bar.position,
			Vector2(bar.size.x * Hazards.normalised(i, value), bar.size.y)),
			colour, true)
		if i != Hazards.Gas.O2:
			var tx: float = bar.position.x + bar.size.x \
				* clampf(Hazards.GAS_ALARM_LOW[i] / Hazards.GAS_FULL_SCALE[i], 0.0, 1.0)
			draw_line(Vector2(tx, bar.position.y), Vector2(tx, bar.end.y),
				Color(1, 1, 1, 0.6), 2.0)
		draw_rect(bar, Color(edge.r, edge.g, edge.b, 0.5), false, 1.5)
		y += row

	draw_string(_font, Vector2(s.x - pad - 200, s.y - 14),
		Sim.VISION_NAMES[Sim.vision_mode], HORIZONTAL_ALIGNMENT_RIGHT, 200, fs, COL_DIM)
