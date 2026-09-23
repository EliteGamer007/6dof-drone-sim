# Beirut Port SAR Drone Simulator

A VR search-and-rescue drone simulation over a post-blast industrial zone,
built in Godot 4.5. You fly the first aircraft into a sector nobody can enter on
foot: find the survivors, map the atmosphere, and flag what is about to fall on
the rescue teams.

The scenario is an educational reconstruction referencing the 2020 Port of
Beirut explosion. It is a teaching model, not a forensic reproduction of that
event.

---

## Presentation brief

Everything whoever builds the slides needs: what the project is, what it is
built with, and what to show - in slide order, with the numbers to quote.
Screenshots referenced below are in `docs/screenshots/`. Who owns which part is
in [docs/TEAM.md](docs/TEAM.md).

### 1. Title

**Beirut Port SAR Drone Simulator** - a search-and-rescue drone simulation,
flat screen and VR, built in Godot 4.5.

### 2. The problem

On 4 August 2020, 2,750 tonnes of ammonium nitrate detonated at the Port of
Beirut. In the first hours after a blast like that, nobody can safely walk into
the site. The collapse is unstable, the air may be toxic or explosive, and
fires are still burning. Someone has to find out where the survivors are, what
is in the air, and what is about to fall - before rescuers go in.

That is the job a survey drone does, and it is the job this simulator trains.

### 3. What we built

A drone flight simulator set in a reconstructed, post-blast port, with the
sensor payload a real search drone carries. The operator flies in, finds and
tags six survivors, identifies the gas hazards, flags unstable structures,
surveys the zone, and drops first-aid kits - then brings the aircraft home.

Show: `02-site-overview.png`, `01-launch-from-the-van.png`

### 4. Technology

| | |
| --- | --- |
| Engine | **Godot 4.5**, Forward+ renderer |
| Language | **GDScript** - 53 scripts, ~9,550 lines |
| Shaders | **Godot shading language (GLSL-based)** - 4 shaders: all four sensor modes in one post-process, water, terrain, VR comfort vignette |
| VR | **OpenXR** - Quest and Index-class headsets, tethered PCVR |
| 3D assets | **Poly Haven** (CC0): 39 models, 13 PBR material sets, 3 HDRI skies; DJI FPV airframe model |
| Audio | 17 sounds, **synthesised from scratch** in Python - no sample libraries |
| Tooling | **Python** - asset fetcher, audio synthesis, input-map generator, scene layout |
| Testing | Two automated harnesses that run headless: a 155-check self-test and a flight test |
| Version control | **Git / GitHub** - clone and run, every asset included |

### 5. Architecture

```
            Sim (autoload)          Hazards (autoload)
      state, findings, settings     the physical world: gas plumes,
                |                   heat sources, wind, turbulence
                |                          |
    +-----------+-----------+   +----------+-----------+
    |                       |   |                      |
  Drone                   HUD & menus            Sensor post-process
  flight models,          objectives,            EO / thermal / NV / gas
  autopilot, payload,     report, settings       (one shader, reads the
  damage, sensors                                 same field as the detector)
    |
  Camera rig / VR rig  ----- interpolated transform, every frame

  World: terrain function  +  editable scene pieces (buildings, vehicles,
         hazards, survivors) placed in scenes/main.tscn
```

The design point to make: **there is one hazard field.** The thermal image,
the gas overlay, the five-gas detector readings and the damage the aircraft
takes from fire all come from the same model. The picture and the numbers
cannot disagree.

### 6. The aircraft

- **Two flight models**, switchable in settings. *Arcade:* the stick is a
  velocity - it goes where you push it and stops when you let go. *Flight
  sim:* point the nose with the left stick (inverted - pull back to climb), RT to accelerate, LT to brake.
- **Smooth at any frame rate.** The drone moves at 60 Hz physics; the screen
  draws at 144 Hz. Physics interpolation plus a camera that reads the
  interpolated position. Measured: camera speed varies <0.6% frame to frame,
  zero stalled frames. Without it: 55% of frames frozen. *This before/after is
  worth its own slide.*
