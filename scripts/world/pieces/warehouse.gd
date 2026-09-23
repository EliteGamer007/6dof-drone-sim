@tool
class_name Warehouse
extends SitePiece
## Open steel shell with a partly collapsed roof - the obstacle course the pilot
## has to thread to reach the casualty inside.

@export_range(2, 10) var bays := 5:
	set(v):
		bays = v
		_request_rebuild()
@export_range(0, 6) var fallen_bays := 2:
	set(v):
		fallen_bays = v
		_request_rebuild()

const SPAN := 9.0
const HALF_WIDTH := 11.0
const HEIGHT := 11.0


func _build() -> void:
	var steel := Materials.rusted_steel()
	var concrete := Materials.concrete()
	var length := float(bays) * SPAN

	for i in bays + 1:
		var z := float(i) * SPAN - length * 0.5
		for side in [-1.0, 1.0]:
			var x: float = side * HALF_WIDTH
			cylinder(0.32, HEIGHT, Vector3(x, ground(x, z) + HEIGHT * 0.5, z), steel)
		# One roof truss per bay, dropped into the bays at the far end. (The
		# original builder made this inside the per-side loop, so every bay had
		# two identical trusses in the same place.)
		if i < bays:
			var fallen := i >= bays - fallen_bays
			var y := ground(0.0, z) + HEIGHT + (-4.5 if fallen else 0.15)
			var tilt := Vector3(0.0, 0.0, rng.randf_range(-34.0, 34.0) if fallen else 0.0)
			slab(Vector3(23.0, 0.35, 0.9), Vector3(0.0, y, z + SPAN * 0.5), tilt, steel)

	# floor slab and a surviving end wall
	var g0 := ground(0.0, 0.0)
	slab(Vector3(23.0, 0.4, length), Vector3(0.0, g0 + 0.1, 0.0), Vector3.ZERO, concrete)
	slab(Vector3(23.0, HEIGHT, 0.5), Vector3(0.0, g0 + HEIGHT * 0.5, -length * 0.5),
		Vector3.ZERO, concrete)
