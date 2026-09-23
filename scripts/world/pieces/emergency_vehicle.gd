@tool
class_name EmergencyVehicle
extends SitePiece
## A boxed-body emergency vehicle: chassis, cab, glass, livery, wheels and a
## strobing light bar. The response van, the ambulance and the fire appliance
## are all this one piece with different exports.
##
## With `landing_deck` on it is the response van: the roof carries a marked
## touchdown circle the drone launches from and returns to, and it registers
## itself as the launch pad - so moving the van in the editor moves where the
## aircraft starts.

const LAUNCH_PAD_GROUP := "launch_pad"

@export var length := 5.4:
	set(v):
		length = v
		_request_rebuild()
@export var width := 2.16:
	set(v):
		width = v
		_request_rebuild()
@export var body_height := 1.78:
	set(v):
		body_height = v
		_request_rebuild()
@export var shell_colour := Color(0.86, 0.87, 0.88):
	set(v):
		shell_colour = v
		_request_rebuild()
@export var livery_colour := Color(0.86, 0.33, 0.06):
	set(v):
		livery_colour = v
		_request_rebuild()
@export var bar_colours := PackedColorArray([Color(1.0, 0.18, 0.16), Color(0.25, 0.45, 1.0)]):
	set(v):
		bar_colours = v
		_request_rebuild()
@export_group("Equipment")
@export var landing_deck := false:
	set(v):
		landing_deck = v
		_request_rebuild()
@export var ladder := false:
	set(v):
		ladder = v
		_request_rebuild()
@export var worklight := false:
	set(v):
		worklight = v
		_request_rebuild()
@export var engine_heat := 38.0          ## bonnet temperature on the thermal channel

const FLOOR_Y := 0.66

var _deck_local := Vector3.ZERO


func _ready() -> void:
	super._ready()
	if landing_deck:
		add_to_group(LAUNCH_PAD_GROUP)


func _exit_tree() -> void:
	if is_runtime():
		Hazards.unregister(self)


## Where the drone sits on the deck, in world space.
func deck_point() -> Vector3:
	return global_transform * (_deck_local + Vector3.UP * 0.12)


func _build() -> void:
	var shell := StandardMaterial3D.new()
	shell.albedo_color = shell_colour
	shell.roughness = 0.45
	shell.metallic = 0.3
	var trim := StandardMaterial3D.new()
	trim.albedo_color = livery_colour
	trim.roughness = 0.42
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.07, 0.10, 0.12)
	glass.roughness = 0.12
	glass.metallic = 0.85
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.06, 0.06, 0.07)
	rubber.roughness = 0.95

	var g := ground(0.0, 0.0)
	var box_len := length * 0.66
	var cab_len := length * 0.30
	var box_z := length * 0.5 - box_len * 0.5 - 0.05
	var cab_z := -length * 0.5 + cab_len * 0.5 + 0.05
	var floor_y := g + FLOOR_Y

	slab(Vector3(width, body_height, box_len),
		Vector3(0.0, floor_y + body_height * 0.5, box_z), Vector3.ZERO, shell)
	slab(Vector3(width * 0.94, body_height * 0.70, cab_len),
		Vector3(0.0, floor_y + body_height * 0.35, cab_z), Vector3.ZERO, shell)
	slab(Vector3(width * 0.97, 0.30, length), Vector3(0.0, floor_y, 0.0), Vector3.ZERO, rubber)
	slab(Vector3(width * 0.86, body_height * 0.48, 0.10),
		Vector3(0.0, floor_y + body_height * 0.52, cab_z - cab_len * 0.5),
		Vector3(-16.0, 0.0, 0.0), glass)
	for side in [-1.0, 1.0]:
		box(Vector3(0.06, body_height * 0.34, cab_len * 0.62),
			Vector3(width * 0.47 * side, floor_y + body_height * 0.46, cab_z), glass)
		box(Vector3(0.05, body_height * 0.20, box_len * 0.99),
			Vector3(width * 0.5 * side, floor_y + body_height * 0.30, box_z), trim)
	box(Vector3(width, body_height * 0.20, 0.05),
		Vector3(0.0, floor_y + body_height * 0.30, box_z + box_len * 0.5), trim)

	var axle := length * 0.30
	for wheel in [Vector3(-width * 0.47, 0.44, -axle), Vector3(width * 0.47, 0.44, -axle),
			Vector3(-width * 0.47, 0.44, axle), Vector3(width * 0.47, 0.44, axle)]:
		var tyre := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.44
		cyl.bottom_radius = 0.44
		cyl.height = 0.28
		cyl.radial_segments = 16
		tyre.mesh = cyl
		tyre.material_override = rubber
		tyre.position = wheel + Vector3(0.0, g, 0.0)
		tyre.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		tyre.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_generated(tyre)

	_build_light_bar(Vector3(0.0, floor_y + body_height * 0.72, cab_z), width * 0.8)

	var roof := floor_y + body_height
	if landing_deck:
		_build_deck(roof, box_z, box_len)
	if ladder:
		_build_ladder(roof, box_z, box_len)
	if worklight:
		var work := SpotLight3D.new()
		work.name = "Worklight"
		work.position = Vector3(0.0, floor_y + body_height * 0.85, cab_z - cab_len * 0.5)
		work.rotation_degrees = Vector3(-11.0, 0.0, 0.0)
		work.light_color = Color(1.0, 0.95, 0.86)
		work.light_energy = 5.0
		work.spot_range = 42.0
		work.spot_angle = 34.0
		work.spot_attenuation = 1.4
		work.shadow_enabled = false
		add_generated(BuildKit.night_light(work))

	if is_runtime() and engine_heat > 0.0:
		# A vehicle that has just been driven in reads hot across the bonnet.
		Hazards.unregister(self)
		Hazards.register_heat_capsule(self, Vector3(0.0, floor_y + 0.3, cab_z - 0.4),
			Vector3(0.0, floor_y + 0.3, cab_z + 0.4), 0.55, engine_heat, true, 0.25,
			Hazards.HeatKind.MACHINE)


