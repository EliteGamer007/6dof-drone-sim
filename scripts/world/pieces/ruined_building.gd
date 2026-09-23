@tool
class_name RuinedBuilding
extends SitePiece
## One damaged city block.
##
## `collapse` runs 0 (barely touched: a shell with its floors intact) to 1
## (flattened into a pancake stack). Everything between is a partial: some
## floors down, some walls still standing, the rest in a heap at the base.
## Drag the slider in the inspector and the building falls down in the editor.

@export_range(6.0, 40.0, 0.5) var width := 16.0:
	set(v):
		width = v
		_request_rebuild()
@export_range(3.0, 60.0, 0.5) var height := 14.0:
	set(v):
		height = v
		_request_rebuild()
@export_range(6.0, 40.0, 0.5) var depth := 12.0:
	set(v):
		depth = v
		_request_rebuild()
@export_range(0.0, 1.0, 0.05) var collapse := 0.5:
	set(v):
		collapse = v
		_request_rebuild()

const FLOOR_HEIGHT := 3.4


func _build() -> void:
	var concrete := Materials.concrete()
	var broken := Materials.broken_concrete()
	var stone := Materials.stone()

	var base := ground(0.0, 0.0)
	var floors := maxi(int(height / FLOOR_HEIGHT), 1)
	var standing := int(round(float(floors) * (1.0 - collapse)))

	# Standing floors: four corner columns and a slab over them.
	for level in standing:
		var y := base + float(level) * FLOOR_HEIGHT
		for cx in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				slab(Vector3(0.8, FLOOR_HEIGHT, 0.8),
					Vector3(cx * (width * 0.5 - 0.6), y + FLOOR_HEIGHT * 0.5,
						cz * (depth * 0.5 - 0.6)), Vector3.ZERO, concrete)
		slab(Vector3(width, 0.38, depth), Vector3(0.0, y + FLOOR_HEIGHT, 0.0),
			Vector3.ZERO, concrete)

	# Surviving wall sections. Not all four sides: a building with every wall
	# intact does not read as damaged.
	if standing > 0:
		var wall_h := float(standing) * FLOOR_HEIGHT
		slab(Vector3(0.45, wall_h, depth), Vector3(-width * 0.5, base + wall_h * 0.5, 0.0),
			Vector3.ZERO, stone)
		if rng.randf() < 0.65:
			slab(Vector3(width, wall_h * 0.7, 0.45),
				Vector3(0.0, base + wall_h * 0.35, -depth * 0.5), Vector3.ZERO, stone)
		if rng.randf() < 0.4:
			slab(Vector3(0.45, wall_h * 0.55, depth * 0.6),
				Vector3(width * 0.5, base + wall_h * 0.28, depth * 0.2),
				Vector3(0.0, 0.0, rng.randf_range(-4.0, 4.0)), stone)

	# Collapsed floors, pancaked onto whatever is left standing.
	var pile_base := base + float(standing) * FLOOR_HEIGHT
	for level in floors - standing:
		var lean := rng.randf_range(-11.0, 11.0)
		var y := pile_base + float(level) * 0.95 + 0.3
		slab(Vector3(width * rng.randf_range(0.82, 1.02), 0.4,
				depth * rng.randf_range(0.82, 1.02)),
			Vector3(rng.randf_range(-1.8, 1.8), y, rng.randf_range(-1.8, 1.8)),
			Vector3(lean * 0.5, rng.randf_range(-14.0, 14.0), lean), broken)
		# rubble columns propping the slab, which is what makes the void
		for c in 2:
			slab(Vector3(1.0, 0.8, 1.0),
				Vector3(rng.randf_range(-width * 0.35, width * 0.35), y - 0.6,
					rng.randf_range(-depth * 0.35, depth * 0.35)),
				Vector3(0.0, rng.randf_range(0.0, 90.0), 0.0), broken)

	# Debris apron round the base - buildings do not fall straight down.
	for i in int(6.0 + collapse * 8.0):
		var a := rng.randf() * TAU
		var r := rng.randf_range(width * 0.45, width * 0.9)
		var p := Vector2(cos(a) * r, sin(a) * r)
		slab(Vector3(rng.randf_range(1.2, 3.4), rng.randf_range(0.4, 1.1),
				rng.randf_range(1.2, 3.4)),
			Vector3(p.x, ground(p.x, p.y) + rng.randf_range(0.1, 0.5), p.y),
			Vector3(rng.randf_range(-16.0, 16.0), rng.randf_range(0.0, 90.0),
				rng.randf_range(-16.0, 16.0)), broken)
