class_name PayloadBay
extends Node3D
## Under-slung release for first-aid kits.
##
## Search drones that find someone who cannot be reached yet drop them a kit:
## a tourniquet, water, a light, a radio. Four aboard; each one falls under a
## small parachute and is credited to whichever survivor it lands beside.

signal kit_dropped(crate: SupplyCrate)

@export var capacity := 4

var remaining := 4

var _drone: Drone


func _ready() -> void:
	remaining = capacity
	_drone = get_parent() as Drone


func drop() -> void:
	if remaining <= 0:
		Sim.toast.emit("PAYLOAD BAY EMPTY  -  RETURN TO THE VAN TO RELOAD",
			Sim.Severity.CAUTION)
		Sfx.play("ui_click", -6.0, 0.7)
		return
	if _drone and _drone.altitude_agl() < 1.2:
		Sim.toast.emit("TOO LOW TO RELEASE", Sim.Severity.INFO)
		return

	remaining -= 1
	var crate := SupplyCrate.new()
	crate.name = "SupplyCrate"
	# Positioned before it enters the tree, so the interpolated first frame
	# starts at the bay rather than streaking in from the world origin.
	crate.position = global_position + Vector3.DOWN * 0.15
	var world := get_tree().current_scene
	world.add_child(crate)
	crate.reset_physics_interpolation()
	if _drone:
		# It leaves with the aircraft's momentum, which is why a kit dropped
		# at speed lands downrange of the release point.
		crate.linear_velocity = _drone.linear_velocity * 0.85
	Sfx.play("marker_drop", -3.0, 1.35)
	Sim.toast.emit("KIT RELEASED  -  %d LEFT" % remaining, Sim.Severity.INFO)
	kit_dropped.emit(crate)


func reload() -> void:
	remaining = capacity
