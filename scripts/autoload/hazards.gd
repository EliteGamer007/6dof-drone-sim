extends Node
## The physical hazard field: gas plumes, heat sources and wind.
##
## Everything that needs to know "how much CO is at this point" or "how hot is
## this surface" asks here, including the thermal / gas post-process shader,
## which is fed the same description the CPU samples so the picture and the
## numbers can never disagree.
##
## The gas field has three layers, because that is what a detector flown
## through a real incident site actually records:
##
##   1. a diffuse background that is never quite zero and drifts with the wind,
##   2. dozens of plumes, most of them small, each one pulsing on its own
##      rhythm the way a leak or a smouldering pile does,
##   3. turbulence - wind-advected eddies that break every plume into puffs,
##      so flying through one gives a spiky trace instead of a smooth hill.
##
## The turbulence noise is an integer PCG hash, so the GDScript sampler and the
## GLSL shader produce bit-identical lattice values. A float sin() hash would
## drift between CPU (64-bit) and GPU (32-bit) at world coordinates this large.
##
## Autoloaded as `Hazards`.

# ------------------------------------------------------------- gas definitions

enum Gas { CO, H2S, NO2, LEL, O2 }

## What a heat source is. Drives how the auto-gain treats it and how the
## detector describes it.
enum HeatKind { GENERIC, FIRE, PERSON, MACHINE, SMOULDER, COLD }

const GAS_COUNT := 5

const GAS_NAMES := ["CO", "H2S", "NO2", "LEL", "O2"]
const GAS_LONG_NAMES := [
	"Carbon monoxide",
	"Hydrogen sulphide",
	"Nitrogen dioxide",
	"Combustible gas",
	"Oxygen",
]
const GAS_UNITS := ["ppm", "ppm", "ppm", "%LEL", "%vol"]

## Fresh-air baseline for each channel.
const GAS_BASELINE := [0.0, 0.0, 0.0, 0.0, 20.9]
## First alarm (occupational exposure level).
const GAS_ALARM_LOW := [35.0, 10.0, 1.0, 10.0, 19.5]
## Second alarm.
const GAS_ALARM_HIGH := [100.0, 15.0, 5.0, 20.0, 23.5]
## Immediately dangerous to life or health.
const GAS_IDLH := [1200.0, 100.0, 20.0, 100.0, 0.0]
## Full-scale value used by the HUD bars.
const GAS_FULL_SCALE := [500.0, 60.0, 25.0, 60.0, 25.0]

const GAS_COLORS := [
	Color(0.95, 0.45, 0.20),   # CO   - orange
	Color(0.85, 0.85, 0.25),   # H2S  - yellow
	Color(0.75, 0.35, 0.90),   # NO2  - violet
	Color(1.00, 0.30, 0.30),   # LEL  - red
	Color(0.35, 0.80, 1.00),   # O2   - blue
]

## Diffuse background amplitude per channel, in channel units. Sub-alarm by
## design: it keeps the readout alive without crying wolf.
const BACKGROUND := [6.5, 1.1, 0.55, 2.2, 0.0]
const BACKGROUND_FLOOR := [0.8, 0.0, 0.04, 0.0, 0.0]

# ------------------------------------------------------------------- constants

## Beirut in August, before any fire contribution.
const AMBIENT_TEMP_DAY := 29.0
const AMBIENT_TEMP_NIGHT := 22.5

## Shader upload limits. The registries can hold more; the closest to the
## camera are the ones sent.
const MAX_PLUMES := 48
const MAX_HEAT := 64

const TURBULENCE_SCALE := 0.14     ## eddies roughly 7 m across
const MASK32 := 0xFFFFFFFF

# ----------------------------------------------------------------------- state

var ambient_temp := AMBIENT_TEMP_DAY
var wind_direction := Vector3(1.0, 0.0, 0.35).normalized()
var wind_speed := 3.2          ## m/s
var wind_gust := 0.0           ## current gust offset, m/s
var time := 0.0                ## seconds, drives advection and intermittency
var epicentre := Vector3(0.0, 0.0, -12.0)

var plumes: Array[Dictionary] = []
var heat_sources: Array[Dictionary] = []

var _gust_noise := FastNoiseLite.new()

# Shader upload buffers, rebuilt when the reference point moves or on demand.
var _gas_a := PackedVector4Array()
var _gas_b := PackedVector4Array()
var _gas_c := PackedVector4Array()
var _heat_a := PackedVector4Array()
var _heat_b := PackedVector4Array()
var _heat_c := PackedVector4Array()
var _plume_count := 0
var _heat_count := 0
var _packed_frame := -1


