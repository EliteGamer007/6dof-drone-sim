@tool
class_name WindMast
extends SitePiece
## A windsock at the staging area. The plumes drift downwind, so knowing which
## way the wind is blowing is the difference between flying round a cloud and
## flying through it - and the HUD readout needs something in the world that
## agrees with it. The sock points downwind and lifts with the wind speed:
## hanging in still air, flat out at 8 m/s.

var _sock: MeshInstance3D


func _build() -> void:
	var g := ground(0.0, 0.0)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.72, 0.74, 0.76)
	steel.metallic = 0.7
	steel.roughness = 0.35
	slab(Vector3(0.10, 6.0, 0.10), Vector3(0.0, g + 3.0, 0.0), Vector3.ZERO, steel)

	var sock_mat := StandardMaterial3D.new()
	sock_mat.albedo_color = Color(0.96, 0.45, 0.06)
	sock_mat.roughness = 0.9
	sock_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cone := CylinderMesh.new()
	cone.top_radius = 0.42
	cone.bottom_radius = 0.16
	cone.height = 2.2
	cone.radial_segments = 12

	_sock = MeshInstance3D.new()
	_sock.name = "Windsock"
	_sock.mesh = cone
	_sock.material_override = sock_mat
	_sock.position = Vector3(0.0, g + 5.7, 0.0)
	_sock.rotation_degrees = Vector3(70.0, 0.0, 0.0)
	_sock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_generated(_sock)


func _process(_delta: float) -> void:
	if not is_runtime() or _sock == null or not is_instance_valid(_sock):
		return
	var wind := Hazards.current_wind()
	var speed := wind.length()
	if speed < 0.05:
		return
	var dir := wind / speed
	var lift := deg_to_rad(lerpf(20.0, 90.0, clampf(speed / 8.0, 0.0, 1.0)))
	_sock.global_basis = Basis(Vector3.UP, atan2(dir.x, dir.z)) * Basis(Vector3.RIGHT, lift)
