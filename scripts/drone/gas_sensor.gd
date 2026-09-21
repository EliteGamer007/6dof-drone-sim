class_name GasSensor
extends Node3D
## Five-channel gas detector head (CO / H2S / NO2 / LEL / O2), modelled on the
## pumped sensor pods flown on inspection drones.
##
## Readings are deliberately *not* instantaneous. Each channel has a T90
## response time - short, because a drone pod pulls air past its cells with a
## pump, but not zero - and a little sensor noise, so on the HUD the numbers
## climb and settle the way real cells do. Peak-hold, exposure accumulation and
## a one-minute history are kept because that is what an incident commander
## actually asks for.

signal reading_changed(readings: PackedFloat32Array)
signal alarm_level_changed(level: int)
signal reading_logged(finding: Dictionary)

## Seconds for each channel to reach 90% of a step change. Electrochemical
## cells (CO, H2S, NO2) are slower than the catalytic LEL bead and the O2 cell.
const T90 := [5.0, 6.0, 9.0, 3.0, 4.0]

## The pod samples at 20 Hz, like the real units; the filter runs every tick.
const SAMPLE_INTERVAL := 0.05

## One minute of history at 5 Hz, for the trend graphs.
const HISTORY_RATE := 0.2
const HISTORY_LENGTH := 300

## A new gas finding is only logged this far from an earlier one on the same
## channel, so the log reads like a survey rather than a stuck alarm.
const LOG_SPACING := 28.0

@export var noise_amplitude := 0.6

var readings := PackedFloat32Array()      ## filtered, what the HUD shows
var raw := PackedFloat32Array()           ## true field value at the sensor
var peak := PackedFloat32Array()
var exposure := PackedFloat32Array()      ## ppm-minutes, for the report
var alarm_level := 0
var trend := PackedFloat32Array()         ## per channel, signed rate of change
var hazard_index := 0.0                   ## worst channel, relative to its first alarm

var _history: Array[PackedFloat32Array] = []
var _history_index: PackedFloat32Array = PackedFloat32Array()
var _history_head := 0
var _history_filled := 0
var _history_accumulator := 0.0

var _noise := FastNoiseLite.new()
var _time := 0.0
var _sample_accumulator := 0.0
var _beep_accumulator := 0.0
var _logged: Array[Dictionary] = []       ## {gas, position}


func _ready() -> void:
	var n := Hazards.GAS_COUNT
	readings.resize(n)
	raw.resize(n)
	peak.resize(n)
	exposure.resize(n)
	trend.resize(n)
	for i in n:
		readings[i] = Hazards.GAS_BASELINE[i]
		raw[i] = Hazards.GAS_BASELINE[i]
		peak[i] = Hazards.GAS_BASELINE[i]
		var h := PackedFloat32Array()
		h.resize(HISTORY_LENGTH)
		h.fill(Hazards.GAS_BASELINE[i])
		_history.append(h)
	_history_index.resize(HISTORY_LENGTH)
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.6


func _physics_process(delta: float) -> void:
	_time += delta

	_sample_accumulator += delta
	if _sample_accumulator >= SAMPLE_INTERVAL:
		_sample_accumulator = 0.0
		raw = Hazards.sample_gas(global_position)

	var n := Hazards.GAS_COUNT
	for i in n:
		var target := raw[i]
		if Sim.settings.sensor_noise:
			var scale: float = Hazards.GAS_FULL_SCALE[i] * 0.0025 * noise_amplitude
			target += _noise.get_noise_2d(_time * 9.0, float(i) * 37.0) * scale
		# first-order lag: T90 = 2.303 * tau
		var tau: float = maxf(T90[i] / 2.303, 0.05)
		var alpha: float = 1.0 - exp(-delta / tau)
		var previous := readings[i]
		readings[i] = maxf(lerpf(readings[i], target, alpha), 0.0)
		trend[i] = (readings[i] - previous) / maxf(delta, 0.0001)

		if i == Hazards.Gas.O2:
			peak[i] = minf(peak[i], readings[i])
		else:
			peak[i] = maxf(peak[i], readings[i])
			exposure[i] += readings[i] * delta / 60.0

	hazard_index = Hazards.hazard_index(readings)
	reading_changed.emit(readings)
	_record_history(delta)

	var level := Hazards.alarm_level(readings)
	if level != alarm_level:
		alarm_level = level
		alarm_level_changed.emit(level)
	if level >= 1:
		_maybe_log()

	_update_audio(delta)


