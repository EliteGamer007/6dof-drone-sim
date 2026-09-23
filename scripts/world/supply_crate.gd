class_name SupplyCrate
extends RigidBody3D
## A first-aid kit under a drogue parachute.
##
## Falls, deploys its canopy, drifts with the wind, and on touchdown checks
## whether it has landed close enough to a survivor to count. If it has, the
## survivor is marked as supplied and the delivery is logged - that is what the
## "deliver first-aid kits" objective counts.

const DELIVERY_RADIUS := 6.0
const DEPLOY_DELAY := 0.35          ## seconds of free fall before the canopy opens
const CANOPY_DAMP := 2.6            ## linear damping once open: ~3.5 m/s descent

var delivered_to: Victim = null

var _age := 0.0
var _landed := false
var _canopy: MeshInstance3D
var _lines: MeshInstance3D
var _canopy_open := 0.0
var _smoke: GPUParticles3D


func _ready() -> void:
	mass = 1.4
	gravity_scale = 1.0
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 2
	angular_damp = 3.0

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.36, 0.24, 0.36)
	col.shape = shape
	add_child(col)

	_build_crate()
	_build_canopy()
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_age += delta
	if _landed:
		# Canopy collapses once the load is on the ground.
		_canopy_open = move_toward(_canopy_open, 0.0, delta * 1.6)
	elif _age > DEPLOY_DELAY:
		_canopy_open = move_toward(_canopy_open, 1.0, delta * 2.5)
		linear_damp = lerpf(0.0, CANOPY_DAMP, _canopy_open)
		# Drift with the wind under the canopy.
		apply_central_force(Hazards.current_wind() * 0.35 * _canopy_open * mass)
		# Keep the load hanging level under the canopy.
		angular_velocity = angular_velocity.lerp(Vector3.ZERO, clampf(delta * 4.0, 0.0, 1.0))

	var s := maxf(_canopy_open, 0.02)
	if _canopy:
		_canopy.scale = Vector3(s, maxf(s * 0.8, 0.02), s)
		_canopy.visible = _canopy_open > 0.03
	if _lines:
		_lines.visible = _canopy_open > 0.3


func _on_body_entered(_body: Node) -> void:
	if _landed or _age < 0.2:
		return
	if linear_velocity.length() > 9.0:
		return                           # bounced off something on the way down
	_landed = true
	linear_damp = 1.0
	_mark_landing()
	_credit_nearest_survivor()


func _credit_nearest_survivor() -> void:
	var best: Victim = null
	var best_d := DELIVERY_RADIUS
	for node in get_tree().get_nodes_in_group("detectable"):
		var v := node as Victim
		if v == null or v.supplied:
			continue
		var d := v.global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = v
	if best == null:
		Sim.toast.emit("KIT DOWN  -  NO SURVIVOR WITHIN %.0f m" % DELIVERY_RADIUS,
			Sim.Severity.CAUTION)
		return

	delivered_to = best
	best.supplied = true
	Sim.log_finding(Sim.FindingKind.SUPPLY,
		"First-aid kit delivered - %s (%.1f m)" % [best.label, best_d],
		Sim.Severity.INFO, global_position, "supply_%d" % best.get_instance_id(),
		{"detail": "Kit landed within reach of the survivor.", "action": ""})
	Sfx.play("mission_complete", -9.0, 1.3)


# ---------------------------------------------------------------- visuals

func _build_crate() -> void:
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.36, 0.24, 0.36)
	box.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.93, 0.93, 0.90)
	mat.roughness = 0.6
	box.material_override = mat
	add_child(box)

	# Red cross on top, so it reads as medical from the air.
	var cross_mat := StandardMaterial3D.new()
	cross_mat.albedo_color = Color(0.85, 0.08, 0.08)
	cross_mat.emission_enabled = true
	cross_mat.emission = Color(0.85, 0.08, 0.08)
	cross_mat.emission_energy_multiplier = 0.4
	for size in [Vector3(0.24, 0.01, 0.07), Vector3(0.07, 0.01, 0.24)]:
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		bar.mesh = bm
		bar.material_override = cross_mat
		bar.position = Vector3(0.0, 0.126, 0.0)
		add_child(bar)


func _build_canopy() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.46, 0.06)
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var dome := SphereMesh.new()
	dome.radius = 0.75
	dome.height = 0.75
	dome.is_hemisphere = true
	dome.radial_segments = 16
	dome.rings = 5

	_canopy = MeshInstance3D.new()
	_canopy.name = "Canopy"
	_canopy.mesh = dome
	_canopy.material_override = mat
	_canopy.position = Vector3(0.0, 1.35, 0.0)
	_canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_canopy.visible = false
	add_child(_canopy)

	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.9, 0.9, 0.85)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.7
	cone.bottom_radius = 0.02
	cone.height = 1.2
	cone.radial_segments = 8
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line_mat.albedo_color.a = 0.35
	line_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_lines = MeshInstance3D.new()
	_lines.mesh = cone
	_lines.material_override = line_mat
	_lines.position = Vector3(0.0, 0.72, 0.0)
	_lines.visible = false
	add_child(_lines)


## Green marker smoke on touchdown - what a real drop uses so the ground team
## can find the kit.
func _mark_landing() -> void:
	var ramp := Vfx.ramp([
		Color(0.35, 0.95, 0.45, 0.0),
		Color(0.30, 0.85, 0.40, 0.55),
		Color(0.40, 0.70, 0.45, 0.0),
	], [0.0, 0.25, 1.0])
	_smoke = GPUParticles3D.new()
	_smoke.amount = 40
	_smoke.lifetime = 5.0
	_smoke.local_coords = false
	_smoke.visibility_aabb = AABB(Vector3(-8, -2, -8), Vector3(16, 20, 16))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 20.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 1.8
	pm.gravity = Hazards.current_wind() * 0.3 + Vector3(0.0, 0.35, 0.0)
	pm.scale_min = 0.6
	pm.scale_max = 1.8
	pm.color_ramp = ramp
	_smoke.process_material = pm
	_smoke.draw_pass_1 = Vfx.quad(Vector2.ONE * 1.2)
	_smoke.material_override = Vfx.billboard_material(Vfx.soft_circle(48, 2.2), false)
	_smoke.position = Vector3(0.0, 0.2, 0.0)
	add_child(_smoke)
	_smoke.emitting = true
