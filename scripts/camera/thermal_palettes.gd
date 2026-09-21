class_name ThermalPalettes
extends RefCounted
## Colour look-up tables for the thermal channel.
##
## Held in one place and handed to both the post-process shader (as a 1D
## texture) and the HUD legend (as the same Gradient), so the scale drawn on
## screen is always exactly the scale the image is using.
##
## The stops are modelled on the LUTs radiometric cameras actually ship with.
## The important property they share is that the bottom third of the range is
## dark: a real thermal image of a scene at ambient temperature is mostly
## shadow, and only the things that are genuinely warmer than their
## surroundings climb into colour. The earlier version of this project spread
## the scene across the middle of the palette, which is why everything read as
## one bright pink wash.

## Isotherm band used by the ALERT palette - skin and clothed-body surface
## temperatures. Anything in this range is painted; everything else is grey.
const PERSON_BAND := Vector2(28.5, 39.0)

static var _textures := {}
static var _gradients := {}


static func gradient(palette: int) -> Gradient:
	if _gradients.has(palette):
		return _gradients[palette]
	var g := Gradient.new()
	var stops: Array = _stops(palette)
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for stop in stops:
		g.add_point(stop[0], stop[1])
	# Gradient.new() starts with two default points at 0 and 1; drop them.
	while g.get_point_count() > stops.size():
		g.remove_point(0)
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CUBIC
	g.interpolation_color_space = Gradient.GRADIENT_COLOR_SPACE_OKLAB
	_gradients[palette] = g
	return g


static func texture(palette: int) -> GradientTexture1D:
	if _textures.has(palette):
		return _textures[palette]
	var t := GradientTexture1D.new()
	t.gradient = gradient(palette)
	t.width = 256
	_textures[palette] = t
	return t


static func sample(palette: int, v: float) -> Color:
	return gradient(palette).sample(clampf(v, 0.0, 1.0))


static func _stops(palette: int) -> Array:
	match palette:
		Sim.ThermalPalette.WHITE_HOT:
			# Slightly lifted blacks and a gentle toe - the look of a real
			# white-hot core rather than a pure linear ramp.
			return [
				[0.00, Color(0.015, 0.017, 0.020)],
				[0.35, Color(0.20, 0.205, 0.21)],
				[0.70, Color(0.62, 0.62, 0.62)],
				[1.00, Color(0.98, 0.98, 0.96)],
			]
		Sim.ThermalPalette.BLACK_HOT:
			return [
				[0.00, Color(0.93, 0.93, 0.92)],
				[0.35, Color(0.72, 0.72, 0.72)],
				[0.70, Color(0.32, 0.32, 0.33)],
				[1.00, Color(0.02, 0.02, 0.03)],
			]
		Sim.ThermalPalette.ARCTIC:
			return [
				[0.00, Color(0.01, 0.01, 0.04)],
				[0.18, Color(0.02, 0.06, 0.20)],
				[0.40, Color(0.05, 0.22, 0.45)],
				[0.55, Color(0.28, 0.45, 0.58)],
				[0.68, Color(0.78, 0.62, 0.28)],
				[0.84, Color(0.98, 0.80, 0.36)],
				[1.00, Color(1.00, 0.98, 0.90)],
			]
		Sim.ThermalPalette.LAVA:
			return [
				[0.00, Color(0.00, 0.02, 0.03)],
				[0.20, Color(0.02, 0.12, 0.16)],
				[0.40, Color(0.18, 0.10, 0.30)],
				[0.58, Color(0.62, 0.06, 0.18)],
				[0.74, Color(0.93, 0.28, 0.05)],
				[0.88, Color(1.00, 0.66, 0.12)],
				[1.00, Color(1.00, 0.97, 0.82)],
			]
		Sim.ThermalPalette.ALERT:
			# The underlay for the isotherm mode. The band itself is coloured in
			# the shader, keyed on absolute temperature rather than position in
			# the palette, so it means the same thing at any gain setting.
			return [
				[0.00, Color(0.02, 0.02, 0.025)],
				[0.50, Color(0.26, 0.26, 0.27)],
				[1.00, Color(0.72, 0.72, 0.72)],
			]
		_:
			# Ironbow, after the FLIR LUT: black, navy, indigo, violet, then
			# the warm end reserved for things that are actually warm.
			return [
				[0.00, Color(0.00, 0.00, 0.02)],
				[0.12, Color(0.03, 0.01, 0.16)],
				[0.28, Color(0.16, 0.02, 0.36)],
				[0.42, Color(0.38, 0.03, 0.46)],
				[0.54, Color(0.64, 0.07, 0.40)],
				[0.65, Color(0.86, 0.22, 0.18)],
				[0.76, Color(0.97, 0.47, 0.05)],
				[0.87, Color(1.00, 0.76, 0.16)],
				[1.00, Color(1.00, 0.98, 0.88)],
			]


## Colour of the isotherm band at a given absolute temperature, for the legend.
static func alert_colour(temp: float) -> Color:
	var t := clampf((temp - PERSON_BAND.x) / (PERSON_BAND.y - PERSON_BAND.x), 0.0, 1.0)
	return Color(1.0, 0.88, 0.22).lerp(Color(1.0, 0.36, 0.08), t)
