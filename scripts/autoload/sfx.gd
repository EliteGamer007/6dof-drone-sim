extends Node
## Small pooled sound player for UI, alarms and impacts.
##
## Autoloaded as `Sfx`.

const BANK := {
	"alarm_gas": "res://assets/audio/alarm_gas.wav",
	"alarm_critical": "res://assets/audio/alarm_critical.wav",
	"proximity": "res://assets/audio/proximity.wav",
	"detect_ping": "res://assets/audio/detect_ping.wav",
	"ui_click": "res://assets/audio/ui_click.wav",
	"ui_switch": "res://assets/audio/ui_switch.wav",
	"shutter": "res://assets/audio/shutter.wav",
	"marker_drop": "res://assets/audio/marker_drop.wav",
	"low_battery": "res://assets/audio/low_battery.wav",
	"impact": "res://assets/audio/impact.wav",
	"mission_complete": "res://assets/audio/mission_complete.wav",
	"wind_loop": "res://assets/audio/wind_loop.wav",
}

const POOL_SIZE := 12

var _streams := {}
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _wind: AudioStreamPlayer = null

## Minimum seconds between two plays of the same cue, so alarms cannot machine-gun.
var _last_played := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for key in BANK:
		var stream := load(BANK[key])
		if stream == null:
			push_warning("Sfx: missing %s" % BANK[key])
			continue
		_streams[key] = stream

	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(p)
		_pool.append(p)

	_start_wind()


func _start_wind() -> void:
	if not _streams.has("wind_loop"):
		return
	var stream: AudioStream = _streams["wind_loop"]
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = 0
	_wind = AudioStreamPlayer.new()
	_wind.stream = stream
	_wind.bus = "Master"
	_wind.volume_db = -22.0
	add_child(_wind)
	_wind.play()


func set_wind_intensity(speed: float) -> void:
	if _wind == null:
		return
	_wind.volume_db = lerpf(-30.0, -12.0, clampf(speed / 14.0, 0.0, 1.0))
	_wind.pitch_scale = lerpf(0.85, 1.25, clampf(speed / 16.0, 0.0, 1.0))


func play(key: String, volume_db: float = 0.0, pitch: float = 1.0,
		min_interval: float = 0.0) -> void:
	if not _streams.has(key):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if min_interval > 0.0 and now - float(_last_played.get(key, -999.0)) < min_interval:
		return
	_last_played[key] = now

	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = _streams[key]
	p.volume_db = volume_db + linear_to_db(clampf(Sim.settings.master_volume, 0.0, 1.0))
	p.pitch_scale = pitch
	p.play()


func stop_all() -> void:
	for p in _pool:
		p.stop()
