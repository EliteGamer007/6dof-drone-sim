@tool
extends MeshInstance3D
## A visible handle for things that are otherwise invisible until the game runs
## - a gas leak, a fire, a structural hazard - so they can be found, selected and
## moved in the editor. Shown in the editor, hidden the moment the game starts.

func _ready() -> void:
	visible = Engine.is_editor_hint()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