- **Three cameras:** chase, close-follow, FPV nose cam.
- **Autopilot:** return-to-home lands on the van from 75 m within 0.08 m;
  orbit circles a survivor holding its radius to 0.01 m.
- **Payload:** four first-aid kits, dropped under a parachute, credited to the
  survivor they land beside.
- **Damage:** impacts, blasts and fire cost integrity and motor power; the
  airframe wobbles and slows; at zero it falls and a spare launches.

Show: `06-fpv-nose-cam.png`

### 7. The sensors

| Mode | What it shows | Why it matters |
| --- | --- | --- |
| **EO** | the daylight camera | structure - but a grey person in grey rubble is invisible |
| **Thermal** | a radiometric temperature model of the entire site: sun-warmed walls, sky-cooled ground, residual heat in the crater, cold water | body heat against cooling rubble: this is what finds people |
| **Low-light** | an auto-gated image intensifier with an IR illuminator | voids, and anything after dark |
| **Gas overlay** | invisible gas plumes, painted in false colour | lets the pilot fly *around* a cloud instead of through it |

Plus a **five-gas detector** - CO, H2S, NO2, combustible gas and oxygen - with
two-stage alarms at occupational exposure levels (CO 35 / 100 ppm, H2S 10 /
15 ppm, NO2 1 / 5 ppm, flammable 10 / 20 % LEL, O2 below 19.5 %).

Show: `03-thermal-finds-survivor.png`, `04-night-vision.png`,
`05-gas-overlay.png`

### 8. The site

- A procedural terrain with the blast crater at its centre.
- The grain silos, a warehouse, a pancaked building, a container yard, a pipe
  corridor, a collapsed quay crane, the harbour - and thirteen ruined city
  blocks on a collapse slider, from intact shell to flattened.
- A response: the van the drone launches from, an ambulance, a fire engine, a
  casualty collection point, and a coned access route with the wall panel that
  blocks it.
- 6 survivors, 6 named gas leaks across 5 gases, 3 fires, 48 background gas
  sources, 38 fuel drums that can be detonated.
- Four times of day and three graphics presets. Night is genuinely dark: the
  site lights come on and the other sensors earn their place.
- **Every piece is its own scene.** Open `main.tscn` in Godot and the whole
  site is in the scene tree - drag a building and it re-seats itself on the
  terrain. 23 scenes, 119 placed nodes.

### 9. The mission

Five objectives: tag every survivor; identify each gas hazard; survey 35% of
the zone; flag unstable structures; drop first-aid kits. Tagging is
deliberate - the operator puts the reticle on a contact and confirms it; each
contact can only ever be logged once. The mission ends with an after-action
report exportable to CSV, with GPS coordinates for every finding.

### 10. VR

Full OpenXR support. The operator's head is the camera gimbal: look at a
survivor and pull the trigger to tag them. The gas readout is on a wrist
display. Controller buttons use only inputs every runtime delivers, haptics
replace camera shake (shaking a headset view makes people ill), and a crash
freezes the view rather than spinning it.

Show: `08-vr-cockpit.png`

*Be accurate on this slide:* the VR rig builds and passes the full self-test,
but it has not yet been flown on a physical headset. See docs/TEAM.md.

### 11. Engineering

- **Automated testing.** `--selftest` flies the aircraft through the whole site
  and makes 155 checks - sensors, gas readings, thermal field, survivor
  tagging, damage, day/night, graphics presets. `--flighttest` measures
  handling, camera smoothness in every view, and the autopilot. Both run
  headless in about 90 seconds and print PASS or exactly what failed.
- **Bugs stay fixed.** The worst bugs we found each have a test guarding them:
  the survivor counter that stuck at 5/6 (the test reproduced it before the
  fix), duplicate tagging of one survivor, and the camera jitter - where the
  test keeps a no-interpolation run as a control, so the fix is measured
  against the original problem every time.