func _build_light_bar(pos: Vector3, bar_width: float) -> void:
	var housing := StandardMaterial3D.new()
	housing.albedo_color = Color(0.08, 0.08, 0.09)
	housing.roughness = 0.6
	box(Vector3(bar_width, 0.12, 0.26), pos, housing)
	for i in bar_colours.size():
		var colour := bar_colours[i]
		var offset := (float(i) - (bar_colours.size() - 1) * 0.5) * (bar_width * 0.52)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colour
		mat.emission_enabled = true
		mat.emission = colour
		mat.emission_energy_multiplier = 4.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var lamp := box(Vector3(bar_width * 0.42, 0.10, 0.22),
			pos + Vector3(offset, 0.0, 0.0), mat)

		var light := OmniLight3D.new()
		light.position = lamp.position + Vector3(0.0, 0.05, 0.0)
		light.light_color = colour
		light.light_energy = 2.4
		light.omni_range = 8.0
		light.shadow_enabled = false
		add_generated(BuildKit.night_light(light))

		if is_runtime():
			# Double-tap strobe, lamps on opposite phases so the bar alternates.
			var beacon := BeaconLight.new()
			beacon.lamp = lamp
			beacon.light = light
			beacon.base_colour = colour
			beacon.phase = float(i) * 0.5
			add_generated(beacon)


## The landing deck: a plate on the box roof with a marked touchdown circle,
## so it is obvious both where to take off from and what to aim at on the way
## home. It is real collision - the aircraft sits on it.
func _build_deck(roof: float, box_z: float, box_len: float) -> void:
	var deck := StandardMaterial3D.new()
	deck.albedo_color = Color(0.14, 0.15, 0.17)
	deck.roughness = 0.8
	slab(Vector3(width + 0.08, 0.10, box_len + 0.1), Vector3(0.0, roof + 0.05, box_z),
		Vector3.ZERO, deck)
	var top := roof + 0.10
	_deck_local = Vector3(0.0, top, box_z)

	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.94, 0.58, 0.14)
	paint.roughness = 0.9
	paint.emission_enabled = true
	paint.emission = Color(0.9, 0.5, 0.12)
	paint.emission_energy_multiplier = 0.35
	for i in 28:
		var a := TAU * float(i) / 28.0
		box(Vector3(0.11, 0.012, 0.03),
			Vector3(cos(a) * 0.80, top + 0.01, box_z + sin(a) * 0.80), paint,
			Vector3(0.0, -rad_to_deg(a), 0.0))
	box(Vector3(0.78, 0.012, 0.045), Vector3(0.0, top + 0.01, box_z), paint)
	box(Vector3(0.045, 0.012, 0.78), Vector3(0.0, top + 0.01, box_z), paint)
	for corner in [Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 0.0, -1.0),
			Vector3(-1.0, 0.0, 1.0), Vector3(1.0, 0.0, 1.0)]:
		box(Vector3(0.055, 0.22, 0.055),
			Vector3(corner.x * (width * 0.5 - 0.08), top + 0.11,
				box_z + corner.z * (box_len * 0.5 - 0.08)), paint)


func _build_ladder(roof: float, box_z: float, box_len: float) -> void:
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.70, 0.72, 0.74)
	steel.metallic = 0.75
	steel.roughness = 0.35
	for rail in [-0.55, 0.55]:
		box(Vector3(0.07, 0.07, box_len * 1.25), Vector3(rail, roof + 0.2, box_z - 0.3), steel)
	for i in 9:
		box(Vector3(1.10, 0.05, 0.05),
			Vector3(0.0, roof + 0.2, box_z - box_len * 0.6 + float(i) * box_len * 0.15), steel)

	var monitor := SpotLight3D.new()
	monitor.position = Vector3(0.0, roof + 0.5, box_z - box_len * 0.4)
	monitor.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	monitor.light_color = Color(1.0, 0.94, 0.84)
	monitor.light_energy = 6.0
	monitor.spot_range = 46.0
	monitor.spot_angle = 30.0
	monitor.shadow_enabled = false
	add_generated(BuildKit.night_light(monitor))
