# Team and ownership

Three areas of roughly equal size, measured in lines of code (comments and
blank lines excluded, ~9,550 in total). Each person owns their area: they are
the one who can explain it, who reviews changes to it, and who presents it.

| Area | Owner | Size |
| --- | --- | --- |
| Aircraft, flight and VR piloting | Sanjeev | ~2,870 lines, 15 files |
| World, environment and hazard field | Vishnu | ~3,370 lines, 33 files |
| Sensors, mission and interface | Tejeshwar | ~3,310 lines, 15 files |

---

## Sanjeev - aircraft, flight and VR piloting

Everything about flying the drone and what it can do.

- **Flight models.** Arcade (stick is velocity) and flight sim (point the nose,
  RT to fly, LT to brake). Stick shaping, landing assist, obstacle braking.
- **Smoothness.** Physics interpolation, and a camera rig that reads the
  interpolated transform. The measured before/after is the strongest single
  slide in the deck.
- **Cameras.** Chase, close-follow and FPV nose cam, with wall clearance.
- **Autopilot.** Return-to-home onto the van, and point-of-interest orbit.
- **Payload.** First-aid kit drops under a parachute, credited to survivors.
- **Damage.** Impacts, blast and fire; motor degradation; crash and respawn.
- **Fuel drums and the explosion** - the one thing the operator can do *to* the
  site.
- **VR piloting.** The XR rig, controller mapping, haptics, comfort.
- **Flight test** (`--flighttest`) and the input map generator.

`scripts/drone/drone.gd`, `autopilot.gd`, `damage_model.gd`, `payload_bay.gd`,
`proximity_array.gd`, `scripts/camera/camera_rig.gd`, `scripts/xr/*`,
`scripts/world/supply_crate.gd`, `explosion.gd`, `explosive_barrel.gd`,
`scripts/main.gd`, `scripts/debug/flight_test.gd`, `scenes/drone.tscn`,
`tools/gen_project_godot.py`

**Be ready to explain:** why the camera jittered and why interpolation fixed
it; why both flight models command a velocity rather than simulating thrust;
how return-to-home lands within 0.08 m; why VR gets haptics instead of camera
shake.

---

## Vishnu - world, environment and hazard field

Everything about the place the drone flies through.

- **Terrain.** The crater, ejecta rim and rubble undulation, as one pure
  function everything else stands on.
- **The site as editable scenes.** Silos, warehouse, collapsed block, container
  yard, pipe corridor, crane, harbour, thirteen ruined buildings with a collapse
  slider, the staging area and response vehicles, props and signs - all
  draggable in the editor, re-seating on the terrain wherever they are dropped.
- **The city and the rubble field.** One-draw-call skyline, 900 pieces of
  debris in three.
- **Lighting and atmosphere.** Sky, sun and moon, four times of day, site
  lighting that switches on after dark, three graphics presets.
- **The water.**
- **The hazard field.** The physical model of the gas plumes and heat sources
  that every sensor reads from, and the fires and gas leaks placed in it.
- **Assets and audio.** The Poly Haven CC0 pipeline and the synthesised sound
  bank.

`scripts/world/world_builder.gd`, `terrain.gd`, `build_kit.gd`,
`site_piece.gd`, `scripts/world/pieces/*`, `materials.gd`, `vfx.gd`,
`beacon_light.gd`, `fire_source.gd`, `gas_source.gd`,
`scripts/autoload/hazards.gd`, `sfx.gd`, `shaders/water.gdshader`,
`terrain.gdshader`, `scenes/structures`, `scenes/staging`, `scenes/props`,
`scenes/hazards`, `tools/fetch_assets.py`, `make_audio.py`, `gen_main_scene.py`

**Be ready to explain:** how a building knows where the ground is when it is
dragged in the editor; why the skyline is a MultiMesh; how a gas plume is
modelled and why the turbulence is identical on the CPU and the GPU; why night
has to be genuinely dark.

---

## Tejeshwar - sensors, mission and interface

Everything about what the drone sees and what the operator does with it.

- **The four sensors.** EO, thermal (a radiometric temperature model of the
  whole site, six palettes, automatic gain, shutter calibration), low-light
  (auto-gated intensifier with IR illuminator) and the gas overlay - one
  full-screen shader, `vision_post.gdshader`.
- **The five-gas detector** and the air-sample trail.
- **Detection and tagging.** Confidence from range, angle, line of sight and
  sensor mode; the one-finding-per-contact rule.
- **Survivors.** The victim scene, poses, body-temperature heat model.
- **Mission.** Objectives, survey coverage, findings log, report export.
- **Interface.** HUD, settings menu, briefing, help, the VR wrist panel.
- **Self-test** (`--selftest`, 155 checks).

`shaders/vision_post.gdshader`, `scripts/camera/vision_post.gd`,
`thermal_palettes.gd`, `scripts/drone/gas_sensor.gd`, `gas_trail.gd`,
`target_detector.gd`, `scripts/world/victim.gd`, `detectable.gd`,
`hazard_beacon.gd`, `scripts/autoload/sim.gd`, `scripts/mission/*`,
`scripts/ui/*`, `scripts/debug/self_test.gd`, `scenes/victim.tscn`

**Be ready to explain:** why thermal finds a person in rubble that daylight
cannot; what the automatic gain window does and why it is narrow; why the
gas overlay and the detector can never disagree; how the self-test proves a
bug stays fixed.

---

## Before the demo - one task each

The split above describes who owns what. For it to be true, each person should
have genuinely worked in their area before presenting it. Three tasks that
matter and that nobody has done yet:

**Tejeshwar - fly it in a headset.** VR has never been flown on a physical
headset. The rig builds and passes the full self-test without one, but that
proves the code runs, not that it is comfortable or that every button lands
where the mapping says. With the headset connected: `vr_mode on`, launch, and
work through - every button in the README's VR table; the wrist panel's
readability; the frame rate in thermal (it should hold the headset's refresh
rate on the VR preset); comfort through a fast turn and a crash. Fix or report
what does not hold up. This is the largest open risk in the project.

**Vishnu - walk the site from the editor.** Open `main.tscn`, look at every
piece from the angles the demo will use, and fix anything that sits wrong:
a ruin clipping a structure, a drum floating, a survivor sunk into a slab.
Every piece is draggable and reseats itself, so this is quick.

**Sanjeev - rehearse the demo run.** Fly the demo path end to end on the
hardware it will be shown on, twice: once on Arcade, once on Flight Sim.
Time it. Decide which camera view each section is shown in.

Run `--selftest` before every push. It takes about 90 seconds.

---

## If you are asked about tools

The commit history records that parts of this project were written with an AI
coding assistant - every such commit carries a `Co-Authored-By` line. If your
course has a policy on AI use, declare it the way the policy asks; the history
is public and says so either way.