- **Performance.** Skyline in one draw call, 900 rubble pieces in three, 100
  route cones in one; lights that only exist after dark; graphics presets down
  to integrated GPUs.
- **Reproducible.** Clone, open, press F5. No download step, no configuration.

### 12. Team

See [docs/TEAM.md](docs/TEAM.md): Sanjeev - aircraft, flight, damage, VR
piloting, sensors and integration; Vishnu - world, terrain, buildings,
lighting, gas and heat hazards, assets; Tejeshwar - thermal, detection,
mission, HUD and menus. Roughly equal thirds of the code.

### 13. Demo, in about four minutes

1. Briefing screen - the scenario in one breath.
2. Launch from the van in **chase view**. Strafe and climb to show it is smooth.
3. **RB to FPV**, fly over the crater.
4. **LB to thermal** near the warehouse: the trapped survivor appears in
   rubble that was empty in daylight. **A to tag.** The objective counts.
5. **Y to the gas overlay** over the pipe corridor: the LPG cloud becomes
   visible. The detector alarms.
6. **Orbit** the survivor (R3), then **drop a first-aid kit** (D-pad left).
7. **B to detonate** a fuel drum at a safe distance - show it on thermal too.
8. **Esc, time of day to Night**, switch to low-light.
9. **Return home** (D-pad down): the aircraft flies itself back and lands on
   the van.
10. Tab: the after-action report.

### 14. Limitations and next steps

Say these before anyone asks.

- The scenario is a teaching reconstruction, not a survey of the real site.
- VR has not yet been tested on a headset.
- The gas model is an analytic plume, not computational fluid dynamics.
- The flight models are commanded-velocity, chosen for a demo that anyone can
  fly - not a rotor-thrust simulation.
- Next: multiple drones sharing one map; a real terrain scan of the site;
  a scored training mode with time targets.

---

## Running it

**New here? Read [SETUP.md](SETUP.md).** Clone, open `project.godot` in
Godot 4.5, press F5. Every asset is already in the repository — there is
nothing to download and nothing to configure. The first open takes a few
minutes while Godot imports the assets; that is normal and happens once.

**Flat (keyboard / gamepad) — use this for development and testing**

This is how the repository ships. Open the project in Godot 4.5 and press F5.
If someone has turned OpenXR on, turn it back off with:

```bash
vr_mode off
```

**VR (the assessed demo)**

```bash
vr_mode on
```

Connect the headset *first*, then launch. Both commands just regenerate
`project.godot` with OpenXR on or off. The first VR launch writes
`openxr_action_map.tres` into the project with Godot's default bindings; open it
in the editor if you want to rebind anything.

> **Why the toggle exists.** Godot asks the OpenXR loader for a runtime during
> engine start-up. On a machine with no runtime installed that call blocks for
> well over a minute before it gives up, so the flat build leaves OpenXR off and
> starts instantly. Leave it off unless a headset is plugged in.

Tested against `Godot_v4.5-stable_win64`, Forward+ renderer, on an RTX 4060.

---

## Controls

Two flight models, switched in **Esc -> Flight model**. Arcade is the default
and the one to demo with; flight sim is there for anyone who wants to fly it
like an aircraft.

### Gamepad and keyboard - ARCADE

The stick is a velocity: the drone goes where it is pushed and stops when the
stick centres. Strafe, climb and turn are independent.

| | Gamepad | Keyboard |
| --- | --- | --- |
| Forward / back, strafe | Left stick | `W` `A` `S` `D` |
| Up / down | RT / LT | `Space` / `Shift` |
| Turn | Right stick X | `Q` `E` or arrows |
| Camera tilt | Right stick Y | `R` / `F`, `G` centres |

### Gamepad and keyboard - FLIGHT SIM

The drone has a nose. Point it, then drive along it. Pitch is **inverted**,
like an aircraft: pull the left stick back to raise the nose, push to dive.