func _ready() -> void:
	_gust_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_gust_noise.frequency = 0.08
	_gas_a.resize(MAX_PLUMES)
	_gas_b.resize(MAX_PLUMES)
	_gas_c.resize(MAX_PLUMES)
	_heat_a.resize(MAX_HEAT)
	_heat_b.resize(MAX_HEAT)
	_heat_c.resize(MAX_HEAT)


func _process(delta: float) -> void:
	time += delta
	# Gusts wander slowly; every plume axis follows them, so the clouds visibly
	# swing during a demo instead of standing still.
	wind_gust = _gust_noise.get_noise_1d(time * 0.6) * 2.4


# -------------------------------------------------------------- registration

## `minor` plumes carry the ambient texture of the site and are not reported
## as findings on their own; the major ones are Detectables with briefings.
func register_plume(node: Node3D, gas: int, strength: float, radius: float,
		length: float, spread: float = 1.6, minor := false) -> void:
	var seed := plumes.size() * 7919 + int(absf(node.global_position.x * 13.0)) \
		+ int(absf(node.global_position.z * 29.0))
	plumes.append({
		"node": node,
		"gas": gas,
		"strength": strength,
		"radius": radius,
		"length": length,
		"spread": spread,
		"minor": minor,
		# Every source breathes on its own rhythm: a leaking valve surges, a
		# smouldering pile flares and dies back.
		"phase": float(seed % 997) * 0.173,
		"period": 3.5 + float(seed % 13) * 0.9,
		"depth": 0.35 + float(seed % 7) * 0.07,
	})


## Point heat source, `delta_temp` above ambient. Kept for simple emitters.
func register_heat(node: Node3D, delta_temp: float, radius: float, kind: int = 0) -> void:
	register_heat_capsule(node, Vector3.ZERO, Vector3.ZERO, radius * 0.35,
		delta_temp, false, radius * 0.65, kind)


## Heat source shaped as a capsule in the node's local space.
##
## A person is registered as the same capsules their mesh is built from, so in
## the thermal image the warm shape *is* the body - head, torso, limbs - and
## not a round blob hovering over it.
##
##   temp      absolute surface temperature if `absolute`, else delta over ambient
##   halo      metres of warm fringe outside the surface (conduction, reflection)
func register_heat_capsule(node: Node3D, a: Vector3, b: Vector3, radius: float,
		temp: float, absolute := true, halo := 0.12, kind: int = 0) -> void:
	heat_sources.append({
		"node": node,
		"a": a,
		"b": b,
		"radius": maxf(radius, 0.01),
		"temp": temp,
		"absolute": absolute,
		"halo": maxf(halo, 0.02),
		"kind": kind,
	})


func unregister(node: Node3D) -> void:
	plumes = plumes.filter(func(p): return p.node != node)
	heat_sources = heat_sources.filter(func(h): return h.node != node)


func clear_all() -> void:
	plumes.clear()
	heat_sources.clear()


# -------------------------------------------------------------------- noise

## PCG hash. Mirrors `pcg()` in vision_post.gdshader exactly.
static func _pcg(v: int) -> int:
	var state := (v * 747796405 + 2891336453) & MASK32
	var word := (((state >> ((state >> 28) + 4)) ^ state) * 277803737) & MASK32
	return ((word >> 22) ^ word) & MASK32


static func _hash3(x: int, y: int, z: int) -> float:
	var h := _pcg(((x & MASK32) + _pcg(((y & MASK32) + _pcg(z & MASK32)) & MASK32)) & MASK32)
	return float(h) / 4294967295.0


