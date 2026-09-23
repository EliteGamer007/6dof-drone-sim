class_name Explosion
extends Node3D
## A one-shot detonation.
##
## The hard requirement is that it reads on every sensor, not just the daylight
## camera. That falls out of building it from the same pieces the rest of the
## site uses rather than from a bespoke particle effect:
##
##   EO      fireball, smoke column, shockwave ring, blast light
##   THERMAL a real heat source registered with Hazards, cooling as it burns
##   NV      the flash saturates the intensifier exactly as a bright source should
##   GAS     the lingering fire injects CO, so the overlay paints the plume
##
## Everything is spawned, played once, and freed. Nothing here persists except
## the short-lived fire it leaves behind.

const FLASH_PEAK := 34.0
const FLASH_TIME := 0.10          ## seconds to full brightness
const FLASH_DECAY := 0.85         ## seconds back to nothing
const RING_LIFETIME := 0.55
const RING_RADIUS := 13.0
const BURN_SECONDS := 14.0        ## how long the fire it starts keeps burning

@export var power := 1.0          ## scales radius, light and heat

var _age := 0.0
var _light: OmniLight3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _fire: FireSource
var _heat: Dictionary = {}


func _ready() -> void:
	_build_light()
	_build_fireball()
	_build_smoke()
	_build_debris()
	_build_ring()
	_start_fire()

	# The heat spike the thermal channel sees. Registered directly rather than
	# left to the fire, because the fireball is far hotter for the first second
	# than the burn that follows it.
	Hazards.register_heat_capsule(self, Vector3.ZERO, Vector3(0.0, 1.6, 0.0),
		3.4 * power, 900.0, true, 2.2, Hazards.HeatKind.FIRE)
	for h in Hazards.heat_sources:
		if h.node == self:
			_heat = h
			break

	var drone := Sim.drone as Drone
	if drone and drone.damage:
		drone.damage.blast(global_position, power)

	Sfx.play("impact", 4.0, randf_range(0.42, 0.52), 0.0)
	Sfx.play("fire_crackle", -2.0, 0.8, 0.05)
	Sim.camera_shake.emit(1.0 * power)
	Sim.toast.emit("DETONATION  %s" % Sim.format_latlon(global_position),
		Sim.Severity.WARNING)


func _exit_tree() -> void:
	Hazards.unregister(self)


func _process(delta: float) -> void:
	_age += delta

	# Blast light: a fast rise and a slower fall, which is what a fireball
	# actually does. A symmetric flash reads as a camera effect.
	if _light:
		var energy := 0.0
		if _age < FLASH_TIME:
			energy = FLASH_PEAK * (_age / FLASH_TIME)
		else:
			var t := clampf((_age - FLASH_TIME) / FLASH_DECAY, 0.0, 1.0)
			energy = FLASH_PEAK * (1.0 - t) * (1.0 - t)
		_light.light_energy = energy * power
		if _age > FLASH_TIME + FLASH_DECAY:
			_light.queue_free()
			_light = null

	# Expanding shockwave ring, thinning as it goes.
	if _ring:
		var t := clampf(_age / RING_LIFETIME, 0.0, 1.0)
		var r := RING_RADIUS * power * sqrt(t)
		_ring.scale = Vector3(r, 1.0, r)
		_ring_mat.albedo_color.a = (1.0 - t) * 0.5
		if t >= 1.0:
			_ring.queue_free()
			_ring = null

	# The heat source cools from fireball temperature down to the burn the
	# fire will carry on at, instead of snapping off.
	if not _heat.is_empty():
		var t := clampf(_age / 3.5, 0.0, 1.0)
		_heat.temp = lerpf(900.0, 260.0, t)

	if _age > BURN_SECONDS:
		queue_free()


# ---------------------------------------------------------------- pieces

func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.name = "BlastLight"
	_light.light_color = Color(1.0, 0.72, 0.34)
	_light.light_energy = 0.0
	_light.omni_range = 34.0 * power
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 1.4, 0.0)
	add_child(_light)


