@tool
class_name PipeCorridor
extends SitePiece
## Two rows of concrete supports carrying three steel runs at low level. It
## forces the pilot down into a slot where the gas actually pools - which is
## where the LPG leak and one of the survivors are.

@export_range(2, 20) var supports := 9:
	set(v):
		supports = v
		_request_rebuild()
@export_range(3.0, 20.0, 0.5) var support_spacing := 9.0:
	set(v):
		support_spacing = v
		_request_rebuild()
@export_range(2.0, 12.0, 0.5) var corridor_width := 6.0:
	set(v):
		corridor_width = v
		_request_rebuild()
@export_range(1, 5) var pipe_runs := 3:
	set(v):
		pipe_runs = v
		_request_rebuild()


func _build() -> void:
	var steel := Materials.rusted_steel()
	var concrete := Materials.concrete()
	for i in supports:
		var x := float(i) * support_spacing
		for z in [0.0, corridor_width]:
			slab(Vector3(1.0, 5.2, 1.0), Vector3(x, ground(x, z) + 2.6, z),
				Vector3.ZERO, concrete)

	var length := float(supports - 1) * support_spacing + 10.0
	var mid := float(supports - 1) * support_spacing * 0.5
	var base := ground(mid, corridor_width * 0.5) + 4.2
	for run in pipe_runs:
		cylinder(0.34, length, Vector3(mid, base + float(run) * 0.55, float(run) * 0.9),
			steel, Vector3(0.0, 0.0, 90.0))