static func _fade(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


static func value_noise3(p: Vector3) -> float:
	var ix := int(floor(p.x))
	var iy := int(floor(p.y))
	var iz := int(floor(p.z))
	var fx := _fade(p.x - floor(p.x))
	var fy := _fade(p.y - floor(p.y))
	var fz := _fade(p.z - floor(p.z))
	var c000 := _hash3(ix, iy, iz)
	var c100 := _hash3(ix + 1, iy, iz)
	var c010 := _hash3(ix, iy + 1, iz)
	var c110 := _hash3(ix + 1, iy + 1, iz)
	var c001 := _hash3(ix, iy, iz + 1)
	var c101 := _hash3(ix + 1, iy, iz + 1)
	var c011 := _hash3(ix, iy + 1, iz + 1)
	var c111 := _hash3(ix + 1, iy + 1, iz + 1)
	var x00 := lerpf(c000, c100, fx)
	var x10 := lerpf(c010, c110, fx)
	var x01 := lerpf(c001, c101, fx)
	var x11 := lerpf(c011, c111, fx)
	return lerpf(lerpf(x00, x10, fy), lerpf(x01, x11, fy), fz)


## Where the afternoon sun sat: the faces that saw it are the ones still
## holding heat after sunset. Matches AFTERNOON_SUN in vision_post.gdshader.
const AFTERNOON_SUN := Vector3(-0.55, 0.62, 0.56)

const SOLAR_GAIN := 6.5
const SOLAR_STORAGE := 4.2
const SKY_COOLING := 3.6
const THERMAL_MASS_GAIN := 3.2
const GROUND_LAPSE := 0.055
const CRATER_HEAT := 2.0


## Ground-temperature patchiness. Mirrors thermal_patch() in the shader, using
## the same PCG value noise, so the number under the reticle agrees with the
## colour the operator is looking at.
func thermal_patch(p: Vector3) -> float:
	var a := value_noise3(Vector3(p.x * 0.042, 0.0, p.z * 0.042))
	var b := value_noise3(Vector3(p.x * 0.155 + 31.7, 0.0, p.z * 0.155 - 11.3))
	return (a - 0.5) * 1.9 + (b - 0.5) * 0.85


## Surface temperature of the environment before any heat source is applied.
## Mirrors environment_temperature() in vision_post.gdshader.
##
## `albedo` is the surface's rough reflectance; 0.42 is the neutral value that
## contributes nothing, so callers without a real albedo can leave it alone.
func environment_temperature(p: Vector3, normal: Vector3, albedo := 0.42,
		distance := 0.0) -> float:
	var t := ambient_temp
	t += maxf(normal.dot(AFTERNOON_SUN.normalized()), 0.0) \
		* SOLAR_STORAGE * (1.0 - Sim.daylight * 0.45)
	t += maxf(normal.dot(-Sim.sun_direction), 0.0) * SOLAR_GAIN * Sim.daylight
	t -= maxf(normal.y, 0.0) * SKY_COOLING * (1.0 - Sim.daylight * 0.7)
	t += (0.42 - albedo) * THERMAL_MASS_GAIN * clampf(Sim.daylight * 2.2, 0.0, 1.0)
	t -= clampf(p.y * GROUND_LAPSE, 0.0, 2.8)
	t += CRATER_HEAT * exp(-Vector2(p.x - epicentre.x, p.z - epicentre.z).length() / 46.0)
	t += thermal_patch(p)
	return lerpf(t, ambient_temp, clampf(distance / 480.0, 0.0, 0.7))


## Two-octave fbm of the wind-advected position, in [0, 1].
func fbm(p: Vector3) -> float:
	return value_noise3(p) * 0.65 + value_noise3(p * 2.03 + Vector3(17.0, 9.0, 3.0)) * 0.35


## Eddy field: the same function the shader evaluates for the overlay.
func turbulence(p: Vector3) -> float:
	var q := (p - current_wind() * time) * TURBULENCE_SCALE
	return clampf(0.25 + 1.1 * fbm(q), 0.08, 1.45)


## 1D breathing curve for a plume's intermittency.
func _pulse(phase: float) -> float:
	var i := floorf(phase)
	var f := _fade(phase - i)
	return lerpf(_hash3(int(i), 7, 3), _hash3(int(i) + 1, 7, 3), f)


func plume_strength(plume: Dictionary) -> float:
	var p := _pulse(time / float(plume.period) + float(plume.phase))
	return float(plume.strength) * (1.0 - float(plume.depth) + float(plume.depth) * p * 1.4)


# ------------------------------------------------------------------ sampling

func current_wind() -> Vector3:
	return wind_direction * (wind_speed + wind_gust)


## Distance from `p` to a plume's capsule axis, plus the radius at that point.
func _plume_distance(p: Vector3, origin: Vector3, axis: Vector3,
		radius: float, spread: float) -> Vector2:
	var len_sq := axis.length_squared()
	var t := 0.0
	if len_sq > 0.0001:
		t = clampf((p - origin).dot(axis) / len_sq, 0.0, 1.0)
	var closest := origin + axis * t
	return Vector2(p.distance_to(closest), radius * (1.0 + t * spread))


## Concentration of every channel at a world point.
func sample_gas(p: Vector3) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GAS_COUNT)

	# Layer 1: diffuse background, each channel on its own offset of the same
	# advected field so they do not all rise and fall together.
	var q := (p - current_wind() * time) * (TURBULENCE_SCALE * 0.35)
	var near_seat: float = exp(-p.distance_to(epicentre) / 110.0)
	for i in GAS_COUNT - 1:
		var n := fbm(q + Vector3(float(i) * 31.7, float(i) * 11.3, float(i) * 23.9))
		var amp: float = BACKGROUND[i]
		if i == Gas.NO2:
			amp *= 0.35 + 1.6 * near_seat   # residual detonation products
		out[i] = BACKGROUND_FLOOR[i] + amp * n * n * 1.6

	# Layers 2 and 3: plumes, broken up by the shared eddy field.
	var turb := turbulence(p)
	var wind := current_wind()
	var wind_dir := wind.normalized()
	var dilution: float = 1.0 / (1.0 + wind.length() * 0.06)
	var displaced := 0.0
	var o2_drop := 0.0
	for plume in plumes:
		var node: Node3D = plume.node
		if not is_instance_valid(node):
			continue
		var origin: Vector3 = node.global_position
		# cheap reject before the capsule maths
		var reach: float = float(plume.length) + float(plume.radius) * (3.0 + float(plume.spread) * 3.0)
		if p.distance_squared_to(origin) > reach * reach:
			continue
		var axis: Vector3 = wind_dir * float(plume.length)
		var dr := _plume_distance(p, origin, axis, plume.radius, plume.spread)
		var falloff: float = exp(-(dr.x * dr.x) / (2.0 * maxf(dr.y * dr.y, 0.01)))
		# the core near the source is dense and steady; eddies take over downwind
		var core: float = exp(-p.distance_to(origin) / maxf(float(plume.radius) * 1.5, 0.3))
		var patchiness: float = lerpf(turb, 1.0, core)
		var amount: float = plume_strength(plume) * falloff * dilution * patchiness
		var gas: int = plume.gas
		if gas == Gas.O2:
			# an oxygen "plume" is a pocket of inert gas; its strength is the
			# drop in %vol O2 at the core
			o2_drop += amount
			continue
		out[gas] += amount
		displaced += amount / maxf(GAS_IDLH[gas], 1.0)

	# Heavy gas displaces breathable oxygen; the background wobbles it slightly.
	var o2_wobble := (fbm(q + Vector3(91.0, 5.0, 47.0)) - 0.5) * 0.18
	out[Gas.O2] = clampf(GAS_BASELINE[Gas.O2] + o2_wobble - displaced * 4.0 - o2_drop,
		4.0, 23.5)
	return out


