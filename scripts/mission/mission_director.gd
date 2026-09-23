class_name MissionDirector
extends Node
## Mission objectives, survey coverage and the after-action report.
##
## The coverage grid is the piece that turns a free-flight demo into an
## assessment task: the operator can see which parts of the site they have
## actually looked at, which is the first question anyone asks about a drone
## survey.

signal objectives_changed
signal coverage_updated(percent: float)

const GRID_ORIGIN := Vector2(-110.0, -120.0)
const GRID_SIZE := Vector2i(24, 26)
const CELL := 9.5
const MIN_SURVEY_ALT := 4.0
const MAX_SURVEY_ALT := 70.0

var objectives: Array[Dictionary] = []
var covered := {}                 ## Vector2i -> true
var coverage_percent := 0.0
## Vector2i -> {level, gas}: the worst air the aircraft has sampled in each
## cell. This is the 2D half of the gas survey; the 3D half is the GasTrail.
var gas_cells := {}

var _drone: Drone
var _world: WorldBuilder
var _accumulator := 0.0
var _finished := false


func setup(drone: Drone, world: WorldBuilder) -> void:
	_drone = drone
	_world = world


func _ready() -> void:
	objectives = [
		{"id": "survivors", "text": "Locate and mark every survivor",
			"target": 6, "progress": 0, "done": false},
		{"id": "gas", "text": "Identify each gas hazard on site",
			"target": 4, "progress": 0, "done": false},
		{"id": "coverage", "text": "Survey 35% of the assessment zone",
			"target": 35, "progress": 0, "done": false},
		{"id": "structural", "text": "Flag unstable structures",
			"target": 3, "progress": 0, "done": false},
		{"id": "aid", "text": "Drop first-aid kits to survivors",
			"target": 3, "progress": 0, "done": false},
	]
	Sim.finding_logged.connect(_on_finding)
	objectives_changed.emit()


func _process(delta: float) -> void:
	if _drone == null or not is_instance_valid(_drone) or _finished:
		return
	_accumulator += delta
	if _accumulator < 0.18:
		return
	_accumulator = 0.0
	_update_coverage()
	_update_gas_map()
	_recount()
	_check_complete()


# ----------------------------------------------------------------- coverage

func _update_coverage() -> void:
	var agl := _drone.altitude_agl()
	if agl < MIN_SURVEY_ALT or agl > MAX_SURVEY_ALT:
		return
	# Swath width scales with height, the way a real mapping footprint does.
	var radius := clampf(agl * 0.62, CELL * 0.5, 34.0)
	var centre := Vector2(_drone.global_position.x, _drone.global_position.z)

	var before := covered.size()
	var span := int(ceil(radius / CELL))
	var base := _cell_of(centre)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var cell := base + Vector2i(dx, dz)
			if cell.x < 0 or cell.y < 0 or cell.x >= GRID_SIZE.x or cell.y >= GRID_SIZE.y:
				continue
			if covered.has(cell):
				continue
			if _cell_centre(cell).distance_to(centre) <= radius:
				covered[cell] = true

	if covered.size() == before:
		return
	coverage_percent = float(covered.size()) / float(GRID_SIZE.x * GRID_SIZE.y) * 100.0
	Sim.coverage_percent = coverage_percent
	coverage_updated.emit(coverage_percent)
	Sim.coverage_changed.emit(coverage_percent)
	_set_progress("coverage", int(coverage_percent))


func _update_gas_map() -> void:
	var sensor := _drone.gas_sensor
	if sensor == null:
		return
	var cell := _cell_of(Vector2(sensor.global_position.x, sensor.global_position.z))
	if cell.x < 0 or cell.y < 0 or cell.x >= GRID_SIZE.x or cell.y >= GRID_SIZE.y:
		return
	var level := sensor.hazard_index
	var existing: Dictionary = gas_cells.get(cell, {})
	if existing.is_empty() or level > float(existing.level):
		gas_cells[cell] = {"level": level, "gas": sensor.worst_channel()}


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floor((p.x - GRID_ORIGIN.x) / CELL)),
		int(floor((p.y - GRID_ORIGIN.y) / CELL)))


func _cell_centre(c: Vector2i) -> Vector2:
	return GRID_ORIGIN + Vector2((float(c.x) + 0.5) * CELL, (float(c.y) + 0.5) * CELL)


func is_covered(c: Vector2i) -> bool:
	return covered.has(c)


# --------------------------------------------------------------- objectives

func _on_finding(_finding: Dictionary) -> void:
	_recount()


## Recomputes every counter from the world itself rather than from whichever
## finding just arrived. Cheap, and it cannot drift: the objectives panel now
## always agrees with what is actually tagged out there.
func _recount() -> void:
	_set_progress("survivors", _count_kind(Sim.FindingKind.VICTIM))
	_set_progress("gas", _count_distinct_gases())
	_set_progress("structural", _count_kind(Sim.FindingKind.STRUCTURAL))
	_set_progress("aid", _count_supplied())


func _count_supplied() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("detectable"):
		var v := node as Victim
		if v != null and v.supplied:
			n += 1
	return n


func _count_kind(kind: Sim.FindingKind) -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("detectable"):
		var d := node as Detectable
		if d != null and d.tagged and int(d.kind) == int(kind):
			n += 1
	return n


func _count_distinct_gases() -> int:
	var seen := {}
	for f in Sim.findings:
		if int(f.kind) == Sim.FindingKind.GAS_LEAK and f.has("gas"):
			seen[int(f.gas)] = true
	return seen.size()


func _set_progress(id: String, value: int) -> void:
	for o in objectives:
		if o.id != id:
			continue
		if o.progress == value:
			return
		o.progress = value
		var done: bool = value >= int(o.target)
		if done and not o.done:
			o.done = true
			Sim.toast.emit("OBJECTIVE COMPLETE  %s" % o.text, Sim.Severity.INFO)
			Sfx.play("marker_drop", -6.0, 1.2)
		elif not done:
			o.done = false
		objectives_changed.emit()
		return


func _check_complete() -> void:
	for o in objectives:
		if not o.done:
			return
	_finished = true
	Sfx.play("mission_complete", -3.0)
	Sim.finish_mission()


func completed_count() -> int:
	var n := 0
	for o in objectives:
		if o.done:
			n += 1
	return n
