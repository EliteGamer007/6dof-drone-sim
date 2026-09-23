@tool
class_name HazardSign
extends SitePiece
## A warning board on two posts, placed where an unbriefed rescuer would walk
## into something that would kill them. The label is shown in the editor so a
## board can be told apart from the others; the board itself is striped rather
## than lettered, which is what reads from the air.

@export var text := "Hazard":
	set(v):
		text = v
		_request_rebuild()
@export var board_colour := Color(0.92, 0.20, 0.16):
	set(v):
		board_colour = v
		_request_rebuild()


func _build() -> void:
	var g := ground(0.0, 0.0)
	var post := StandardMaterial3D.new()
	post.albedo_color = Color(0.45, 0.46, 0.48)
	post.metallic = 0.5
	post.roughness = 0.5
	for x in [-0.7, 0.7]:
		slab(Vector3(0.08, 2.0, 0.08), Vector3(x, g + 1.0, 0.0), Vector3.ZERO, post)

	var face := StandardMaterial3D.new()
	face.albedo_color = board_colour
	face.roughness = 0.75
	face.emission_enabled = true
	face.emission = board_colour
	face.emission_energy_multiplier = 0.45
	slab(Vector3(1.9, 1.2, 0.07), Vector3(0.0, g + 2.1, 0.0), Vector3.ZERO, face)

	var bar := StandardMaterial3D.new()
	bar.albedo_color = Color(0.06, 0.06, 0.07)
	bar.roughness = 0.8
	for stripe in [-0.32, 0.0, 0.32]:
		box(Vector3(1.7, 0.12, 0.02), Vector3(0.0, g + 2.1 + stripe, 0.05), bar)

	if not is_runtime():
		var label := Label3D.new()
		label.text = text
		label.position = Vector3(0.0, g + 3.1, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = 0.01
		add_generated(label)
