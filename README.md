# Beirut Port SAR Drone Simulator

A VR search-and-rescue drone simulation over a post-blast industrial zone,
built in Godot 4.5. You fly the first aircraft into a sector nobody can enter on
foot: find the survivors, map the atmosphere, and flag what is about to fall on
the rescue teams.

The scenario is an educational reconstruction referencing the 2020 Port of
Beirut explosion. It is a teaching model, not a forensic reproduction of that
event.

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

### VR (OpenXR, tested mapping for Quest / Index-style controllers)

| Action | Control |
| --- | --- |
| Throttle / yaw | Left stick |
| Pitch / roll | Right stick |
| Precision (slow) mode | Left trigger |
| Tag the contact you are looking at | Right trigger |
| Cycle sensor mode | Right A |
| Capture evidence still | Right B |
| Thermal camera on / off | Left X |
| Spotlight | Left Y |
| Thermal palette | Left grip |
| Cycle camera view (chase / close / FPV) | Right grip |
| Reset aircraft | Right menu |
| Report / settings | Left menu |

Your head is the gimbal — look wherever you want, the aircraft does not care.
The gas readout is on your **left wrist**; turn your hand over to read it.

### Flat (keyboard / gamepad)

The drone flies where you point it and stops when you let go, but it has weight:
it accelerates up to speed rather than snapping to it, brakes harder than it
accelerates, and banks by however much specific force it is pulling. Nothing
drifts on its own in any axis.

| | Gamepad | Keyboard |
| --- | --- | --- |
| Forward / back | Left stick up / down | `W` `S` |
| Strafe | Left stick left / right | `A` `D` |
| Up / down | RT / LT | `Space` / `Shift` |
| Turn | Right stick | `Q` `E` or arrow keys |
| Slow mode | L3 | `Ctrl` |
| **Thermal camera on / off** | **LB** | **`2`** or **`T`** |
| **Camera view** | **RB** (or Back) | **`C`** |
| Cycle sensor mode | Y | `V` |
| Sensor direct | — | `1` EO, `3` night, `4` gas |
| Thermal palette (6 LUTs, white hot default) | — | `B` |
| Gimbal tilt / centre | Right stick Y | `R` `F` / `G` |
| Tag contact | A | `X` |
| Photo | X | `P` |
| Spotlight | D-pad up | `L` |
| Air-sample trail | — | `K` |
| Report | — | `Tab` |
| Reset to the van | Start | `Backspace` |
| Controls / settings | — | `F1` / `Esc` |

### The three camera views

RB on the pad, `C` on the keyboard, cycling in this order:

| View | What it is for |
| --- | --- |
| **Chase** | The default following shot. Backs off as speed builds. |
| **Close follow** | Tight over-the-shoulder. The airframe reads clearly — this is the one to fly in when you want to *see* the drone. |
| **FPV nose cam** | Bolted to the nose, 104° lens, inherits the airframe's lean and a small throttle-dependent frame vibration. Accelerating drops the horizon and braking lifts it. |

Chase and close both hang off a spring arm, so a wall between the camera and the
aircraft pulls the camera in instead of clipping through it.

### Launch and recovery

The drone starts on the roof deck of the response van parked in the staging
area. The deck is a real collision surface with a marked touchdown circle, the
ground inside the cordon is kept clear of debris, and `Backspace` puts the
aircraft back on the deck from anywhere.

Editing: open `scenes/main.tscn`. The `Drone` node is `scenes/drone.tscn` (your
DJI model is its `Airframe` child). The terrain, structures, van and props are
built by `scripts/world/world_builder.gd` and are previewed in the editor
viewport.

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

One mode, tuned for a demo somebody has to be able to pick up and fly:

- The sticks command a velocity, and the aircraft accelerates onto it at a
  finite rate (12 m/s² up, 16 m/s² braking) rather than being teleported onto
  it. That is the whole difference between "arcade" and "has weight".
- Yaw rate ramps in and out instead of stepping, so a turn starts and finishes
  smoothly.
- Bank angle comes from specific force — the airframe tilts by the angle whose
  horizontal thrust component produces the acceleration it is actually pulling,
  plus a standing tilt to hold against drag at speed. It is animation only: the
  collision body stays level, so a lean can never tip the aircraft or push it
  off course.
- Sideways flight is deliberately slower than forward flight.
- Nothing drifts. Release the sticks and it stops and stays stopped.

Verify it with `--flighttest`, which measures hands-off drift, sustained
forward speed and stopping distance.

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

```
scenes/main.tscn         World + Drone; the rest of the site is built in code
scenes/drone.tscn        the aircraft, with the DJI model as its Airframe child
scripts/
  autoload/              Sim (state, findings, settings), Hazards (the physical
                         gas/heat field), Sfx
  drone/                 flight model, gas sensor, proximity ring, detector
  camera/                flat camera rig, payload post-process
  xr/                    OpenXR rig, controller-to-InputMap bridge
  world/                 terrain, structures, hazards, victims, beacons, VFX
  mission/               objectives, survey coverage, report
  ui/                    HUD, wrist panel, briefing and settings
shaders/                 vision_post, terrain, comfort_vignette
tools/                   asset fetcher, audio synthesis, project.godot generator
assets/team/             drop-in point for the rest of the team's models
```

Most of the site is constructed in code rather than authored as `.tscn` files.
That is
deliberate: the rotor positions, sensor mounts and hazard field all have to stay
consistent with the flight model, and keeping them in one place means they
cannot drift apart.

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