func _record_history(delta: float) -> void:
	_history_accumulator += delta
	if _history_accumulator < HISTORY_RATE:
		return
	_history_accumulator = 0.0
	for i in Hazards.GAS_COUNT:
		_history[i][_history_head] = readings[i]
	_history_index[_history_head] = hazard_index
	_history_head = (_history_head + 1) % HISTORY_LENGTH
	_history_filled = mini(_history_filled + 1, HISTORY_LENGTH)


## Oldest-first copy of a channel's last minute. Pass -1 for the combined
## hazard index.
func history(channel: int) -> PackedFloat32Array:
	var src: PackedFloat32Array = _history_index if channel < 0 else _history[channel]
	var out := PackedFloat32Array()
	out.resize(_history_filled)
	var start := (_history_head - _history_filled + HISTORY_LENGTH) % HISTORY_LENGTH
	for k in _history_filled:
		out[k] = src[(start + k) % HISTORY_LENGTH]
	return out


## Logs an elevated reading as a finding at the aircraft's position, unless the
## same channel was already logged close by. Flying a site therefore leaves a
## trail of located readings - a gas survey - rather than one alarm entry.
func _maybe_log() -> void:
	var worst := worst_channel()
	var level := Hazards.channel_alarm_level(worst, readings[worst])
	if level < 1:
		return
	for entry in _logged:
		if int(entry.gas) == worst and (entry.position as Vector3).distance_to(global_position) < LOG_SPACING:
			if level > int(entry.level):
				entry.level = level      # it got worse here - escalate in place
				(entry.finding as Dictionary).severity = _severity(level)
			return

	var finding := Sim.log_finding(
		Sim.FindingKind.GAS_LEAK,
		"%s %.1f %s" % [Hazards.GAS_NAMES[worst], readings[worst], Hazards.GAS_UNITS[worst]],
		_severity(level),
		global_position,
		"",
		{
			"gas": worst,
			"value": readings[worst],
			"level": level,
			"reading": true,
			"detail": "%s measured at %.0f m above ground. %s" % [
				Hazards.GAS_LONG_NAMES[worst], _altitude(),
				["", "Above the occupational exposure limit.",
					"Above the second alarm threshold.",
					"Immediately dangerous to life or health."][level]],
		})
	_logged.append({"gas": worst, "position": global_position, "level": level,
		"finding": finding})
	reading_logged.emit(finding)


func _severity(level: int) -> Sim.Severity:
	if level >= 3:
		return Sim.Severity.CRITICAL
	if level == 2:
		return Sim.Severity.WARNING
	return Sim.Severity.CAUTION


func _altitude() -> float:
	var parent := get_parent()
	if parent and parent.has_method("altitude_agl"):
		return parent.altitude_agl()
	return 0.0


func _update_audio(delta: float) -> void:
	if alarm_level <= 0:
		_beep_accumulator = 0.0
		return
	var interval: float = [0.0, 0.85, 0.42, 0.16][mini(alarm_level, 3)]
	_beep_accumulator += delta
	if _beep_accumulator >= interval:
		_beep_accumulator = 0.0
		if alarm_level >= 3:
			Sfx.play("alarm_critical", -6.0, 1.0, 1.4)
		else:
			Sfx.play("alarm_gas", -10.0 + alarm_level * 2.0, 1.0)


## Index of the channel that is furthest into alarm right now.
func worst_channel() -> int:
	var worst := 0
	var worst_score := -1.0
	for i in Hazards.GAS_COUNT:
		var level := Hazards.channel_alarm_level(i, readings[i])
		var score := float(level) + Hazards.normalised(i, readings[i])
		if score > worst_score:
			worst_score = score
			worst = i
	return worst


func reset_peaks() -> void:
	for i in Hazards.GAS_COUNT:
		peak[i] = readings[i]
		exposure[i] = 0.0
	_logged.clear()
