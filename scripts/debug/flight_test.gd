class_name FlightTest
extends Node
## Handling harness:  Godot --headless --path . -- --flighttest
##
## Three parts, then PASS or FAIL.
##
## 1. HANDLING. The numbers that define each flight model: hands-off drift,
##    how fast it reaches speed, how far it takes to stop, how the turn
##    behaves - and, in flight-sim mode, that it actually flies where the nose
##    points.
##
## 2. SMOOTHNESS. The camera is sampled every rendered frame with the display
##    running at 144 Hz over the 60 Hz physics tick - exactly the conditions
##    that produced the strafe and climb jitter - for every view in both
##    models, on the manoeuvres that used to jitter. Two figures per run:
##      CV     spread of the camera's frame-to-frame speed during steady
##             motion. A perfectly smooth shot is 0; stepping at the physics
##             rate reads around 0.5 or worse.
##      STALL  share of frames in which the camera barely moved while the
##             aircraft was moving - the signature of 60 Hz stepping.
##    One run is repeated with interpolation switched off, as the control.
##
## 3. AUTOPILOT. Return-home has to land on the van; the orbit has to hold its
##    radius with the nose on the target; a first-aid kit dropped over a
##    survivor has to be credited to them.

const DISPLAY_HZ := 144
const MAX_CV := 0.03
const MAX_STALL := 0.03

var _main: Node
var _drone: Drone
var _rig: CameraRig

var _sampling := false
var _samples := PackedFloat32Array()
var _prev := Vector3.ZERO
var _prev_valid := false

var _failures: Array[String] = []


func setup(main: Node) -> void:
	_main = main


func _ready() -> void:
	# After the camera rig in every frame, so each sample is this frame's shot.
	process_priority = 1000
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = DISPLAY_HZ
	_run.call_deferred()


## Speed is measured against the engine's frame delta, not the wall clock.
## The engine delta is the clock interpolation actually runs on, and on a
## real display vsync presents frames at that same regular interval. Headless
## has no vsync, so wall-clock timing picks up the OS scheduler instead: a
## frame that lands one millisecond after the last reads as a speed spike that
## no screen would ever show.
func _process(delta: float) -> void:
	if not _sampling or _rig == null:
		return
	var p := _rig.camera.global_position
	if _prev_valid and delta > 0.0005:
		_samples.append(p.distance_to(_prev) / delta)
	_prev = p
	_prev_valid = true


# ------------------------------------------------------------------ run