| | Gamepad | Keyboard |
| --- | --- | --- |
| Point the nose (pitch / turn) | Left stick | `W` `A` `S` `D` |
| Accelerate / brake | RT / LT | `Space` / `Shift` |
| Climb / descend directly | Right stick Y | `R` / `F` |
| Slide sideways | Right stick X | `Q` / `E` |

Release the trigger and it coasts down to a hover rather than stopping dead.

### Everything else (both models)

| | Gamepad | Keyboard |
| --- | --- | --- |
| **Thermal on / off** | **LB** | **`2`** or **`T`** |
| **Camera: chase / close / FPV** | **RB** | **`C`** |
| Cycle sensor (EO / thermal / NV / gas) | Y | `V` |
| Tag what the reticle is on | A | `X` |
| Photo | X | `P` |
| **Detonate a fuel drum** | **B** | **`B`** |
| **Return to the van (autopilot)** | **D-pad down** | **`H`** |
| **Orbit the contact (autopilot)** | **R3** | **`J`** |
| **Drop a first-aid kit** | **D-pad left** | **`Z`** |
| Spotlight | D-pad up | `L` |
| Slow (precision) | L3 | `Ctrl` |
| Reset to the van | Start | `Backspace` |
| Thermal palette | - | `M` |
| Help / settings / report | - / - / - | `F1` / `Esc` / `Tab` |

### VR (Quest / Index-style controllers)

Mode-2 drone layout: left stick throttle and yaw, right stick pitch and roll.
Your head is the gimbal, and tagging, orbiting and detonating all act on what
you are looking at.

| | Right hand | Left hand |
| --- | --- | --- |
| Trigger | Tag what you are looking at | Precision (slow) |
| Grip | Spotlight | Detonate the drum you look at |
| A / X | Cycle sensor | Thermal on / off |
| B / Y | Drop first-aid kit | Return to the van |
| Stick click | Orbit the contact | Photo |
| Menu | - | Settings (flight model, reset, time of day) |

The gas readout is on your **left wrist**; turn your hand over to read it.
Nothing is mapped to the right-hand menu button: on a Quest that is the system
button and is never delivered to applications.

**VR status:** the full VR rig builds and runs the complete self-test
(`--selftest --force-xr-rig`), and the mapping above uses only inputs every
OpenXR runtime reports. It has not yet been flown on a physical headset - do
that before any VR demo; see docs/TEAM.md.

### The three camera views

| View | What it is for |
| --- | --- |
| **Chase** | The default following shot. Swings round behind a turn. |
| **Close follow** | Tight over-the-shoulder. The one to fly in to *see* the drone. |
| **FPV nose cam** | 104 deg lens on the nose, inheriting the airframe's lean. |

Chase and close cast their own ray back from the drone, so a wall between the
camera and the aircraft pulls the camera in instead of clipping through it. In
VR the headset replaces all three.

---

## What the aircraft carries

**Four sensor modes**, all computed from one shared hazard field, so the picture
and the numbers can never disagree:

- **EO daylight** — what the eye would see. Good for structure; close to useless
  for a grey person lying in grey rubble.
- **Thermal IR** — a radiometric model of the whole site, not just the hot
  things in it. Every surface gets a temperature from heat banked on the faces
  that saw the afternoon sun, radiative loss to the sky on anything facing up,
  thermal mass, height above the ground, residual warmth in the crater floor,
  and two octaves of ground patchiness — so the site carries a real gradient
  instead of reading as one flat colour with the fires cut out of it. The
  automatic gain window is deliberately narrow, because a wide window is what
  flattens that gradient back out. People are heat capsules matching their
  bodies, so you see a human silhouette, not a blob. Six LUT palettes; white
  hot is the default because it is what a search payload is actually flown in.
  Depth-based detail enhancement and a periodic shutter (NUC) calibration give
  it the look of a real core, and bloom is switched off on every sensor feed.
