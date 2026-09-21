class_name FlightTest
extends Node
## Handling check, run with:  Godot --headless --path . -- --flighttest
##
## Measures the three things the handling model has to get right at once:
##   * hands off, it must not drift at all
##   * held forward, it must build up to speed over a moment and then hold it
##   * released, it must stop, and stop in a sane distance
##
## The acceleration and stopping numbers are the ones that separate "has
## weight" from "arcade", so they are printed rather than just asserted - a
## regression here is a feel problem, not a pass/fail one.

var _main: Node
var _t := 0.0
var _phase := 0
var _mark := Vector3.ZERO
var _spool_time := -1.0
var _peak_bank := 0.0
var _release_speed := 0.0


func setup(main: Node) -> void:
	_main = main


func _physics_process(delta: float) -> void:
	var drone: Drone = _main.drone
	_t += delta
	match _phase:
		0:
			if _t > 1.0:
				_mark = drone.global_position
				_phase = 1
				_t = 0.0
		1:  # hands off for 5 s
			if _t > 5.0:
				print("[flight] hover drift over 5 s: %.2f m"
					% drone.global_position.distance_to(_mark))
				Input.action_press("throttle_up")
				_phase = 2
				_t = 0.0
		2:  # climb 2 s
			if _t > 2.0:
				Input.action_release("throttle_up")
				_mark = drone.global_position
				Input.action_press("pitch_up")
				_phase = 3
				_t = 0.0
		3:  # forward 8 s
			_peak_bank = maxf(_peak_bank, absf(rad_to_deg(drone.body_lean().x)))
			if _spool_time < 0.0 and drone.ground_speed() > drone.cruise_speed * 0.9:
				_spool_time = _t
				print("[flight] time to 90%% of cruise speed: %.2f s" % _spool_time)
			if _t > 4.0 and _t - delta <= 4.0:
				print("[flight] speed after 4 s forward: %.1f m/s" % drone.ground_speed())
			if _t > 8.0:
				print("[flight] speed after 8 s forward: %.1f m/s, travelled %.1f m" % [
					drone.ground_speed(), drone.global_position.distance_to(_mark)])
				print("[flight] peak nose-down bank while accelerating: %.1f deg"
					% _peak_bank)
				_release_speed = drone.ground_speed()
				_mark = drone.global_position
				Input.action_release("pitch_up")
				_phase = 4
				_t = 0.0
		4:  # released
			if _t > 2.0:
				print("[flight] speed 2 s after release: %.2f m/s"
					% drone.linear_velocity.length())
				print("[flight] stopping distance from %.1f m/s: %.1f m"
					% [_release_speed, drone.global_position.distance_to(_mark)])
				_mark = drone.global_position
				Input.action_press("yaw_right")
				_phase = 5
				_t = 0.0
		5:  # turn on the spot for 3 s
			if _t > 3.0:
				Input.action_release("yaw_right")
				print("[flight] yaw rate after 3 s: %.0f deg/s, wandered %.2f m"
					% [rad_to_deg(absf(drone.angular_velocity.y)),
						drone.global_position.distance_to(_mark)])
				_phase = 6
				_t = 0.0
		6:  # yaw must stop too
			if _t > 1.5:
				print("[flight] yaw rate 1.5 s after release: %.1f deg/s"
					% rad_to_deg(absf(drone.angular_velocity.y)))
				get_tree().quit()
