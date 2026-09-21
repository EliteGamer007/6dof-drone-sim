class_name SelfTest
extends Node
## Automated smoke test, run with:
##
##   Godot --headless --path . -- --selftest
##
## Flies the aircraft through the whole site, exercises every sensor mode and
## every action that writes something out, and fails loudly if any subsystem
## returns nonsense. It exists because the interesting failures in this project
## are not crashes - they are a sensor quietly reading zero, or a finding never
## being logged - and those do not show up by looking at the screen.

signal finished(passed: bool)

## Each stop declares what it is supposed to find, so the test asserts against
## the scenario rather than just against "did anything happen".
##   position   - where to hover, relative to the ground at that point
##   expect_gas - channel index that should read above its first alarm here
##   expect_hot - a heat source should be detectable from here
const WAYPOINTS := [
	{"name": "pad", "position": Vector3(0.0, 14.0, 60.0)},
	{"name": "collapsed block", "position": Vector3(-38.0, 6.0, 36.0),
		"expect_hot": true},
	{"name": "lpg leak", "position": Vector3(-45.0, 2.0, 11.0),
		"expect_gas": Hazards.Gas.LEL},
	{"name": "drainage void", "position": Vector3(-34.0, 2.0, 40.5),
		"expect_gas": Hazards.Gas.H2S},
	{"name": "crater", "position": Vector3(-6.0, 3.0, -19.0),
		"expect_gas": Hazards.Gas.NO2},
	{"name": "container fire", "position": Vector3(27.0, 3.0, 43.0),
		"expect_gas": Hazards.Gas.CO, "expect_hot": true},
	{"name": "ruptured silo", "position": Vector3(-52.0, 2.0, -60.0),
		"expect_gas": Hazards.Gas.O2},
	{"name": "warehouse", "position": Vector3(44.0, 4.0, -38.0),
		"expect_hot": true},
	{"name": "return", "position": Vector3(0.0, 6.0, 92.0)},
]

## The detector cells have a T90 of 12-25 seconds. Anything shorter than this
## and the test is measuring the filter, not the scenario.
const HOLD_SECONDS := 9.0

var _main: Node
var _index := 0
var _elapsed := 0.0
var _started := false
var _failures: Array[String] = []
var _checks := 0
var _seen_gas := {}
var _max_alarm := 0


func setup(main: Node) -> void:
	_main = main


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[selftest] starting - %d stops, %.0fs each" % [WAYPOINTS.size(), HOLD_SECONDS])


func _physics_process(delta: float) -> void:
	if _main == null or _main.drone == null:
		return
	var drone: Drone = _main.drone

	if not _started:
		_started = true
		_teleport(drone, WAYPOINTS[_index])

	_elapsed += delta

	# Hold the aircraft still: this is a sensor test, not a flight test, and a
	# drifting drone would leave the plume it is meant to be measuring.
	drone.linear_velocity = Vector3.ZERO
	drone.angular_velocity = Vector3.ZERO

	var worst := drone.gas_sensor.worst_channel()
	if drone.gas_sensor.readings[worst] > Hazards.GAS_ALARM_LOW[worst] * 0.6:
		_seen_gas[worst] = true
	_max_alarm = maxi(_max_alarm, drone.gas_sensor.alarm_level)

	if _elapsed < HOLD_SECONDS:
		return

	_run_checks_for_waypoint(drone, WAYPOINTS[_index])
	_elapsed = 0.0
	_index += 1
	if _index >= WAYPOINTS.size():
		_finish()
	else:
		_teleport(drone, WAYPOINTS[_index])


func _teleport(drone: Drone, stop: Dictionary) -> void:
	var target: Vector3 = stop.position
	var ground: float = _main.world.terrain_height(target.x, target.z)
	drone.global_position = Vector3(target.x, ground + target.y, target.z)
	drone.linear_velocity = Vector3.ZERO
	drone.angular_velocity = Vector3.ZERO
	var flat := Vector3(0.0, 0.0, -12.0) - drone.global_position
	flat.y = 0.0
	if flat.length() > 0.1:
		drone.global_basis = Basis(Vector3.UP, atan2(-flat.x, -flat.z))
	drone.gimbal_pitch = -25.0
	Sim.set_vision_mode((_index % 4) as Sim.VisionMode)
	if _index % 2 == 0:
		Sim.cycle_palette()