- **Low-light NV** — an auto-gated intensifier: the gain opens until the scene
  sits mid-grey and closes when something bright enters frame, exactly as a
  real tube gates. Plus an IR illuminator cone for voids and hard dark.
- **Gas overlay** — analytic plume integration along the view ray, in false
  colour per gas, so an invisible cloud acquires a visible shape and you can
  fly around it instead of through it.

**A live gas field** — ~50 sources (smouldering debris, drains, fuel spills,
nitrate residue) each pulsing on its own rhythm, a drifting background, and
wind-advected turbulence shared bit-for-bit between CPU and GPU. Readings never
sit still, just like a real pod flown over a disaster site. Every sample is left
behind as a coloured 3D **air-sample trail** (`T` / left stick click) and on the
survey map, and each channel has a 60-second trend graph.

**A five-channel detector head** — CO, H₂S, NO₂, combustible gas (%LEL) and
oxygen — with realistic response lag, sensor noise, peak hold, exposure
accumulation and two-stage alarms at genuine occupational exposure levels.

**Obstacle ring** — eight lateral beams plus up and down, feeding the HUD
proximity display, an audible closing tone and an optional braking assist.

**Detection pipeline** — range, off-boresight angle, line of sight and the
active sensor mode combine into a confidence figure. Thermal roughly doubles
the odds of finding a person in rubble, which is the entire argument for the
payload.

---

## The site

The assessment zone is laid out so that every piece of it answers a question
the operator would otherwise have to ask over the radio.

| | |
| --- | --- |
| **Staging area** | The response van you launch from, inside a barrier cordon, with the ground swept clear of debris for 19 m. |
| **The city** | A ruined skyline on three sides, open toward the quay. Six damaged blocks stand behind the staging area and seven more inside the survey area, from barely-touched shells to flattened pancake stacks. |
| **Rubble field** | Ground debris across the whole site, thickest along the pipe corridor. Three MultiMeshes, so the entire field costs three draw calls and carries no collision. |
| **Wind mast** | A windsock that points downwind and lifts with the wind speed, so the mast, the HUD readout and the direction the plumes actually drift all agree. |
| **Casualty collection point** | Canopy, ambulance, and three triage bays painted immediate / delayed / minor. This is where the survivors you tag are taken, which is why the route to it matters. |
| **Marked access route** | A coned vehicle route from the staging area to the collapse — and the fallen wall panel that blocks it. That blockage is a finding, not scenery: it is the single most useful thing an assessment flight can report. |
| **Fire appliance** | Working the container-yard fire, deck monitor lit after dark. |
| **Collapsed quay crane** | The gantry folded across the container stacks, boom still under load. The reason the yard is an exclusion zone. |
| **Hazard boards** | At the silo, the flammable atmosphere and the active fire — the three places an unbriefed rescuer would walk into something that would kill them. |
| **Silos, warehouse, pipe corridor, crater** | The original blast site, unchanged. |

Nothing here is decoration for its own sake. If a prop does not tell the
operator something, it is not in the scene.

---

## Time of day

Four named times, stepped from the settings menu (`Esc` → Time of day):

| | | |
| --- | --- | --- |
| **DAWN** | 06:24 | Long shadows, thermal contrast still good from overnight cooling. |
| **DAY** | 13:00 | Thermal is at its weakest — everything has been in the sun. |
| **DUSK** | 17:36 | The default. Readable on the daylight camera, and thermal already wins. |
| **NIGHT** | 22:18 | The daylight camera is nearly useless. Site lighting comes on: the van's light bar and worklight, the fire appliance's deck monitor, the casualty point's canopy light. This is the low-light and thermal demo. |

After dark the sky stops acting as a fill light and the sun becomes a dim,
cold moon. That is deliberate: if night is not actually dark, the low-light
channel has nothing to amplify and the other two sensors have no argument.

---

## Finding people

A survivor is logged when **you tag them**, not when the detector happens to
glimpse a warm shape. Put the reticle on them and press A / `X`.

