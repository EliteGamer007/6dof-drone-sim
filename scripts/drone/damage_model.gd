class_name DamageModel
extends Node
## What happens when the aircraft hits something.
##
## A small quad is fragile: props shatter on contact, arms crack, and a motor
## that has taken a strike runs hot and weak. So damage here costs the pilot
## something they can feel rather than a number on a panel:
##
##   integrity   0-100 %. Impacts, blast overpressure and flying through fire
##               all take it down. At zero the motors cut and it falls.
##   motors      each one degrades separately. Lost thrust caps top speed and
##               climb rate, and an uneven set makes the airframe wobble.
##
## Landing back on the van - by hand or by return-home - repairs it, the way a
## field team would swap props and a battery between sorties.

signal integrity_changed(integrity: float)
signal destroyed

## Below this the impact is a bump. A quad's props survive touching a wall at
## walking pace; they do not survive much more.
const IMPACT_THRESHOLD := 1.6        ## m/s
const IMPACT_SCALE := 5.5            ## integrity lost per (m/s over threshold)^1.35
const MOTOR_STRIKE_SPEED := 3.0      ## m/s - above this a prop strike costs a motor
const FIRE_DAMAGE_RATE := 14.0       ## integrity per second inside a flame column
const BLAST_RADIUS := 16.0           ## metres within which a detonation hurts
const RESPAWN_DELAY := 3.0

var integrity := 100.0
var destroyed_at := -1.0
## Off for the automated sensor sweep, which parks the aircraft next to fires
## and inside plumes on purpose.
var enabled := true

var _drone: Drone
var _warned_half := false
var _warned_critical := false
var _smoke: GPUParticles3D
var _fire_timer := 0.0
var _last_heat_warning := -INF


func _ready() -> void:
	_drone = get_parent() as Drone
	if _drone:
		_drone.damage = self
	_build_smoke.call_deferred()


func _physics_process(delta: float) -> void:
	if _drone == null:
		return
	if is_destroyed():
		if Sim.mission_time - destroyed_at > RESPAWN_DELAY:
			_drone.reset_to_start()
		return
	_fire_exposure(delta)
	if _smoke:
		_smoke.emitting = integrity < 45.0
		_smoke.amount_ratio = clampf((45.0 - integrity) / 45.0, 0.15, 1.0)


func is_destroyed() -> bool:
	return destroyed_at >= 0.0


## Thrust available, 0-1. The flight model scales top speed and climb by it.
func thrust_factor() -> float:
	var total := 0.0
	for h in _drone.motor_health:
		total += h
	return clampf(total / 4.0, 0.0, 1.0)


## How uneven the motors are, 0-1. Drives the airframe wobble.
func imbalance() -> float:
	var lo := 1.0
	var hi := 0.0
	for h in _drone.motor_health:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return clampf(hi - lo, 0.0, 1.0)


## A collision. `speed` is how fast the aircraft was travelling into it.
func impact(speed: float) -> void:
	if not enabled or is_destroyed() or speed < IMPACT_THRESHOLD:
		return
	var loss := pow(speed - IMPACT_THRESHOLD, 1.35) * IMPACT_SCALE
	if speed > MOTOR_STRIKE_SPEED:
		var motor := randi() % 4
		_drone.motor_health[motor] = maxf(
			_drone.motor_health[motor] - 0.12 - speed * 0.035, 0.2)
		Sim.alarm_raised.emit(Sim.Severity.WARNING,
			"PROP STRIKE - MOTOR %d AT %d%%" % [motor + 1,
				int(_drone.motor_health[motor] * 100.0)])
	_apply(loss, "IMPACT %.1f m/s" % speed)


## Blast overpressure from a detonation, falling off with distance.
func blast(origin: Vector3, power: float) -> void:
	if not enabled or is_destroyed():
		return
	var d := _drone.global_position.distance_to(origin)
	var radius := BLAST_RADIUS * power
	if d > radius:
		return
	var t := 1.0 - d / radius
	# Knocked away from the blast, harder the closer it was.
	var push := (_drone.global_position - origin).normalized() + Vector3.UP * 0.4
	_drone.linear_velocity += push.normalized() * t * 14.0 * power
	for i in 4:
		_drone.motor_health[i] = maxf(_drone.motor_health[i] - t * 0.35, 0.2)
	_apply(t * t * 95.0 * power, "CAUGHT IN THE BLAST")


