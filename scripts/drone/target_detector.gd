class_name TargetDetector
extends Node3D
## On-board detection pipeline: decides what the payload can currently "see",
## how sure it is, and pushes that to the HUD and the world-space markers.
##
## Confidence is built from range, how far off-boresight the contact is,
## whether there is a clear line of sight, and how much the active sensor mode
## helps. Thermal genuinely doubles the odds of finding a person in rubble,
## which is the point the demo needs to make.

signal detections_changed(detections: Array)
signal target_acquired(target: Detectable)

@export var scan_interval := 0.12
@export var confidence_threshold := 0.45
@export var log_threshold := 0.72
@export var hold_time_to_log := 1.1        ## seconds above threshold before logging

var detections: Array[Dictionary] = []     ## {target, confidence, distance, screen_pos}
var focused: Detectable = null             ## contact nearest the reticle
var _accumulator := 0.0
var _hold := {}


func _physics_process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < scan_interval:
		return
	_accumulator = 0.0
	_scan(delta)


func _scan(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	var body := get_parent() as PhysicsBody3D
	if body:
		exclude.append(body.get_rid())

	var results: Array[Dictionary] = []
	var best_focus_score := -1.0
	var new_focus: Detectable = null
	var cam_pos := camera.global_position
	var cam_fwd := -camera.global_basis.z

	for node in get_tree().get_nodes_in_group("detectable"):
		var target := node as Detectable
		if target == null or not is_instance_valid(target):
			continue

		var to_target := target.global_position - cam_pos
		var distance := to_target.length()
		if distance > target.max_detect_range or distance < 0.05:
			continue

		var dir := to_target / distance
		var boresight := dir.dot(cam_fwd)
		if boresight <= 0.25:                      # behind us or far off-axis
			continue
		if not camera.is_position_in_frustum(target.global_position):
			continue

		var clear_los := true
		if target.requires_line_of_sight:
			var params := PhysicsRayQueryParameters3D.create(cam_pos,
				target.global_position)
			params.exclude = exclude
			var hit := space.intersect_ray(params)
			if not hit.is_empty():
				var hit_node: Object = hit.collider
				# a hit on the target's own body still counts as visible
				clear_los = hit_node != null and (hit_node == target
					or target.is_ancestor_of(hit_node)
					or hit.position.distance_to(target.global_position)
						< target.detection_radius * 1.6)

		var range_score := clampf(1.0 - distance / target.max_detect_range, 0.0, 1.0)
		var angle_score := smoothstep(0.25, 0.9, boresight)
		var confidence := (0.35 + 0.45 * range_score + 0.20 * angle_score)
		confidence *= target.sensor_advantage(Sim.vision_mode)
		if not clear_los:
			# A partial return through debris, not a blind spot. This used to be
			# 0.28, which pushed anything behind a pipe or a slab below the
			# display threshold entirely - so a survivor you could plainly see
			# through a gap simply was not there as far as the payload was
			# concerned.
			confidence *= 0.45
		confidence = clampf(confidence, 0.0, 0.99)

		if confidence < confidence_threshold:
			_hold.erase(target.get_instance_id())
			target.detected = false
			continue

		var screen_pos := camera.unproject_position(target.global_position)
		results.append({
			"target": target,
			"confidence": confidence,
			"distance": distance,
			"screen_pos": screen_pos,
			"clear_los": clear_los,
		})

		target.detected = true
		target.best_confidence = maxf(target.best_confidence, confidence)

		var focus_score := boresight * 4.0 - distance * 0.01
		if focus_score > best_focus_score:
			best_focus_score = focus_score
			new_focus = target

		_accumulate_hold(target, confidence)

	focused = new_focus
	detections = results
	detections_changed.emit(detections)


func _accumulate_hold(target: Detectable, confidence: float) -> void:
	var id := target.get_instance_id()
	if confidence < log_threshold:
		_hold.erase(id)
		return
	var held: float = float(_hold.get(id, 0.0)) + scan_interval
	_hold[id] = held
	if held < hold_time_to_log:
		return
	if target.finding_id != 0 or not target.auto_log:
		return

	# First confirmed sighting - log it, ping the operator, and drop a beacon.
	var extra := {
		"detail": target.detail,
		"action": target.recommended_action,
		"confidence": confidence,
		"auto": true,
	}
	if target is GasSource:
		extra["gas"] = (target as GasSource).gas
	var finding := Sim.log_finding(
		target.kind,
		"%s (%d%% confidence)" % [target.label, int(confidence * 100.0)],
		target.severity,
		target.global_position,
		target.contact_key(),
		extra)
	target.finding_id = finding.id
	target.first_detected_at = Sim.mission_time
	target.mark_tagged()
	Sfx.play("detect_ping", -5.0, 1.0, 0.4)
	target_acquired.emit(target)


func detection_for(target: Detectable) -> Dictionary:
	for d in detections:
		if d.target == target:
			return d
	return {}
