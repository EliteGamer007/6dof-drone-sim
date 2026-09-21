class_name GasSource
extends Detectable
## A leaking vessel or ruptured line.
##
## Registers a Gaussian plume with the hazard field, then gives it a physical
## presence: drifting particles, a ground danger ring, and a spatialised hiss
## the pilot can fly back to. In VR the hiss alone usually finds the leak
## before the sensor does, which is exactly how it works in the field.

@export_enum("CO", "H2S", "NO2", "LEL", "O2") var gas: int = 3
@export var strength := 260.0          ## concentration at the source, in channel units
@export var plume_radius := 2.6        ## metres, core width
@export var plume_length := 24.0       ## metres of downwind reach
@export var plume_spread := 1.8        ## how much the cone widens downwind
@export var visible_vapour := true     ## some of these gases are invisible in EO
@export var hiss_volume_db := -16.0

var _particles: GPUParticles3D
var _ring: MeshInstance3D
var _audio: AudioStreamPlayer3D


func _ready() -> void:
	kind = Sim.FindingKind.GAS_LEAK
	if label == "Contact":
		label = "%s leak" % Hazards.GAS_LONG_NAMES[gas]
	if detail == "":
		detail = _default_detail()
	if recommended_action == "":
		recommended_action = _default_action()
	severity = Sim.Severity.WARNING if gas != Hazards.Gas.CO else Sim.Severity.CAUTION
	detection_radius = maxf(plume_radius * 0.6, 0.8)
	thermal_contrast = 0.35 if gas == Hazards.Gas.LEL else 0.1
	super._ready()

	Hazards.register_plume(self, gas, strength, plume_radius, plume_length, plume_spread)
	_build_visuals()
	_build_audio()


func _exit_tree() -> void:
	Hazards.unregister(self)


func _process(_delta: float) -> void:
	if _particles == null:
		return
	# Drift the vapour with the live wind so the picture always agrees with
	# the sensor model.
	var wind := Hazards.current_wind()
	var pm := _particles.process_material as ParticleProcessMaterial
	pm.gravity = Vector3(wind.x * 0.42, 0.45, wind.z * 0.42)
	if _ring:
		var pulse := 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.0035)
		var mat := _ring.material_override as StandardMaterial3D
		mat.albedo_color.a = lerpf(0.30, 0.75, pulse)


func _build_visuals() -> void:
	var tint: Color = Hazards.GAS_COLORS[gas]
	var peak_alpha := 0.13 if visible_vapour else 0.035
	var ramp := Vfx.ramp([
		Color(tint.r, tint.g, tint.b, 0.0),
		Color(tint.r, tint.g, tint.b, peak_alpha),
		Color(tint.r, tint.g, tint.b, peak_alpha * 0.55),
		Color(tint.r, tint.g, tint.b, 0.0),
	], [0.0, 0.16, 0.6, 1.0])

	# A leak you can already see is not a sensing problem. The vapour is kept
	# barely perceptible in the daylight feed on purpose: it is the gas overlay
	# and the detector head that are supposed to find this, not your eyes.
	_particles = Vfx.plume_particles(ramp, plume_radius * 0.34, 1.5,
		plume_length / 3.2, 110, Vector2(0.5, 1.2), false)
	add_child(_particles)

	_ring = Vfx.ground_ring(plume_radius * 2.2, tint)
	_ring.position = Vector3(0.0, 0.12, 0.0)
	add_child(_ring)


func _build_audio() -> void:
	var stream := load("res://assets/audio/gas_hiss.wav")
	if stream == null:
		return
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_audio = AudioStreamPlayer3D.new()
	_audio.stream = stream
	_audio.volume_db = hiss_volume_db
	_audio.unit_size = 6.0
	_audio.max_distance = 45.0
	_audio.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
	add_child(_audio)
	_audio.play()


func _default_detail() -> String:
	match gas:
		Hazards.Gas.CO:
			return ("Carbon monoxide from incomplete combustion. Colourless and "
				+ "odourless, so nothing in the visual feed will show it. "
				+ "35 ppm is the 8-hour exposure limit; 1200 ppm is immediately "
				+ "dangerous to life.")
		Hazards.Gas.H2S:
			return ("Hydrogen sulphide, typically from disturbed drainage or "
				+ "decomposition under collapsed structures. Deadens the sense "
				+ "of smell at exactly the concentrations that become lethal, "
				+ "so instruments are the only reliable warning.")
		Hazards.Gas.NO2:
			return ("Nitrogen dioxide - the signature product of an ammonium "
				+ "nitrate detonation, and the reason the Beirut plume was "
				+ "orange-red. Causes delayed pulmonary injury; 20 ppm is "
				+ "immediately dangerous.")
		Hazards.Gas.LEL:
			return ("Combustible gas from a damaged LPG or fuel line, measured "
				+ "as a percentage of its lower explosive limit. At 100% LEL "
				+ "the atmosphere ignites from any spark, including a drone "
				+ "motor.")
		_:
			return ("Oxygen displacement. Heavier gases pooling in a void have "
				+ "pushed breathable air out. Below 19.5% no rescuer may enter "
				+ "without breathing apparatus.")


func _default_action() -> String:
	match gas:
		Hazards.Gas.LEL:
			return "No ignition sources. Isolate upstream valve before entry."
		Hazards.Gas.NO2:
			return "Full breathing apparatus. Approach from upwind only."
		Hazards.Gas.H2S:
			return "Breathing apparatus mandatory. Do not rely on smell."
		Hazards.Gas.CO:
			return "Ventilate before entry. Monitor continuously."
		_:
			return "Confined-space entry procedure with forced ventilation."