Tagging works on whatever the reticle is pointing at, regardless of what the
detector thinks. The detector drops its confidence hard when the line of sight
is obstructed, which is right for the automatic log and wrong for the tag
button: a survivor visible through a gap in a pipe rack has to be taggable.

The six survivors are instances of `scenes/victim.tscn`, sitting under a
`Survivors` node in `scenes/main.tscn`, so they can be selected and moved in
the editor. Each one drops onto whatever solid surface is below it when the
scene starts, so placing one only means getting the X and Z right.

Every contact carries one de-duplication key, and both routes into the findings
log — the automatic detector for fires, gas and structures, and the tag button
— go through it. So a contact can produce exactly one finding however many
times it is seen or tagged, the survivor count on the objectives panel counts
people rather than button presses, and tagging someone twice says
`ALREADY TAGGED #03` and changes nothing. Tagged survivors get a green strobe
that stays lit, so a second pass can see at a glance who is already accounted
for.

Reference points — tagging with no contact in the reticle — are deliberately
*not* de-duplicated, because those are free-form notes.

The `--selftest` harness asserts all of this: it tags one survivor seven times
and fails if the log or the counter moves more than once.

---

## Making the problem visible

The brief was that whoever is watching should be able to see *exactly* where the
problem is. That is handled in five places:

1. **World-anchored beacons.** Every confirmed finding plants a labelled marker
   with a light shaft and a ground ring. Labels ignore depth, so a marker behind
   a slab still tells you it is there, and hold a constant angular size so they
   are readable at a hundred metres.
2. **Contact briefings.** Put the reticle on a contact and the interface states
   what it is, how confident the detector is, why it matters and what should be
   done about it — in plain language, with coordinates.
3. **The survey map.** Coverage fills in as you fly, so "which parts of this
   site has anyone actually looked at" has an answer.
4. **Sensor legends.** A thermal scale with the live gain window and a marker
   for the spot sample; a per-gas colour key for the overlay.
5. **The after-action report.** Every finding with position, time, severity and
   WGS84 coordinates, exportable to CSV.

---

## Flight model

Both models command a velocity on top of a rigid body, so walls stop the
aircraft and neither can drift: no input is a zero command, and the body is
brought to rest.

| | Arcade | Flight sim |
| --- | --- | --- |
| Top speed | 12 m/s, strafe equal to forward | 18 m/s along the nose |
| Time to 90% speed | 0.46 s | 2.2 s |
| Stopping | 2.6 m from cruise | 8.7 m braking from 16 m/s |
| On release | stops | coasts |

Numbers from `--flighttest`, which re-measures all of them on every run.

**Why it is smooth.** The aircraft moves at the 60 Hz physics rate and the
screen draws faster - 144 Hz on a gaming laptop, 72-120 Hz in a headset. A
camera reading the raw body position stands still for a frame, then jumps:
invisible flying forward, obvious on a strafe or a climb, where the motion runs
across the frame. Physics interpolation is on, every camera (and the VR rig)
reads the *interpolated* transform, and the chase rig holds translation rigid
and eases only the yaw of the shot. `--flighttest` samples the camera every
rendered frame at 144 Hz for every view in both models: frame-to-frame speed
varies by under 0.6% with no stalled frames. The same test with interpolation
off, kept as the control, shows 55% of frames frozen.

**Landing assist.** The last couple of metres of any descent are flown at a
touchdown rate, the way a real flight controller does, so a landing is never
scored as a crash.

---

## Autopilot, payload and damage

**Return to the van** (`H`, D-pad down). Climbs to 20 m above the staging area,
flies straight back, and lands on the deck facing the way it launched - 0.08 m
from the centre from 75 m out. Landing repairs the airframe and reloads the
kits.

**Orbit** (`J`, R3). Circles whatever contact the reticle is on, at the radius
it was engaged from, nose and gimbal held on the target: the standard way to
inspect a find from every side. Holds radius to 0.01 m.