func repair() -> void:
	integrity = 100.0
	destroyed_at = -1.0
	_warned_half = false
	_warned_critical = false
	for i in 4:
		_drone.motor_health[i] = 1.0
	integrity_changed.emit(integrity)


func _apply(loss: float, cause: String) -> void:
	integrity = maxf(integrity - loss, 0.0)
	integrity_changed.emit(integrity)
	if integrity <= 0.0:
		_destroy(cause)
		return
	if integrity < 25.0 and not _warned_critical:
		_warned_critical = true
		Sim.alarm_raised.emit(Sim.Severity.CRITICAL,
			"AIRFRAME CRITICAL %d%% - RETURN TO THE VAN" % int(integrity))
	elif integrity < 50.0 and not _warned_half:
		_warned_half = true
		Sim.alarm_raised.emit(Sim.Severity.WARNING,
			"AIRFRAME DAMAGED %d%%" % int(integrity))


func _destroy(cause: String) -> void:
	destroyed_at = Sim.mission_time
	for i in 4:
		_drone.motor_health[i] = 0.0
	if _drone.autopilot:
		_drone.autopilot.cancel("")
	# Motors cut: it falls like the unpowered airframe it now is.
	_drone.gravity_scale = 1.0
	_drone.axis_lock_angular_x = false
	_drone.axis_lock_angular_z = false
	_drone.angular_velocity += Vector3(randf_range(-4, 4), randf_range(-2, 2),
		randf_range(-4, 4))
	Sim.alarm_raised.emit(Sim.Severity.CRITICAL, "AIRCRAFT LOST - %s" % cause)
	Sim.toast.emit("AIRCRAFT LOST  -  SPARE LAUNCHING FROM THE VAN IN %d s"
		% int(RESPAWN_DELAY), Sim.Severity.CRITICAL)
	Sfx.play("impact", 2.0, 0.55)
	destroyed.emit()


## Flying through a flame column cooks the props and the electronics. Checked
## against the same heat field the thermal camera renders, so if it glows
## white-hot on the display it is hurting the aircraft.
func _fire_exposure(delta: float) -> void:
	if not enabled:
		return
	_fire_timer += delta
	if _fire_timer < 0.2:
		return
	var step := _fire_timer
	_fire_timer = 0.0
	var temp := Hazards.sample_temperature(_drone.global_position)
	if temp > 120.0:
		var severity := clampf((temp - 120.0) / 300.0, 0.0, 1.0)
		_apply(FIRE_DAMAGE_RATE * severity * step, "HEAT DAMAGE")
		# One warning every few seconds, not one per sample - it used to fire on
		# a coin toss five times a second and flood the toast list.
		if Sim.mission_time - _last_heat_warning > 3.0:
			_last_heat_warning = Sim.mission_time
			Sim.toast.emit("TOO HOT - %d C AT THE AIRFRAME" % int(temp),
				Sim.Severity.WARNING)


## Grey smoke from a damaged airframe, so the state of the aircraft is visible
## from outside it - including to anyone watching the chase view.
func _build_smoke() -> void:
	if _drone == null:
		return
	var ramp := Vfx.ramp([
		Color(0.22, 0.21, 0.20, 0.0),
		Color(0.20, 0.19, 0.18, 0.5),
		Color(0.30, 0.29, 0.28, 0.0),
	], [0.0, 0.2, 1.0])
	_smoke = GPUParticles3D.new()
	_smoke.name = "DamageSmoke"
	_smoke.amount = 36
	_smoke.lifetime = 1.8
	_smoke.local_coords = false
	_smoke.emitting = false
	_smoke.visibility_aabb = AABB(Vector3(-6, -3, -6), Vector3(12, 10, 12))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.3
	pm.initial_velocity_max = 1.0
	pm.gravity = Vector3(0.0, 0.6, 0.0)
	pm.scale_min = 0.25
	pm.scale_max = 0.7
	pm.color_ramp = ramp
	_smoke.process_material = pm
	_smoke.draw_pass_1 = Vfx.quad(Vector2.ONE * 0.6)
	_smoke.material_override = Vfx.billboard_material(Vfx.soft_circle(48, 2.2), false)
	_drone.add_child(_smoke)
