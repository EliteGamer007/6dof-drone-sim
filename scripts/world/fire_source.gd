class_name FireSource
extends Detectable
## An active fire: light, flame, smoke column, a large thermal signature and a
## carbon-monoxide plume registered with the hazard field.

@export var intensity := 1.0           ## scales flame size, light and heat
@export var temperature_delta := 420.0 ## K above ambient at the core
@export var heat_radius := 2.6
@export var co_strength := 190.0
@export var smoke_height := 14.0

var _light: OmniLight3D
var _flicker := 0.0


func _ready() -> void:
	kind = Sim.FindingKind.FIRE
	if label == "Contact":
		label = "Active fire"
	if detail == "":
		detail = ("Burning fuel or stored material. Beyond the direct thermal "
			+ "risk it is the dominant carbon monoxide source on site and will "
			+ "keep loading the atmosphere downwind for as long as it runs.")
	if recommended_action == "":
		recommended_action = "Suppress before committing rescuers downwind."
	severity = Sim.Severity.WARNING
	thermal_contrast = 1.0
	detection_radius = 1.6 * intensity
	super._ready()

	# The burning bed on the ground, and above it the column of hot gas, which
	# is what heats the walls and wreckage standing around a fire.
	Hazards.register_heat_capsule(self, Vector3(0.0, 0.2, 0.0), Vector3(0.0, 0.2, 0.0),
		1.0 * intensity, temperature_delta * intensity, false, 1.8 * intensity,
		Hazards.HeatKind.FIRE)
	Hazards.register_heat_capsule(self, Vector3(0.0, 0.6, 0.0),
		Vector3(0.0, 3.6 * intensity, 0.0), 0.45 * intensity, 150.0 * intensity, false,
		1.3 * intensity, Hazards.HeatKind.FIRE)
	Hazards.register_plume(self, Hazards.Gas.CO, co_strength * intensity,
		heat_radius * 1.2, 30.0, 2.2)

	_build_flame()
	_build_smoke()
	_build_light()
	_build_audio()


func _exit_tree() -> void:
	Hazards.unregister(self)


func _process(delta: float) -> void:
	if _light == null:
		return
	# Two detuned sine terms read as a far less mechanical flicker than noise.
	_flicker += delta
	var f := 0.72 + 0.18 * sin(_flicker * 11.3) + 0.14 * sin(_flicker * 27.7)
	_light.light_energy = f * 6.0 * intensity


func _build_flame() -> void:
	var ramp := Vfx.ramp([
		Color(1.0, 0.95, 0.55, 0.0),
		Color(1.0, 0.78, 0.25, 0.95),
		Color(1.0, 0.36, 0.06, 0.75),
		Color(0.35, 0.10, 0.03, 0.0),
	], [0.0, 0.12, 0.55, 1.0])

	var flame := Vfx.plume_particles(ramp, 0.75 * intensity, 3.4, 1.1, 90,
		Vector2(0.7, 1.6), true)
	var pm := flame.process_material as ParticleProcessMaterial
	pm.spread = 14.0
	pm.turbulence_noise_strength = 1.6
	flame.name = "Flame"
	add_child(flame)


func _build_smoke() -> void:
	var ramp := Vfx.ramp([
		Color(0.22, 0.20, 0.19, 0.0),
		Color(0.16, 0.15, 0.14, 0.72),
		Color(0.30, 0.29, 0.28, 0.40),
		Color(0.45, 0.44, 0.43, 0.0),
	], [0.0, 0.18, 0.6, 1.0])

	var smoke := Vfx.plume_particles(ramp, 1.9 * intensity, 2.6,
		smoke_height / 2.2, 110, Vector2(1.4, 3.6), false)
	smoke.name = "Smoke"
	smoke.position.y = 1.2 * intensity
	add_child(smoke)


func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.56, 0.22)
	_light.omni_range = 18.0 * intensity
	_light.light_energy = 6.0 * intensity
	_light.shadow_enabled = true
	_light.light_volumetric_fog_energy = 2.5
	_light.position.y = 1.0
	add_child(_light)


func _build_audio() -> void:
	var stream := load("res://assets/audio/fire_crackle.wav")
	if stream == null:
		return
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	var audio := AudioStreamPlayer3D.new()
	audio.stream = stream
	audio.volume_db = -12.0
	audio.unit_size = 10.0
	audio.max_distance = 70.0
	add_child(audio)
	audio.play()
