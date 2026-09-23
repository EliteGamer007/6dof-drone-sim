@tool
class_name GrainSilos
extends SitePiece
## The grain silos were the defining silhouette of the Beirut port after the
## blast, so a simplified mass is modelled even though the rest of the port is
## abstract. The near cells are torn open - that is the entry the mission uses.

@export_range(1, 4) var rows := 2:
	set(v):
		rows = v
		_request_rebuild()
@export_range(1, 8) var columns := 4:
	set(v):
		columns = v
		_request_rebuild()
@export_range(0, 8) var ruptured := 3:
	set(v):
		ruptured = v
		_request_rebuild()

const SPACING := 9.4
const RADIUS := 4.3


func _build() -> void:
	var concrete := Materials.concrete()
	var broken := Materials.broken_concrete()
	var i := 0
	for row in rows:
		for col in columns:
			var p := Vector2(float(col) * SPACING, float(row) * SPACING)
			var g := ground(p.x, p.y)
			var torn := i < ruptured
			var h := 17.0 if torn else 33.0
			cylinder(RADIUS, h, Vector3(p.x, g + h * 0.5 - 0.5, p.y),
				broken if torn else concrete)
			if torn:
				# torn concrete lip and spilled grain mass
				slab(Vector3(9.0, 1.2, 4.0), Vector3(p.x + 2.4, g + h, p.y - 1.0),
					Vector3(rng.randf_range(-26.0, -8.0), rng.randf_range(0.0, 90.0), 6.0),
					broken)
			i += 1