## Surface temperature at `p` after every heat source has been applied to an
## environment temperature (ambient air unless the caller knows better).
## Matches `apply_heat()` in the shader: warm sources only raise, cold sources
## only lower.
func sample_temperature(p: Vector3, env: float = NAN) -> float:
	var t: float = ambient_temp if is_nan(env) else env
	for h in heat_sources:
		var node: Node3D = h.node
		if not is_instance_valid(node):
			continue
		var a: Vector3 = node.global_transform * (h.a as Vector3)
		var b: Vector3 = node.global_transform * (h.b as Vector3)
		var ab := b - a
		var seg_t := 0.0
		if ab.length_squared() > 1e-6:
			seg_t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d: float = p.distance_to(a + ab * seg_t) - float(h.radius)
		var halo: float = h.halo
		if d > halo * 4.0:
			continue
		var w: float = exp(-pow(maxf(d, 0.0), 2.0) / (2.0 * halo * halo))
		var ts: float = h.temp if h.absolute else ambient_temp + float(h.temp)
		if int(h.kind) == HeatKind.COLD:
			t = lerpf(t, minf(t, ts), w)
		else:
			t = lerpf(t, maxf(t, ts), w)
	return t


## Worst alarm level reached by a reading set: 0 clear, 1 low, 2 high, 3 IDLH.
func alarm_level(readings: PackedFloat32Array) -> int:
	var worst := 0
	for i in GAS_COUNT:
		worst = maxi(worst, channel_alarm_level(i, readings[i]))
	return worst


func channel_alarm_level(gas: int, value: float) -> int:
	if gas == Gas.O2:
		if value <= 17.0:
			return 3
		if value <= GAS_ALARM_LOW[Gas.O2] or value >= GAS_ALARM_HIGH[Gas.O2]:
			return 2
		if value <= 20.0:
			return 1
		return 0
	if GAS_IDLH[gas] > 0.0 and value >= GAS_IDLH[gas]:
		return 3
	if value >= GAS_ALARM_HIGH[gas]:
		return 2
	if value >= GAS_ALARM_LOW[gas]:
		return 1
	return 0