func _check(label: String, condition: bool, detail := "") -> void:
	_checks += 1
	if condition:
		return
	_failures.append("%s%s" % [label, (" (%s)" % detail) if detail != "" else ""])


func _run_checks_for_waypoint(drone: Drone, stop: Dictionary) -> void:
	var label: String = stop.name

	_check("%s: altitude sane" % label,
		drone.altitude_agl() > -1.0 and drone.altitude_agl() < 120.0,
		"%.1f m" % drone.altitude_agl())
	_check("%s: battery in range" % label,
		drone.battery_percent > 0.0 and drone.battery_percent <= 100.0,
		"%.1f%%" % drone.battery_percent)
	_check("%s: proximity ring reporting" % label,
		drone.proximity.closest_distance > 0.0,
		"%.2f m" % drone.proximity.closest_distance)

	for i in Hazards.GAS_COUNT:
		var value := drone.gas_sensor.readings[i]
		_check("%s: %s finite" % [label, Hazards.GAS_NAMES[i]],
			is_finite(value) and value >= 0.0, str(value))
	_check("%s: oxygen plausible" % label,
		drone.gas_sensor.readings[Hazards.Gas.O2] > 3.0
			and drone.gas_sensor.readings[Hazards.Gas.O2] <= 23.5,
		"%.2f %%" % drone.gas_sensor.readings[Hazards.Gas.O2])

	var temp := Hazards.sample_temperature(drone.global_position)
	_check("%s: temperature field sane" % label,
		temp > -40.0 and temp < 1200.0, "%.1f C" % temp)

	# The scenario expectations: does this place actually contain what the
	# world builder says it contains, and does the sensor see it?
	if stop.has("expect_gas"):
		var channel: int = stop.expect_gas
		var raw := drone.gas_sensor.raw[channel]
		var shown := drone.gas_sensor.readings[channel]
		if channel == Hazards.Gas.O2:
			_check("%s: oxygen depleted in the field" % label, raw < 19.5,
				"%.2f %%" % raw)
			_check("%s: oxygen depletion reaches the display" % label,
				shown < 20.4, "%.2f %%" % shown)
		else:
			_check("%s: %s present in the field" % [label, Hazards.GAS_NAMES[channel]],
				raw > Hazards.GAS_ALARM_LOW[channel], "%.1f" % raw)
			_check("%s: %s reaches the display" % [label, Hazards.GAS_NAMES[channel]],
				shown > Hazards.GAS_ALARM_LOW[channel] * 0.5, "%.1f" % shown)
			_seen_gas[channel] = true

	if stop.get("expect_hot", false):
		# the hottest heat-source surface within 25 m of the aircraft
		var best := Hazards.ambient_temp
		for h in Hazards.heat_sources:
			var n: Node3D = h.node
			if is_instance_valid(n) and n.global_position.distance_to(drone.global_position) < 25.0:
				best = maxf(best, Hazards.sample_temperature(n.global_position))
		_check("%s: thermal contrast present" % label,
			best > Hazards.ambient_temp + 3.0,
			"%.1f C vs ambient %.1f" % [best, Hazards.ambient_temp])

	# Actions that write something out.
	_main.drop_marker()
	_main.capture_evidence()


func _finish() -> void:
	var drone: Drone = _main.drone

	_check("wind is moving", Hazards.current_wind().length() > 0.1)
	_check("hazard field populated",
		Hazards.plumes.size() >= 5 and Hazards.heat_sources.size() >= 8,
		"%d plumes, %d heat" % [Hazards.plumes.size(), Hazards.heat_sources.size()])
	_check("detectables registered",
		get_tree().get_nodes_in_group("detectable").size() >= 15,
		str(get_tree().get_nodes_in_group("detectable").size()))
	_check("findings logged", Sim.findings.size() >= WAYPOINTS.size(),
		str(Sim.findings.size()))
	_check("beacons spawned", _main.beacons.get_child_count() >= WAYPOINTS.size(),
		str(_main.beacons.get_child_count()))
	_check("gas encountered on at least two channels", _seen_gas.size() >= 2,
		str(_seen_gas.keys()))
	_check("a gas alarm was raised at some point", _max_alarm >= 1,
		"max level %d" % _max_alarm)
	_check("distance accumulated", drone.total_distance > 100.0,
		"%.0f m" % drone.total_distance)
	_check("coverage accumulated", Sim.coverage_percent > 0.0,
		"%.1f%%" % Sim.coverage_percent)
	_check("report exports", _export_report_ok())
	_check_launch_pad(drone)
	_check_contact_tagging()
	_check_thermal_field()
	_check_graphics_presets()
	_check_day_night()

	print("\n[selftest] %d checks, %d failures" % [_checks, _failures.size()])
	for f in _failures:
		print("  FAIL  %s" % f)
	print("[selftest] findings=%d coverage=%.1f%% photos=%d battery=%.0f%%" % [
		Sim.findings.size(), Sim.coverage_percent, Sim.photos_taken,
		drone.battery_percent])
	print("[selftest] %s" % ("PASS" if _failures.is_empty() else "FAIL"))

	finished.emit(_failures.is_empty())
	get_tree().quit(0 if _failures.is_empty() else 1)


