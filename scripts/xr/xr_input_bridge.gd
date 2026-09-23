class_name XrInputBridge
extends Node
## Feeds the OpenXR controllers into the same InputMap actions the keyboard and
## gamepad use.
##
## Injecting through `Input.action_press` instead of reading the controllers
## inside the flight model means there is exactly one flight-control code path,
## so anything tested on the desktop build behaves identically in the headset.

const DEADZONE := 0.12

## action -> last pressed state, for correct just_pressed / just_released edges.
var _state := {}

var left: XRController3D
var right: XRController3D


func setup(left_hand: XRController3D, right_hand: XRController3D) -> void:
	left = left_hand
	right = right_hand


func _process(_delta: float) -> void:
	if left == null or right == null:
		return

	# Left stick: throttle and yaw. Right stick: pitch and roll.
	# This is Mode 2, what almost every drone pilot already has in their hands.
	var lstick := left.get_vector2(&"primary")
	var rstick := right.get_vector2(&"primary")

	_axis("yaw_left", "yaw_right", lstick.x)
	_axis("throttle_down", "throttle_up", lstick.y)
	_axis("roll_left", "roll_right", rstick.x)
	_axis("pitch_down", "pitch_up", rstick.y)

	# Every button a Quest-class controller has that the application is allowed
	# to use. The right-hand menu button is the system button on Quest and is
	# never delivered to apps, so nothing important can live there - reset
	# used to, and could never be pressed. Grips are read as analogue squeeze,
	# which every runtime reports, rather than as a click, which some do not.
	#
	#   RIGHT  trigger  tag what you are looking at      A  cycle sensor
	#          grip     spotlight                        B  drop first-aid kit
	#          stick    orbit the contact
	#   LEFT   trigger  precision (slow) flying          X  thermal on/off
	#          grip     detonate the drum you look at    Y  return to the van
	#          stick    capture evidence photo           menu  settings / pause
	_hold("drop_marker", right.get_float(&"trigger") > 0.7)
	_hold("vision_next", right.is_button_pressed(&"ax_button"))
	_hold("drop_supply", right.is_button_pressed(&"by_button"))
	_hold("toggle_spotlight", right.get_float(&"grip") > 0.6)
	_hold("orbit_poi", right.is_button_pressed(&"primary_click"))

	_hold("precision_mode", left.get_float(&"trigger") > 0.55)
	_hold("toggle_thermal", left.is_button_pressed(&"ax_button"))
	_hold("return_home", left.is_button_pressed(&"by_button"))
	_hold("detonate", left.get_float(&"grip") > 0.6)
	_hold("capture_photo", left.is_button_pressed(&"primary_click"))
	_hold("pause_menu", left.is_button_pressed(&"menu_button"))


func _axis(negative: String, positive: String, value: float) -> void:
	var scaled := (absf(value) - DEADZONE) / (1.0 - DEADZONE)
	if scaled <= 0.0:
		_release(negative)
		_release(positive)
		return
	if value > 0.0:
		Input.action_press(positive, clampf(scaled, 0.0, 1.0))
		_state[positive] = true
		_release(negative)
	else:
		Input.action_press(negative, clampf(scaled, 0.0, 1.0))
		_state[negative] = true
		_release(positive)


func _hold(action: String, pressed: bool) -> void:
	var was: bool = _state.get(action, false)
	if pressed and not was:
		Input.action_press(action)
	elif not pressed and was:
		Input.action_release(action)
	_state[action] = pressed


func _release(action: String) -> void:
	if _state.get(action, false):
		Input.action_release(action)
	_state[action] = false


## Haptic nudge - used for alarms and contact acquisition so the pilot feels a
## finding even when looking the other way.
func pulse(hand: String, amplitude := 0.6, duration := 0.12) -> void:
	var controller: XRController3D = left if hand == "left" else right
	if controller == null:
		return
	controller.trigger_haptic_pulse(&"haptic", 0.0, amplitude, duration, 0.0)