Both hand control straight back the moment a stick is touched, and a banner
across the top says so while they are flying.

**First-aid kits** (`Z`, D-pad left). Four aboard. Each falls under a drogue
chute, drifts with the wind, lands with green marker smoke, and is credited to
any survivor within 6 m - which is the fifth objective.

**Damage.** A sub-kilogram quad is fragile - props shatter on contact - and it flies like it:

| | |
| --- | --- |
| Impact under 1.6 m/s | free - brushing a wall |
| Harder impacts | integrity loss rising steeply with speed; above 3 m/s a prop strike costs a motor |
| Detonation within 16 m | overpressure damage and a shove away from the blast |
| Flying through a flame column | heat damage, from the same field the thermal camera draws |
| Lost thrust | top speed and climb come down with it; uneven motors make the airframe wobble |
| 0% | motors cut, it falls, and a spare launches from the van three seconds later |

Grey smoke trails from the airframe below 45%, so its state is visible from the
chase camera. Landing on the van repairs it.

---

## Settings (`Esc`)

Every row in the menu changes something you can see without leaving it, and the
highlighted row explains itself on the line at the bottom. Three switches that
nothing had read since the flight model was rewritten — invert pitch, stick
expo, mouse sensitivity — were removed rather than left there looking
functional, and the obstacle braking assist was reconnected: it now scales back
only the part of the commanded velocity pointed at the nearest obstacle, so the
aircraft still flies freely along a wall and simply refuses to be driven into
it.

`W`/`S` moves, `A`/`D` changes a value, `X` or gamepad A selects, `Esc` closes.

---

## Project layout

Open `scenes/main.tscn` and every piece of the site is there in the scene tree,
as its own scene - drag any of it and it re-seats itself on the terrain:

```
Main
  World            terrain, sky, lighting, skyline, rubble field (generated)
  Drone            scenes/drone.tscn - airframe, sensors, autopilot, payload bay
  StagingArea      ResponseVan (the launch pad), WindMast, Cordon, Kit
  Response         CasualtyPoint, Ambulance, FireAppliance, AccessRoute
  Site             GrainSilos, Warehouse, CollapsedBlock, ContainerYard,
                   PipeCorridor, CollapsedCrane, Harbour
  City             thirteen RuinedBuildings - drag the Collapse slider and
                   they fall down in the editor
  Hazards          GasLeaks, Fires, Structural, Signs
  ExplosiveDrums   38 drums
  Survivors        six scenes/victim.tscn instances
```

```
scenes/
  drone.tscn, victim.tscn
  staging/         response van, ambulance, fire appliance, casualty point,
                   access route, wind mast
  structures/      silos, warehouse, collapsed block, container yard, pipe
                   corridor, crane, harbour, ruined building
  hazards/         fire, gas leak, structural hazard
  props/           prop model (any Poly Haven asset), hazard sign, explosive drum
scripts/
  autoload/        Sim (state, findings, settings), Hazards (the physical
                   gas/heat field), Sfx
  drone/           flight models, autopilot, payload bay, damage, gas sensor,
                   proximity ring, detector
  camera/          flat camera rig, payload post-process, thermal palettes
  xr/              OpenXR rig, controller-to-InputMap bridge
  world/           terrain, build kit, world builder, hazards, victims, VFX
  world/pieces/    the script behind every placeable scene
  mission/         objectives, survey coverage, report
  ui/              HUD, wrist panel, briefing and settings
  debug/           --selftest and --flighttest
shaders/           vision_post (all four sensors), water, terrain, vignette
tools/             project.godot generator, main scene layout, asset fetcher,
                   audio synthesis
```

Every placeable piece extends `SitePiece`: it builds its geometry from code in
the editor as well as the game, and tags what it builds so none of it is
written back into the scene file - `main.tscn` stores where each piece is and
how it is set up, not thousands of slabs. Pieces ask `Terrain.height()` where
the ground is, the same pure function the terrain mesh is built from, so the
mesh and everything standing on it can never disagree.

