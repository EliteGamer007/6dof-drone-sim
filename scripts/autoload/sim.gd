extends Node
## Global simulation state: mission clock, findings log, settings and the
## signal bus every other system talks over.
##
## Autoloaded as `Sim`.

# ---------------------------------------------------------------- enumerations

enum VisionMode { NORMAL, THERMAL, NIGHT, GAS }
enum ThermalPalette { WHITE_HOT, BLACK_HOT, IRONBOW, ARCTIC, LAVA, ALERT }
enum Severity { INFO, CAUTION, WARNING, CRITICAL }
enum FindingKind { VICTIM, GAS_LEAK, FIRE, STRUCTURAL, MARKER, PHOTO }

const VISION_NAMES := ["EO / DAYLIGHT", "THERMAL IR", "LOW-LIGHT NV", "GAS OVERLAY"]
const PALETTE_NAMES := ["WHITE HOT", "BLACK HOT", "IRONBOW", "ARCTIC", "LAVA",
	"ISOTHERM ALERT"]
const SEVERITY_NAMES := ["INFO", "CAUTION", "WARNING", "CRITICAL"]
const KIND_NAMES := ["SURVIVOR", "GAS LEAK", "FIRE", "STRUCTURE", "MARKER", "PHOTO"]

const SEVERITY_COLORS := [
	Color(0.55, 0.78, 0.95),
	Color(0.98, 0.83, 0.26),
	Color(1.0, 0.55, 0.15),
	Color(1.0, 0.25, 0.25),
]

## Local origin of the simulated survey area, so the HUD can print plausible
## WGS84 coordinates. This is the Port of Beirut blast site.
const ORIGIN_LAT := 33.901389
const ORIGIN_LON := 35.519167
const METRES_PER_DEG_LAT := 111320.0

# -------------------------------------------------------------------- signals

signal vision_mode_changed(mode: VisionMode)
signal palette_changed(palette: ThermalPalette)
signal finding_logged(finding: Dictionary)
signal marker_dropped(finding: Dictionary)
signal alarm_raised(severity: Severity, text: String)
signal toast(text: String, severity: Severity)
signal mission_started
signal mission_finished(summary: Dictionary)
signal coverage_changed(percent: float)
signal settings_changed

# ---------------------------------------------------------------------- state

var vision_mode: VisionMode = VisionMode.NORMAL
## White hot by default. It is what a search-and-rescue payload is actually
## flown in: the false-colour LUTs look dramatic in a screenshot and are
## harder to read, and ironbow in particular turns a whole frame of
## ambient-temperature ground into one pink wash. B cycles the others.
var thermal_palette: ThermalPalette = ThermalPalette.WHITE_HOT

var mission_running := false
var mission_time := 0.0
var coverage_percent := 0.0
var photos_taken := 0

var findings: Array[Dictionary] = []
var drone: Node3D = null            ## set by the drone when it enters the tree
var home_position := Vector3.ZERO

## Published by the world's time-of-day controller; read by the vision shader
## and the sensor model.
var sun_direction := Vector3(-0.4, -0.8, -0.45).normalized()
var daylight := 1.0                 ## 0 full night .. 1 midday
var time_of_day := 17.6             ## hours - early evening: readable, still good thermal
var xr_active := false              ## true once OpenXR initialises

## Only settings something actually reads live here. `invert_pitch`,
## `stick_expo` and `mouse_sensitivity` were carried by the menu long after the
## code that honoured them was replaced, so they were three switches that did
## nothing - they are gone.
var settings := {
	"master_volume": 0.9,
	"hud_opacity": 1.0,
	"quality": 1,                # WorldBuilder.Quality.MEDIUM
	"obstacle_assist": false,
	"show_detection_boxes": true,
	"sensor_noise": true,
	"gas_trail": true,           # 3D breadcrumb of every air sample
	# VR comfort. Both default on; turning them off is the "I have my VR legs"
	# setting, not the recommended demo configuration.
	"vr_follow_yaw": true,
	"vr_comfort_vignette": true,
}

