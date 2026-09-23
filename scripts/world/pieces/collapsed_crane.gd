@tool
class_name CollapsedCrane
extends SitePiece
## The quay crane, folded across the container yard.
##
## Built as one connected structure - portal legs, a head beam, a boom hinged
## at the top of the standing leg and dropped across the stacks - because a
## crane drawn as separate floating members reads as debris, not as a machine
## that has failed.


func _build() -> void:
	var steel := Materials.rusted_steel()
	var g := ground(0.0, 0.0)

	# Standing portal: two columns, a head beam, and the rail sill they run on.
	for x in [-5.2, 5.2]:
		slab(Vector3(1.1, 14.0, 1.1), Vector3(x, g + 7.0, 10.0),
			Vector3(0.0, 0.0, -3.0 * signf(x)), steel)
		slab(Vector3(2.2, 0.9, 3.4), Vector3(x, ground(x, 10.0) + 0.45, 10.0),
			Vector3.ZERO, steel)
	slab(Vector3(12.4, 1.3, 1.6), Vector3(0.0, g + 14.3, 10.0), Vector3.ZERO, steel)
	# diagonal bracing, so the portal reads as a frame
	for s in [-1.0, 1.0]:
		slab(Vector3(11.6, 0.55, 0.55), Vector3(0.0, g + 7.6, 10.0),
			Vector3(0.0, 0.0, 34.0 * s), steel)

	# The boom: hinged at the head beam, dropped across the stacks. One piece,
	# so both ends actually meet something.
	slab(Vector3(1.8, 1.8, 32.0), Vector3(0.0, g + 8.6, -5.0), Vector3(-19.6, 0.0, 0.0), steel)
	for x in [-1.3, 1.3]:
		slab(Vector3(0.35, 0.35, 26.0), Vector3(x, g + 10.4, -2.0),
			Vector3(-19.6, 0.0, 0.0), steel)

	# Machinery house, riding the boom just outboard of the hinge.
	slab(Vector3(3.8, 3.0, 4.6), Vector3(0.0, g + 14.0, 5.4), Vector3(-19.6, 0.0, 0.0), steel)

	# The far leg has buckled and lies across the yard under the boom.
	slab(Vector3(1.1, 12.0, 1.1), Vector3(-2.4, g + 1.4, -14.0), Vector3(74.0, 8.0, 0.0), steel)
	slab(Vector3(2.2, 0.9, 3.4), Vector3(-5.0, g + 0.6, -19.4), Vector3(12.0, 26.0, 8.0), steel)

	if not is_runtime():
		return
	var d := Detectable.new()
	d.kind = Sim.FindingKind.STRUCTURAL
	d.label = "Collapsed quay crane"
	d.detail = ("The gantry has folded across the container yard, the boom still "
		+ "under load and resting on the stacks. The standing leg is out of plumb "
		+ "and the whole structure is one aftershock from moving.")
	d.recommended_action = ("Treat the yard as an exclusion zone. Survey the "
		+ "containers underneath by air only.")
	d.severity = Sim.Severity.WARNING
	d.detection_radius = 7.0
	d.max_detect_range = 130.0
	d.position = Vector3(0.0, g + 9.0, 2.0)
	add_generated(d)
