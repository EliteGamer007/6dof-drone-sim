class_name Detectable
extends Node3D
## Anything the payload is meant to find: a survivor, a leaking cylinder, a
## fire, a compromised structure.
##
## Each one carries its own briefing text. That is deliberate - when the
## operator puts the reticle on a contact, the HUD can explain *what* it is,
## *why* it matters and *what to do about it*, which is the difference between
## a pretty picture and something an assessor can act on.

@export var kind: Sim.FindingKind = Sim.FindingKind.STRUCTURAL
@export var label := "Contact"
@export_multiline var detail := ""
@export_multiline var recommended_action := ""
@export var severity: Sim.Severity = Sim.Severity.CAUTION
@export var detection_radius := 1.0        ## metres, drives the on-screen box
@export var max_detect_range := 70.0
@export var thermal_contrast := 0.0        ## 0 invisible in IR .. 1 glows
@export var requires_line_of_sight := true
@export var auto_log := true

var detected := false
var best_confidence := 0.0
var first_detected_at := -1.0
var finding_id := 0
var tagged := false            ## true once this contact is in the findings log


func _ready() -> void:
	add_to_group("detectable")


## The de-duplication key for this contact. Every route into the findings log -
## the automatic detector and the operator's tag button alike - uses this one
## key, so a contact can only ever produce a single finding no matter how many
## times it is seen or tagged.
func contact_key() -> String:
	return "contact_%d" % get_instance_id()


## Called once, when this contact first reaches the findings log. Subclasses
## override it to show that they have been accounted for.
func mark_tagged() -> void:
	if tagged:
		return
	tagged = true
	_on_tagged()


func _on_tagged() -> void:
	pass


func describe() -> String:
	return detail if detail != "" else label


## Confidence multiplier this target gets from the current sensor mode.
func sensor_advantage(mode: Sim.VisionMode) -> float:
	match mode:
		Sim.VisionMode.THERMAL:
			return 1.0 + thermal_contrast * 1.35
		Sim.VisionMode.NIGHT:
			return 1.0 + thermal_contrast * 0.25
		Sim.VisionMode.GAS:
			return 1.25 if kind == Sim.FindingKind.GAS_LEAK else 0.7
		_:
			return 1.0
