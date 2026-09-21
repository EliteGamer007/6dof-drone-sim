class_name BeaconLight
extends Node
## Drives one lamp on an emergency vehicle's light bar.
##
## Two short flashes then a gap, which is what a real strobe bar does and what
## makes it read as one at a distance - a smooth sine just looks like something
## breathing. Lamps are given opposite phases so a bar alternates.

@export var phase := 0.0           ## 0 or 0.5, to alternate across a bar
@export var period := 1.05         ## seconds for the full cycle
@export var base_colour := Color(1.0, 0.2, 0.2)
@export var peak_energy := 5.5
@export var idle_energy := 0.25

var lamp: MeshInstance3D
var light: OmniLight3D

var _mat: StandardMaterial3D


func _ready() -> void:
	if lamp and lamp.material_override is StandardMaterial3D:
		# Duplicated so each lamp animates independently of its neighbours.
		_mat = (lamp.material_override as StandardMaterial3D).duplicate()
		lamp.material_override = _mat


func _process(_delta: float) -> void:
	var t := fposmod(Time.get_ticks_msec() / 1000.0 / period + phase, 1.0)
	# Double-tap: bright at the start of the half-cycle, again just after, then
	# dark for the rest.
	var on := 1.0 if (t < 0.07 or (t > 0.12 and t < 0.19)) else 0.0
	var energy := lerpf(idle_energy, peak_energy, on)

	if light and is_instance_valid(light):
		light.light_energy = energy
	if _mat:
		_mat.emission_energy_multiplier = lerpf(0.9, 7.0, on)
