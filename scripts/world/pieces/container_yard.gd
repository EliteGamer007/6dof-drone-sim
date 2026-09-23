@tool
class_name ContainerYard
extends SitePiece
## Stacked shipping containers, some thrown over by the blast. One survivor is
## up on the stack, signalling.

@export_range(1, 40) var containers := 14:
	set(v):
		containers = v
		_request_rebuild()
@export_range(1, 8) var per_row := 5:
	set(v):
		per_row = v
		_request_rebuild()
@export_range(1, 4) var max_stack := 3:
	set(v):
		max_stack = v
		_request_rebuild()
@export_range(0.0, 1.0, 0.05) var toppled_chance := 0.22:
	set(v):
		toppled_chance = v
		_request_rebuild()

const COLOURS := [Color(0.62, 0.30, 0.24), Color(0.28, 0.42, 0.52),
	Color(0.55, 0.52, 0.30), Color(0.38, 0.45, 0.36)]


func _build() -> void:
	var steel := Materials.rusted_steel()
	for i in containers:
		var x := float(i % per_row) * 7.0 + rng.randf_range(-0.6, 0.6)
		var z := float(i / per_row) * 3.4
		var stack := rng.randi_range(1, max_stack)
		var g := ground(x, z)
		for s in stack:
			var mat := steel.duplicate() as StandardMaterial3D
			mat.albedo_color = COLOURS[rng.randi() % COLOURS.size()]
			var toppled := rng.randf() < toppled_chance and s == stack - 1
			slab(Vector3(6.1, 2.6, 2.44), Vector3(x, g + 1.35 + float(s) * 2.65, z),
				Vector3(0.0, rng.randf_range(-4.0, 4.0),
					rng.randf_range(38.0, 86.0) if toppled else 0.0), mat)