## The complaint this guards: "in thermal you can only see the fires and the
## rest is plain". The environment model has to produce real variation across
## the site, and that variation has to sit *below* body temperature, or people
## stop standing out from it.
func _check_thermal_field() -> void:
	var samples := PackedFloat32Array()
	var lowest := INF
	var highest := -INF
	for i in 60:
		var a := TAU * float(i) / 60.0
		var r := 12.0 + float(i % 7) * 14.0
		var x := cos(a) * r
		var z := -12.0 + sin(a) * r
		var p := Vector3(x, _main.world.terrain_height(x, z) + 0.05, z)
		var t := Hazards.environment_temperature(p, Vector3.UP)
		samples.append(t)
		lowest = minf(lowest, t)
		highest = maxf(highest, t)

	var mean := 0.0
	for t in samples:
		mean += t
	mean /= float(samples.size())
	var variance := 0.0
	for t in samples:
		variance += (t - mean) * (t - mean)
	variance /= float(samples.size())
	var deviation := sqrt(variance)

	_check("ground temperature varies across the site", deviation > 0.6,
		"standard deviation %.2f C" % deviation)
	_check("ground temperature spans a usable range", highest - lowest > 2.0,
		"%.1f C to %.1f C" % [lowest, highest])
	_check("ground stays cooler than a person", highest < Victim.CLOTHED_LIMB - 1.0,
		"hottest ground %.1f C vs a limb at %.1f C" % [highest, Victim.CLOTHED_LIMB])

	# A wall that faced the afternoon sun must read warmer than ground that has
	# been radiating to the sky since sunset - that contrast is the image.
	var here := Vector3(0.0, _main.world.terrain_height(0.0, 40.0) + 0.05, 40.0)
	var flat := Hazards.environment_temperature(here, Vector3.UP)
	var wall := Hazards.environment_temperature(here,
		Hazards.AFTERNOON_SUN.normalized())
	_check("sunward faces read warmer than sky-facing ground", wall > flat + 1.5,
		"wall %.1f C vs ground %.1f C" % [wall, flat])


## Every preset has to apply without throwing, and has to actually differ -
## a graphics menu whose settings all do the same thing is worse than none.
func _check_graphics_presets() -> void:
	var original: int = int(_main.world.quality)
	var distances := []
	for preset in [WorldBuilder.Quality.LOW, WorldBuilder.Quality.MEDIUM,
			WorldBuilder.Quality.HIGH]:
		_main.world.apply_quality(preset)
		_check("graphics preset %s applies" % WorldBuilder.Quality.keys()[preset],
			int(_main.world.quality) == int(preset))
		distances.append(_main.world.sun.directional_shadow_max_distance)
	_check("the graphics presets are actually different",
		distances[0] < distances[1] and distances[1] < distances[2],
		str(distances))
	_main.world.apply_quality(original as WorldBuilder.Quality)


## Night has to be night: dark, colder, and with the site lighting switched on.
func _check_day_night() -> void:
	var original := Sim.time_of_day

	_main.world.set_time_of_day(13.0)
	var day_light := Sim.daylight
	var day_temp := Hazards.ambient_temp

	_main.world.set_time_of_day(22.3)
	_check("night is dark", Sim.daylight < 0.05, "daylight %.3f" % Sim.daylight)
	_check("day is lit", day_light > 0.6, "daylight %.3f" % day_light)
	_check("the ground cools off after dark", Hazards.ambient_temp < day_temp - 3.0,
		"%.1f C at night vs %.1f C at midday" % [Hazards.ambient_temp, day_temp])

	var lights := get_tree().get_nodes_in_group(WorldBuilder.NIGHT_LIGHT_GROUP)
	_check("the site has night lighting to switch on", lights.size() >= 4,
		"%d lights" % lights.size())
	var lit := 0
	for node in lights:
		if node is Node3D and node.visible:
			lit += 1
	_check("night lighting is on at night", lit == lights.size(),
		"%d of %d lit" % [lit, lights.size()])

	_main.world.set_time_of_day(13.0)
	lit = 0
	for node in lights:
		if node is Node3D and node.visible:
			lit += 1
	_check("night lighting is off by day", lit == 0, "%d still lit" % lit)

	# The named presets the settings menu steps through have to round-trip.
	_main.world.set_time_of_day(22.3)
	_check("the night preset is named NIGHT", _main.world.time_preset_name() == "NIGHT",
		_main.world.time_preset_name())
	_main.world.set_time_of_day(13.0)
	_check("the midday preset is named DAY", _main.world.time_preset_name() == "DAY",
		_main.world.time_preset_name())

	_main.world.set_time_of_day(original)


