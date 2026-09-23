@tool
class_name CasualtyPoint
extends SitePiece
## Where the people you find are taken. A canopy, three triage bays painted in
## the standard order - immediate, delayed, minor - and a lit square so it reads
## as somewhere staffed rather than an abandoned tent.
##
## The bays are laid out in front of the canopy rather than under it: triage
## works in the open, and from the air a stretcher under a roof is a stretcher
## nobody can see.

const TRIAGE := [Color(0.85, 0.12, 0.12), Color(0.95, 0.75, 0.12), Color(0.20, 0.72, 0.30)]


func _build() -> void:
	var g := ground(0.0, 0.0)
	var canvas := StandardMaterial3D.new()
	canvas.albedo_color = Color(0.88, 0.86, 0.78)
	canvas.roughness = 0.95
	canvas.cull_mode = BaseMaterial3D.CULL_DISABLED
	var frame := StandardMaterial3D.new()
	frame.albedo_color = Color(0.55, 0.57, 0.60)
	frame.metallic = 0.6
	frame.roughness = 0.4

	# Pitched canopy on a frame with waist rails, so it is legible from above.
	for pitch in [-1.0, 1.0]:
		slab(Vector3(6.2, 0.09, 3.3), Vector3(0.0, g + 2.8, 1.55 * pitch),
			Vector3(7.0 * pitch, 0.0, 0.0), canvas)
	for leg in [Vector3(-2.9, 0.0, -2.9), Vector3(2.9, 0.0, -2.9),
			Vector3(-2.9, 0.0, 2.9), Vector3(2.9, 0.0, 2.9)]:
		slab(Vector3(0.12, 2.78, 0.12), leg + Vector3(0.0, g + 1.39, 0.0), Vector3.ZERO, frame)
	for rail in [-2.9, 2.9]:
		box(Vector3(0.07, 0.07, 5.8), Vector3(rail, g + 1.55, 0.0), frame)

	for i in TRIAGE.size():
		var mat := StandardMaterial3D.new()
		mat.albedo_color = TRIAGE[i]
		mat.roughness = 0.85
		var x := -2.4 + float(i) * 2.4
		slab(Vector3(0.78, 0.09, 2.10), Vector3(x, g + 0.46, 5.0), Vector3.ZERO, mat)
		for end in [-0.9, 0.9]:
			box(Vector3(0.70, 0.42, 0.06), Vector3(x, g + 0.21, 5.0 + end), frame)
		var paint := mat.duplicate() as StandardMaterial3D
		paint.emission_enabled = true
		paint.emission = TRIAGE[i]
		paint.emission_energy_multiplier = 0.5
		box(Vector3(2.10, 0.03, 0.14), Vector3(x, g + 0.02, 3.8), paint)

	var glow := SpotLight3D.new()
	glow.position = Vector3(0.0, g + 2.55, 0.0)
	glow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	glow.light_color = Color(1.0, 0.96, 0.88)
	glow.light_energy = 5.0
	glow.spot_range = 12.0
	glow.spot_angle = 58.0
	glow.shadow_enabled = false
	add_generated(BuildKit.night_light(glow))

	if not is_runtime():
		return
	var sign := Detectable.new()
	sign.kind = Sim.FindingKind.MARKER
	sign.label = "Casualty collection point"
	sign.detail = ("Triage and ambulance loading. Every survivor you tag is extracted "
		+ "to here, so the access route between this point and the rubble is the one "
		+ "that has to stay open.")
	sign.recommended_action = "Keep the marked route clear for stretcher parties."
	sign.severity = Sim.Severity.INFO
	sign.detection_radius = 3.2
	sign.max_detect_range = 95.0
	sign.position = Vector3(0.0, g + 2.9, 0.0)
	add_generated(sign)