## Fraction of the way to full scale, for bar fill and beep rate.
func normalised(gas: int, value: float) -> float:
	if gas == Gas.O2:
		return clampf((GAS_BASELINE[Gas.O2] - value) / 4.0, 0.0, 1.0)
	return clampf(value / maxf(GAS_FULL_SCALE[gas], 0.001), 0.0, 1.0)


## A single 0..1+ "how bad is the air here" index across every channel,
## relative to each channel's first alarm. Drives the flight-path trail and the
## survey gas map.
func hazard_index(readings: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in GAS_COUNT:
		var v := readings[i]
		var idx := 0.0
		if i == Gas.O2:
			idx = clampf((GAS_BASELINE[i] - v) / (GAS_BASELINE[i] - GAS_ALARM_LOW[i]), 0.0, 3.0)
		else:
			idx = v / maxf(GAS_ALARM_LOW[i], 0.001)
		worst = maxf(worst, idx)
	return worst


# ------------------------------------------------------- shader packing

## Uploads the field to a post-process material. Only the sources nearest
## `reference` are sent - the registries can be far larger than a uniform
## array - so a camera anywhere on site always sees its local hazards.
func apply_to_material(mat: ShaderMaterial, reference: Vector3) -> void:
	var frame := Engine.get_process_frames()
	if frame != _packed_frame:
		_repack(reference)
		_packed_frame = frame
	mat.set_shader_parameter("gas_a", _gas_a)
	mat.set_shader_parameter("gas_b", _gas_b)
	mat.set_shader_parameter("gas_c", _gas_c)
	mat.set_shader_parameter("gas_count", _plume_count)
	mat.set_shader_parameter("heat_a", _heat_a)
	mat.set_shader_parameter("heat_b", _heat_b)
	mat.set_shader_parameter("heat_c", _heat_c)
	mat.set_shader_parameter("heat_count", _heat_count)
	mat.set_shader_parameter("ambient_temp", ambient_temp)
	mat.set_shader_parameter("wind", current_wind())
	mat.set_shader_parameter("sim_time", time)


func _repack(reference: Vector3) -> void:
	var wind_dir := current_wind().normalized()

	# --- plumes, nearest first ----------------------------------------------
	var order: Array = []
	for plume in plumes:
		var node: Node3D = plume.node
		if is_instance_valid(node):
			order.append([node.global_position.distance_squared_to(reference), plume])
	order.sort_custom(func(x, y): return x[0] < y[0])

	var i := 0
	for entry in order:
		if i >= MAX_PLUMES:
			break
		var plume: Dictionary = entry[1]
		var origin: Vector3 = (plume.node as Node3D).global_position
		var axis: Vector3 = wind_dir * float(plume.length)
		_gas_a[i] = Vector4(origin.x, origin.y, origin.z, plume.radius)
		# oxygen pockets are a few %vol deep - scale them up so the overlay can
		# draw a deficient void at a visible strength
		var display: float = plume_strength(plume) * (6.0 if int(plume.gas) == Gas.O2 else 1.0)
		_gas_b[i] = Vector4(axis.x, axis.y, axis.z, display)
		_gas_c[i] = Vector4(float(plume.gas), plume.spread,
			maxf(GAS_FULL_SCALE[plume.gas], 0.001), 0.0)
		i += 1
	for j in range(i, MAX_PLUMES):
		_gas_a[j] = Vector4.ZERO
		_gas_b[j] = Vector4.ZERO
		_gas_c[j] = Vector4.ZERO
	_plume_count = i

	# --- heat capsules, nearest first ---------------------------------------
	var horder: Array = []
	for h in heat_sources:
		var node: Node3D = h.node
		if is_instance_valid(node):
			horder.append([node.global_position.distance_squared_to(reference), h])
	horder.sort_custom(func(x, y): return x[0] < y[0])

	var k := 0
	for entry in horder:
		if k >= MAX_HEAT:
			break
		var h: Dictionary = entry[1]
		var node: Node3D = h.node
		var a: Vector3 = node.global_transform * (h.a as Vector3)
		var b: Vector3 = node.global_transform * (h.b as Vector3)
		var temp: float = h.temp if h.absolute else ambient_temp + float(h.temp)
		_heat_a[k] = Vector4(a.x, a.y, a.z, h.radius)
		_heat_b[k] = Vector4(b.x, b.y, b.z, temp)
		_heat_c[k] = Vector4(h.halo, float(h.kind), 0.0, 0.0)
		k += 1
	for j in range(k, MAX_HEAT):
		_heat_a[j] = Vector4.ZERO
		_heat_b[j] = Vector4.ZERO
		_heat_c[j] = Vector4.ZERO
	_heat_count = k