## The aircraft has to start on the response van's deck, not hovering beside
## it and not buried in it, or "return to the van" is not a thing the operator
## can be asked to do.
func _check_launch_pad(drone: Drone) -> void:
	var pad: Vector3 = _main.world.launch_position()
	var ground: float = _main.world.terrain_height(pad.x, pad.z)
	_check("launch pad sits on the van deck", pad.y - ground > 2.0,
		"%.2f m above ground" % (pad.y - ground))
	_check("home position is the launch pad",
		Sim.home_position.distance_to(pad) < 0.5,
		"%.2f m off" % Sim.home_position.distance_to(pad))

	# A downward ray from just above the deck has to land on the van, which is
	# what makes the deck something the drone can be flown back onto.
	var from := pad + Vector3.UP * 0.5
	var params := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0)
	params.exclude = [drone.get_rid()]
	var space: PhysicsDirectSpaceState3D = _main.get_world_3d().direct_space_state
	var hit: Dictionary = space.intersect_ray(params)
	_check("the deck is a solid surface to land on", not hit.is_empty()
		and hit.position.y > ground + 1.5,
		"nothing under the pad" if hit.is_empty() else "%.2f m" % hit.position.y)


## Guards the reported bug: tagging one survivor repeatedly used to file a new
## finding every press and walk the objective counter up with it.
func _check_contact_tagging() -> void:
	var victim: Victim = null
	for node in get_tree().get_nodes_in_group("detectable"):
		if node is Victim and not (node as Victim).tagged:
			victim = node
			break
	if victim == null:
		_check("an untagged survivor was available to test against", false)
		return

	var findings_before := Sim.findings.size()
	var counted_before: int = _main.mission._count_kind(Sim.FindingKind.VICTIM)

	_main._tag_contact(victim)
	_check("tagging a survivor files one finding",
		Sim.findings.size() == findings_before + 1,
		"%d -> %d" % [findings_before, Sim.findings.size()])
	_check("the survivor is flagged as accounted for", victim.tagged)
	_check("the survivor count goes up by one",
		_main.mission._count_kind(Sim.FindingKind.VICTIM) == counted_before + 1,
		"%d -> %d" % [counted_before,
			_main.mission._count_kind(Sim.FindingKind.VICTIM)])

	for i in 6:
		_main._tag_contact(victim)
	_check("re-tagging the same survivor files nothing further",
		Sim.findings.size() == findings_before + 1,
		"%d findings after 6 more presses" % Sim.findings.size())
	_check("the survivor count does not move on a re-tag",
		_main.mission._count_kind(Sim.FindingKind.VICTIM) == counted_before + 1,
		str(_main.mission._count_kind(Sim.FindingKind.VICTIM)))

	# Survivors must not file themselves: the operator has to tag them.
	var untagged := 0
	for node in get_tree().get_nodes_in_group("detectable"):
		if node is Victim and not (node as Victim).tagged:
			untagged += 1
	_check("survivors are not auto-logged by the detector", untagged > 0,
		"every survivor was already logged without being tagged")


func _export_report_ok() -> bool:
	DirAccess.make_dir_recursive_absolute("user://reports")
	var path := "user://reports/selftest.csv"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_line("id,type,severity,finding")
	for f in Sim.findings:
		file.store_line("%d,%s,%s,\"%s\"" % [int(f.id), Sim.KIND_NAMES[int(f.kind)],
			Sim.SEVERITY_NAMES[int(f.severity)], str(f.text).replace("\"", "'")])
	file.close()
	return FileAccess.file_exists(path)