const SETTINGS_PATH := "user://settings.cfg"

# ----------------------------------------------------------------- lifecycle

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()


func _process(delta: float) -> void:
	if mission_running:
		mission_time += delta


# ------------------------------------------------------------------- mission

func start_mission() -> void:
	# Contacts carry their own "already accounted for" flag, so clearing the
	# log without clearing them would leave the objective counters reading
	# full against an empty findings list.
	for node in get_tree().get_nodes_in_group("detectable"):
		node.tagged = false
		node.finding_id = 0
		node.first_detected_at = -1.0
	findings.clear()
	mission_time = 0.0
	coverage_percent = 0.0
	photos_taken = 0
	mission_running = true
	mission_started.emit()


func finish_mission() -> void:
	if not mission_running:
		return
	mission_running = false
	mission_finished.emit(build_summary())


func build_summary() -> Dictionary:
	var by_kind := {}
	for f in findings:
		by_kind[f.kind] = int(by_kind.get(f.kind, 0)) + 1
	return {
		"duration": mission_time,
		"findings": findings.duplicate(true),
		"counts": by_kind,
		"coverage": coverage_percent,
		"photos": photos_taken,
	}


## Records a finding. `key` de-duplicates: logging the same key twice only
## refreshes the existing entry instead of spamming the log.
func log_finding(kind: FindingKind, text: String, severity: Severity,
		position: Vector3, key: String = "", extra: Dictionary = {}) -> Dictionary:
	if key != "":
		for existing in findings:
			if existing.key == key:
				existing.last_seen = mission_time
				existing.position = position
				existing.merge(extra, true)
				return existing

	var finding := {
		"kind": kind,
		"text": text,
		"severity": severity,
		"position": position,
		"key": key,
		"time": mission_time,
		"last_seen": mission_time,
		"id": findings.size() + 1,
	}
	finding.merge(extra, true)
	findings.append(finding)
	finding_logged.emit(finding)
	if severity >= Severity.WARNING:
		alarm_raised.emit(severity, text)
	toast.emit("%s  %s" % [KIND_NAMES[kind], text], severity)
	return finding


func set_vision_mode(mode: VisionMode) -> void:
	if mode == vision_mode:
		return
	vision_mode = mode
	vision_mode_changed.emit(mode)


func cycle_vision_mode(step: int = 1) -> void:
	var count := VISION_NAMES.size()
	set_vision_mode(((vision_mode + step) % count + count) % count as VisionMode)


func cycle_palette() -> void:
	thermal_palette = ((thermal_palette + 1) % PALETTE_NAMES.size()) as ThermalPalette
	palette_changed.emit(thermal_palette)


# --------------------------------------------------------------- coordinates

## Converts a local metre position into plausible WGS84 degrees.
func to_latlon(pos: Vector3) -> Vector2:
	var lat := ORIGIN_LAT + (-pos.z) / METRES_PER_DEG_LAT
	var metres_per_deg_lon: float = METRES_PER_DEG_LAT * cos(deg_to_rad(ORIGIN_LAT))
	var lon := ORIGIN_LON + pos.x / metres_per_deg_lon
	return Vector2(lat, lon)


func format_latlon(pos: Vector3) -> String:
	var ll := to_latlon(pos)
	var ns := "N" if ll.x >= 0.0 else "S"
	var ew := "E" if ll.y >= 0.0 else "W"
	return "%.6f%s %.6f%s" % [absf(ll.x), ns, absf(ll.y), ew]


func format_clock(seconds: float) -> String:
	var total := int(seconds)
	return "%02d:%02d:%02d" % [total / 3600, (total / 60) % 60, total % 60]


# ------------------------------------------------------------------ settings

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for k in settings.keys():
		if cfg.has_section_key("sim", k):
			settings[k] = cfg.get_value("sim", k)
	settings_changed.emit()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in settings.keys():
		cfg.set_value("sim", k, settings[k])
	cfg.save(SETTINGS_PATH)


func set_setting(key: String, value: Variant) -> void:
	settings[key] = value
	settings_changed.emit()
	save_settings()