func _build_fireball() -> void:
	var ramp := Vfx.ramp([
		Color(1.0, 0.98, 0.86, 1.0),
		Color(1.0, 0.68, 0.18, 0.95),
		Color(0.72, 0.20, 0.04, 0.6),
		Color(0.10, 0.09, 0.09, 0.0),
	], [0.0, 0.18, 0.5, 1.0])

	var p := GPUParticles3D.new()
	p.name = "Fireball"
	p.amount = 110
	p.lifetime = 1.3
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-16, -6, -16), Vector3(32, 28, 32))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.7 * power
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 180.0
	pm.initial_velocity_min = 5.0 * power
	pm.initial_velocity_max = 15.0 * power
	pm.gravity = Vector3(0.0, 2.2, 0.0)       # fire rises
	pm.damping_min = 5.0
	pm.damping_max = 11.0
	pm.scale_min = 1.1 * power
	pm.scale_max = 3.2 * power
	pm.color_ramp = ramp
	p.process_material = pm
	p.draw_pass_1 = Vfx.quad(Vector2.ONE * 2.2)
	p.material_override = Vfx.billboard_material(Vfx.soft_circle(64, 1.6), true)
	p.position = Vector3(0.0, 0.9, 0.0)
	add_child(p)
	p.emitting = true


func _build_smoke() -> void:
	var ramp := Vfx.ramp([
		Color(0.26, 0.24, 0.23, 0.0),
		Color(0.20, 0.19, 0.18, 0.72),
		Color(0.34, 0.33, 0.32, 0.0),
	], [0.0, 0.2, 1.0])

	var p := GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = 64
	p.lifetime = 6.0
	p.one_shot = true
	p.explosiveness = 0.7
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-20, -4, -20), Vector3(40, 46, 40))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 1.1 * power
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 46.0
	pm.initial_velocity_min = 3.5
	pm.initial_velocity_max = 9.0
	pm.gravity = Hazards.current_wind() * 0.35 + Vector3(0.0, 1.1, 0.0)
	pm.damping_min = 0.8
	pm.damping_max = 2.0
	pm.scale_min = 2.4 * power
	pm.scale_max = 6.5 * power
	pm.color_ramp = ramp
	p.process_material = pm
	p.draw_pass_1 = Vfx.quad(Vector2.ONE * 3.0)
	p.material_override = Vfx.billboard_material(Vfx.soft_circle(64, 2.4), false)
	p.position = Vector3(0.0, 1.3, 0.0)
	add_child(p)
	p.emitting = true


## Sparks and fragments thrown clear. Short-lived and additive, so they read
## as embers rather than as geometry.
func _build_debris() -> void:
	var ramp := Vfx.ramp([
		Color(1.0, 0.92, 0.6, 1.0),
		Color(1.0, 0.48, 0.10, 0.85),
		Color(0.5, 0.12, 0.02, 0.0),
	], [0.0, 0.45, 1.0])

	var p := GPUParticles3D.new()
	p.name = "Debris"
	p.amount = 70
	p.lifetime = 2.2
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-26, -8, -26), Vector3(52, 34, 52))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.4
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 96.0
	pm.initial_velocity_min = 11.0 * power
	pm.initial_velocity_max = 26.0 * power
	pm.gravity = Vector3(0.0, -13.0, 0.0)     # fragments fall, flame does not
	pm.damping_min = 0.3
	pm.damping_max = 1.2
	pm.scale_min = 0.16
	pm.scale_max = 0.42
	pm.color_ramp = ramp
	p.process_material = pm
	p.draw_pass_1 = Vfx.quad(Vector2.ONE * 0.9)
	p.material_override = Vfx.billboard_material(Vfx.soft_circle(32, 1.2), true)
	p.position = Vector3(0.0, 0.8, 0.0)
	add_child(p)
	p.emitting = true


func _build_ring() -> void:
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.albedo_color = Color(1.0, 0.86, 0.62, 0.5)
	_ring_mat.albedo_texture = Vfx.ring_texture(256, 0.80, 0.98)
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED

	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE * 2.0
	quad.orientation = PlaneMesh.FACE_Y

	_ring = MeshInstance3D.new()
	_ring.name = "Shockwave"
	_ring.mesh = quad
	_ring.material_override = _ring_mat
	_ring.position = Vector3(0.0, 0.35, 0.0)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.scale = Vector3(0.01, 1.0, 0.01)
	add_child(_ring)


## What the blast leaves behind: a real fire, which is what puts this on the
## gas overlay and keeps it on the thermal image after the flash has gone.
func _start_fire() -> void:
	_fire = FireSource.new()
	_fire.name = "BlastFire"
	_fire.intensity = 0.8 * power
	_fire.label = "Secondary fire from detonation"
	_fire.auto_log = false        # the toast already reported it
	add_child(_fire)