`tools/gen_main_scene.py` laid out the initial `main.tscn`. It is not needed
any more - the scene file is the source of truth now - and re-running it would
overwrite hand edits (except Survivors, which it always carries over).

`project.godot` is generated by `tools/gen_project_godot.py` — edit that script
rather than the file, or your input map will be overwritten next time the VR
toggle is used.

**What is in version control.** All source, and all ~205 MB of assets, so a
clone is immediately runnable. Not the `.godot/` folder: that is Godot's import
cache, it is over 500 MB on this project, it is derived entirely from the
committed assets, and it is not portable between machines. Godot rebuilds it on
first open. The `.import` files beside each asset *are* committed — they carry
the stable resource UIDs, and without them every teammate's editor would assign
different ones and the scene files would stop resolving.

---

## Adding the team's assets

Drop `.glb` files into `assets/team/` and list their placements in
`assets/team/placement.json`. See `assets/team/README.md` for the format. If
that folder is empty the scene builds exactly as it does now, so neither half of
the project blocks the other.

---

## Regenerating the generated content

None of this is needed to run the project — every asset these scripts produce
is already committed. They are here so the asset set can be rebuilt from
scratch rather than trusted as opaque binaries.

```bash
python tools/fetch_assets.py        # re-download the CC0 asset set (~154 MB)
python tools/make_audio.py          # re-synthesise the audio bank
python tools/gen_project_godot.py   # rebuild project.godot (add --vr for OpenXR)
```

`project.godot` holds the input map and is written by the last of these. Edit
`tools/gen_project_godot.py` rather than the file itself, or your bindings will
be overwritten the next time anyone uses the VR toggle.

---

## Performance notes

Three presets, switchable live from the settings menu, plus a VR one that is
selected automatically when OpenXR initialises. The choice is saved.

| Preset | What it turns on | For |
| --- | --- | --- |
| `LOW` | Nothing that costs a full-screen pass. No bloom, no fog, no ambient occlusion, 70 m shadows on one split, airborne dust off. | Integrated graphics. |
| `MEDIUM` | Bloom, distance fog, 150 m shadows on two splits, half dust. **Default.** | A laptop GPU. |
| `HIGH` | Ambient occlusion to seat the rubble on the ground, volumetric fog for the fires and the spotlight to shine through, 230 m shadows on four splits, full dust. | Recording the demo. |
| `VR` | Stereo doubles the cost of every screen-space effect, so this keeps only what the mission needs. | Selected automatically. |

SDFGI and SSIL are off at every preset. On this scene they cost more than
everything else combined and buy very little, because almost all of the
interesting light is direct.

Other things that keep the frame budget honest: the ~100 route cones are one
MultiMesh and therefore one draw call; the imported airframe's 120-odd meshes
do not cast shadows; site lighting only exists after dark, so by day those
lights are not in the renderer's list at all.

This targets **tethered PCVR** (Quest Link or SteamVR) on the Forward+
renderer. A standalone Quest build would need the Compatibility renderer and a
further cut to the asset budget — that is a porting exercise, not a setting.

---

## Credits and licensing

All third-party content is CC0 or OFL. See `assets/CREDITS.md`, which is
regenerated by the asset fetcher.

- Environment models, materials and HDRIs: [Poly Haven](https://polyhaven.com) (CC0)
- Fonts: Barlow Semi Condensed and Share Tech Mono (SIL Open Font License)
- Airframe: the DJI FPV model carried over from the author's earlier
  `project-test` prototype
- All audio: synthesised from scratch by `tools/make_audio.py`

## A note on the subject matter

The scenario begins with a content note, avoids injury depiction, and represents
casualties only as far as is needed to practise locating them. It is presented
as an educational reconstruction of a disaster-assessment task, in
acknowledgement of the people killed, injured and displaced in Beirut on
4 August 2020.