func _run() -> void:
	_drone = _main.drone
	_rig = _main.rig
	# Handling is measured on an undamaged airframe; damage is the self-test's
	# job. A stray contact here would change every number that follows it.
	if _drone.damage:
		_drone.damage.enabled = false
	await _wait(1.0)
	print("\n[flight] ===== 1. HANDLING =====")
	await _handling_arcade()
	await _handling_sim()

	print("\n[flight] ===== 2. SMOOTHNESS (display %d Hz, physics %d Hz) ====="
		% [DISPLAY_HZ, Engine.physics_ticks_per_second])
	print("[flight] %-11s %-6s %-22s %6s  %6s  %7s  %6s" %
		["MODEL", "VIEW", "MANOEUVRE", "m/s", "CV", "STALL", "MAX"])
	for model in [Drone.FlightModel.ARCADE, Drone.FlightModel.SIM]:
		for view in [CameraRig.View.CHASE, CameraRig.View.CLOSE, CameraRig.View.FPV]:
			await _smoothness(model, view)
	await _control_without_interpolation()

	print("\n[flight] ===== 3. AUTOPILOT =====")
	await _return_home()
	await _orbit()
	await _supply_drop()

	print("")
	for f in _failures:
		print("[flight]   FAIL  %s" % f)
	print("[flight] RESULT %s  (%d failures)" %
		["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	Engine.max_fps = 0
	get_tree().quit(0 if _failures.is_empty() else 1)


# ------------------------------------------------------------ handling

func _handling_arcade() -> void:
	_place(Drone.FlightModel.ARCADE, Vector3(0.0, 45.0, 90.0))
	await _wait(0.5)
	var mark := _drone.global_position
	await _wait(5.0)
	var drift := _drone.global_position.distance_to(mark)
	_report("arcade  hands-off drift over 5 s", "%.3f m" % drift, drift < 0.02)

	var spool := await _hold_until("pitch_up", 4.0,
		func(): return _drone.ground_speed() > _drone.cruise_speed * 0.9)
	_report("arcade  time to 90% of cruise", "%.2f s" % spool, spool < 1.2)
	await _wait(1.5)
	var cruise := _drone.ground_speed()
	_report("arcade  cruise speed held", "%.1f m/s" % cruise,
		absf(cruise - _drone.cruise_speed) < 0.3)
	var stop_from := _drone.global_position
	_release_all()
	await _wait(2.5)
	var stop := _drone.global_position.distance_to(stop_from)
	_report("arcade  stopping distance from cruise", "%.1f m" % stop, stop < 5.0)
	_report("arcade  at rest after release", "%.2f m/s" % _drone.linear_velocity.length(),
		_drone.linear_velocity.length() < 0.05)

	Input.action_press("roll_right")
	await _wait(2.0)
	var strafe := _drone.ground_speed()
	_release_all()
	_report("arcade  strafe as fast as forward", "%.1f m/s" % strafe,
		strafe > _drone.cruise_speed * 0.95)

	Input.action_press("yaw_right")
	await _wait(2.0)
	var yaw_rate := rad_to_deg(absf(_drone.angular_velocity.y))
	var wander_from := _drone.global_position
	await _wait(1.0)
	var wander := _drone.global_position.distance_to(wander_from)
	_release_all()
	await _wait(1.0)
	_report("arcade  yaw rate", "%.0f deg/s" % yaw_rate, yaw_rate > 90.0)
	_report("arcade  turns on the spot", "%.2f m" % wander, wander < 0.05)
	_report("arcade  yaw stops on release",
		"%.1f deg/s" % rad_to_deg(absf(_drone.angular_velocity.y)),
		absf(_drone.angular_velocity.y) < 0.01)


func _handling_sim() -> void:
	_place(Drone.FlightModel.SIM, Vector3(0.0, 45.0, 90.0))
	await _wait(0.5)
	var mark := _drone.global_position
	await _wait(4.0)
	var drift := _drone.global_position.distance_to(mark)
	_report("sim     hands-off drift over 4 s", "%.3f m" % drift, drift < 0.02)

	var spool := await _hold_until("throttle_up", 6.0,
		func(): return _drone.ground_speed() > _drone.sim_max_speed * 0.9)
	_report("sim     RT to 90% of max speed", "%.2f s" % spool, spool > 1.2 and spool < 3.5)

	# Brake from full speed.
	var from := _drone.global_position
	var speed := _drone.ground_speed()
	_release_all()
	Input.action_press("throttle_down")
	await _wait(2.5)
	_release_all()
	var brake := _drone.global_position.distance_to(from)
	_report("sim     LT braking distance from %.0f m/s" % speed, "%.1f m" % brake,
		brake < 16.0 and _drone.linear_velocity.length() < 0.3)

	# Coast: release the trigger at speed and it should glide, not stop dead.
	await _hold_until("throttle_up", 4.0, func(): return _drone.ground_speed() > 12.0)
	_release_all()
	await _wait(1.0)
	var coasting := _drone.ground_speed()
	_report("sim     coasts after RT release", "%.1f m/s after 1 s" % coasting,
		coasting > 8.0)
	Input.action_press("throttle_down")
	await _wait(2.0)
	_release_all()

	# Nose up, then drive: it must climb along the nose, not fly flat.
	Input.action_press("pitch_up")
	await _wait(0.5)
	Input.action_release("pitch_up")
	var start_y := _drone.global_position.y
	Input.action_press("throttle_up")
	await _wait(2.5)
	var climb := _drone.global_position.y - start_y
	_release_all()
	_report("sim     flies where the nose points (nose up)", "%+.1f m climbed" % climb,
		climb > 4.0)

	# Stick up must be nose up - the not-inverted requirement.
	_report("sim     stick up is nose up", "%.0f deg" % rad_to_deg(_drone.view_pitch()),
		_drone.view_pitch() > 0.1)
	Input.action_press("pitch_down")
	await _wait(0.5)
	_release_all()
	Input.action_press("throttle_down")
	await _wait(2.0)
	_release_all()


# ---------------------------------------------------------- smoothness

func _smoothness(model: int, view: int) -> void:
	var view_name: String = CameraRig.VIEW_NAMES[view].split(" ")[0]
	var model_name: String = Drone.FLIGHT_MODEL_NAMES[model]

	if model == Drone.FlightModel.ARCADE:
		var manoeuvres := [
			["strafe right", ["roll_right"], 2.4, 1.2],
			["climb", ["throttle_up"], 2.0, 0.9],
			["reverse", ["pitch_down"], 2.4, 1.2],
			["forward + turn", ["pitch_up", "yaw_right"], 2.4, 1.2],
		]
		for m in manoeuvres:
			await _smooth_run(model, view, model_name, view_name, m)
	else:
		var manoeuvres := [
			["cruise", ["throttle_up"], 3.8, 1.2],
			["cruise + turn", ["throttle_up", "roll_right"], 3.8, 1.2],
			["climb (right stick)", ["gimbal_up"], 2.0, 0.9],
			["slide (right stick)", ["yaw_right"], 2.0, 0.9],
		]
		for m in manoeuvres:
			await _smooth_run(model, view, model_name, view_name, m)


func _smooth_run(model: int, view: int, model_name: String, view_name: String,
		m: Array, label_suffix := "", enforce := true) -> void:
	_place(model, Vector3(0.0, 45.0, 90.0))
	_rig.set_view(view)
	_rig._initialised = false
	await _wait(0.6)
	for action in m[1]:
		Input.action_press(action)
	await _wait(float(m[2]) - float(m[3]))
	var st := await _measure(float(m[3]))
	_release_all()
	var ok: bool = st.cv < MAX_CV and st.stall < MAX_STALL
	print("[flight] %-11s %-6s %-22s %6.1f  %6.3f  %6.1f%%  %6.1f  %s" % [model_name,
		view_name, str(m[0]) + label_suffix, st.mean, st.cv, st.stall * 100.0,
		st.max, ("ok" if ok else "JITTER") if enforce else "(control)"])
	if enforce and not ok:
		_failures.append("%s %s %s: CV %.3f, stall %.1f%%" % [model_name, view_name,
			m[0], st.cv, st.stall * 100.0])


## The same measurement with interpolation off. This is the control: it shows
## the stepping the fix removes, so the numbers above mean something.
func _control_without_interpolation() -> void:
	get_tree().physics_interpolation = false
	await _smooth_run(Drone.FlightModel.ARCADE, CameraRig.View.CHASE, "ARCADE", "CHASE",
		["strafe right", ["roll_right"], 2.4, 1.2], "  [interp OFF]", false)
	get_tree().physics_interpolation = true
	await _wait(0.2)


func _measure(seconds: float) -> Dictionary:
	_samples.clear()
	_prev_valid = false
	_sampling = true
	await _wait(seconds)
	_sampling = false
	var n := _samples.size()
	if n < 4:
		return {"mean": 0.0, "cv": 1.0, "stall": 1.0, "max": 0.0}
	var mean := 0.0
	for v in _samples:
		mean += v
	mean /= float(n)
	var variance := 0.0
	var stalls := 0
	for v in _samples:
		variance += (v - mean) * (v - mean)
		if v < mean * 0.25:
			stalls += 1
	var fastest := 0.0
	for v in _samples:
		fastest = maxf(fastest, v)
	return {"mean": mean, "cv": sqrt(variance / float(n)) / maxf(mean, 0.001),
		"stall": float(stalls) / float(n), "max": fastest}


# ------------------------------------------------------------ autopilot

func _return_home() -> void:
	_place(Drone.FlightModel.ARCADE, Vector3(46.0, 8.0, 38.0))
	await _wait(0.5)
	var from := _drone.distance_to_home()
	_drone.payload.remaining = 0
	_drone.autopilot.engage_return_home()
	var t0 := Time.get_ticks_msec()
	while _drone.autopilot.active and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().physics_frame
	var seconds := float(Time.get_ticks_msec() - t0) / 1000.0
	var miss := _drone.global_position.distance_to(Sim.home_position)
	_report("return home from %.0f m lands on the deck" % from,
		"%.2f m off, %.1f s" % [miss, seconds],
		not _drone.autopilot.active and miss < 0.6)
	_report("landing on the van reloads the kits",
		"%d / %d" % [_drone.payload.remaining, _drone.payload.capacity],
		_drone.payload.remaining == _drone.payload.capacity)
	var yaw_err := rad_to_deg(absf(wrapf(Autopilot._yaw_of(_drone.global_basis)
		- Autopilot._yaw_of(_drone.start_transform.basis), -PI, PI)))
	_report("lands facing the way it launched", "%.1f deg" % yaw_err, yaw_err < 6.0)


func _orbit() -> void:
	var target := _victim("ContainerStack")
	if target == null:
		_report("orbit target present", "missing", false)
		return
	var c := target.global_position
	_place(Drone.FlightModel.ARCADE, Vector3(c.x + 14.0, c.y + 9.0, c.z))
	await _wait(0.5)
	_drone.autopilot.engage_orbit(target)
	await _wait(3.0)              # settle onto the ring
	var radii := PackedFloat32Array()
	var worst_aim := 0.0
	var start_angle := atan2(_drone.global_position.z - c.z, _drone.global_position.x - c.x)
	for i in 240:                 # four seconds of samples
		await get_tree().physics_frame
		var flat := Vector2(_drone.global_position.x - c.x, _drone.global_position.z - c.z)
		radii.append(flat.length())
		var aim := wrapf(Autopilot._yaw_of(_drone.global_basis)
			- atan2(flat.x, flat.y), -PI, PI)
		worst_aim = maxf(worst_aim, absf(rad_to_deg(aim)))
	var travelled := wrapf(atan2(_drone.global_position.z - c.z,
		_drone.global_position.x - c.x) - start_angle, -PI, PI)
	var mean := 0.0
	for r in radii:
		mean += r
	mean /= radii.size()
	var spread := 0.0
	for r in radii:
		spread = maxf(spread, absf(r - mean))
	_drone.autopilot.cancel("")
	_report("orbit holds its radius", "%.1f m +/- %.2f" % [mean, spread], spread < 0.8)
	_report("orbit keeps the nose on the target", "worst %.1f deg" % worst_aim,
		worst_aim < 12.0)
	_report("orbit actually goes round", "%.0f deg in 4 s" % rad_to_deg(absf(travelled)),
		absf(travelled) > 0.6)


func _supply_drop() -> void:
	var target := _victim("PipeRack")
	if target == null:
		_report("supply target present", "missing", false)
		return
	target.supplied = false
	var c := target.global_position
	_place(Drone.FlightModel.ARCADE, Vector3(c.x, c.y + 7.0, c.z))
	_drone.payload.reload()
	await _wait(0.5)
	_drone.payload.drop()
	var t0 := Time.get_ticks_msec()
	while not target.supplied and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().physics_frame
	_report("first-aid kit credited to the survivor below",
		"%.1f s" % (float(Time.get_ticks_msec() - t0) / 1000.0), target.supplied)


# -------------------------------------------------------------- helpers

func _place(model: int, relative: Vector3) -> void:
	_release_all()
	if _drone.autopilot:
		_drone.autopilot.cancel("")
	_drone.set_flight_model(model)
	var ground: float = _main.world.terrain_height(relative.x, relative.z)
	_drone.global_transform = Transform3D(Basis(), Vector3(relative.x,
		ground + relative.y, relative.z))
	_drone.linear_velocity = Vector3.ZERO
	_drone.angular_velocity = Vector3.ZERO
	_drone._yaw_rate = 0.0
	_drone._sim_speed = 0.0
	_drone._nose_pitch = 0.0
	_drone._nose_prev = 0.0
	_drone.reset_physics_interpolation()


func _hold_until(action: String, limit: float, done: Callable) -> float:
	Input.action_press(action)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(limit * 1000.0):
		await get_tree().physics_frame
		if done.call():
			return float(Time.get_ticks_msec() - t0) / 1000.0
	return limit


func _release_all() -> void:
	for a in ["pitch_up", "pitch_down", "roll_left", "roll_right", "yaw_left",
			"yaw_right", "throttle_up", "throttle_down", "gimbal_up", "gimbal_down"]:
		Input.action_release(a)


func _victim(node_name: String) -> Victim:
	for node in get_tree().get_nodes_in_group("detectable"):
		if node is Victim and node.name == node_name:
			return node
	return null


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _report(what: String, value: String, ok: bool) -> void:
	print("[flight] %-46s %-24s %s" % [what, value, "ok" if ok else "FAIL"])
	if not ok:
		_failures.append("%s (%s)" % [what, value])
