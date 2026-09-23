@tool
class_name CollapsedBlock
extends SitePiece
## Pancaked floor slabs with survivable voids between them, behind a surviving
## stone facade of the older Beirut construction. Two of the survivors are in
## here, which is what makes it the hardest search on the site.

@export_range(1, 8) var levels := 5:
	set(v):
		levels = v
		_request_rebuild()

const LEVEL_SPACING := 2.6


func _build() -> void:
	var broken := Materials.broken_concrete()
	var stone := Materials.stone()
	var g := ground(0.0, 0.0)
	var y := g + 0.4

	for level in levels:
		var lean := rng.randf_range(-9.0, 9.0)
		var offset := Vector3(rng.randf_range(-2.2, 2.2), 0.0, rng.randf_range(-2.2, 2.2))
		slab(Vector3(15.0, 0.42, 12.0), offset + Vector3(0.0, y, 0.0),
			Vector3(lean * 0.4, rng.randf_range(-8.0, 8.0), lean), broken)
		# rubble columns hold the slab up and create the void underneath
		for c in 3:
			slab(Vector3(1.1, 1.9, 1.1),
				Vector3(rng.randf_range(-6.0, 6.0), y + 0.95, rng.randf_range(-5.0, 5.0)),
				Vector3(0.0, rng.randf_range(0.0, 90.0), rng.randf_range(-6.0, 6.0)),
				broken)
		y += LEVEL_SPACING

	# a surviving stone facade
	slab(Vector3(0.6, 9.0, 13.0), Vector3(-8.4, g + 4.5, 0.0), Vector3(0.0, 0.0, 6.0), stone)
	slab(Vector3(11.0, 8.0, 0.6), Vector3(-3.0, g + 4.0, -6.8), Vector3(-5.0, 0.0, 0.0), stone)
