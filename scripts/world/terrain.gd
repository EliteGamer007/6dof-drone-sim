class_name Terrain
extends RefCounted
## The ground, as a pure function of position.
##
## Everything that has to sit on the ground asks this - the terrain mesh, the
## prop scatter, and every hand-placed scene piece in the editor. It needs no
## scene tree and no physics, which is what lets a building dragged around in
## the editor re-seat itself on the rubble wherever it is dropped.

const EPICENTRE := Vector2(0.0, -12.0)
const CRATER_RADIUS := 58.0
const CRATER_DEPTH := 9.5
const PAD_CENTRE := Vector2(0.0, 96.0)


## Crater bowl, ejecta rim, rubble undulation and a flattened launch pad.
static func height(x: float, z: float) -> float:
	var d := Vector2(x - EPICENTRE.x, z - EPICENTRE.y).length()
	var h := 0.0

	# crater bowl with a raised rim of ejecta
	if d < CRATER_RADIUS:
		var t := d / CRATER_RADIUS
		h -= CRATER_DEPTH * (1.0 - t * t) * (1.0 - t * 0.35)
	var rim := exp(-pow((d - CRATER_RADIUS * 1.06) / 22.0, 2.0))
	h += rim * 3.2

	# general rubble undulation, heavier close in
	var rubble_weight := clampf(1.4 - d / 150.0, 0.25, 1.4)
	h += fbm(Vector2(x, z) * 0.035) * 2.1 * rubble_weight
	h += fbm(Vector2(x, z) * 0.14 + Vector2(19.0, 7.0)) * 0.55 * rubble_weight

	# flatten the launch pad so the drone starts on something sane
	var pad := exp(-pow(Vector2(x, z).distance_to(PAD_CENTRE) / 14.0, 2.0))
	return lerpf(h, 0.35, clampf(pad, 0.0, 0.92))


static func fbm(p: Vector2) -> float:
	var total := 0.0
	var amp := 1.0
	var freq := 1.0
	var norm := 0.0
	for i in 4:
		total += value_noise(p * freq) * amp
		norm += amp
		amp *= 0.5
		freq *= 2.07
	return (total / norm) * 2.0 - 1.0


static func value_noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := hash2(i)
	var b := hash2(i + Vector2(1.0, 0.0))
	var c := hash2(i + Vector2(0.0, 1.0))
	var d := hash2(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)


static func hash2(p: Vector2) -> float:
	return fposmod(sin(p.x * 127.1 + p.y * 311.7) * 43758.5453, 1.0)
