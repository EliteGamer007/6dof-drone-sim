@tool
class_name PropModel
extends SitePiece
## Any Poly Haven model from assets/polyhaven/models, sat on the terrain with a
## collider fitted to its bounds. Pick the model by folder name in the
## inspector - "concrete_road_barrier", "portable_generator" and so on - and it
## appears in the editor straight away.

@export var model_name := "wooden_crate_01":
	set(v):
		model_name = v
		_request_rebuild()
@export var model_scale := 1.0:
	set(v):
		model_scale = v
		_request_rebuild()
@export var collide := true:
	set(v):
		collide = v
		_request_rebuild()
@export var tilt := 0.0:
	set(v):
		tilt = v
		_request_rebuild()


func _build() -> void:
	model(model_name, Vector3(0.0, ground(0.0, 0.0), 0.0), 0.0, model_scale, collide, tilt)
