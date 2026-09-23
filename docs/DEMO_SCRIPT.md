# Demo video script and live demo plan

Total video length: about 6 minutes. Three voiceovers, clearly separated -
Sanjeev, then Vishnu, then Tejeshwar - after a shared intro. Each section lists
what is **on screen** and what is **said**. Timings are targets, not rules.

Set up before recording: Graphics HIGH, Time of day DUSK, Flight model ARCADE,
HUD on. Record at 1920x1080, 60 fps.

---

## 0. Cold open (0:00 - 0:20) - Sanjeev

**On screen:** black. Then fade up: thermal view, a warm human shape lying in
grey rubble. Hold two seconds. Cut to the title card.

**Say:**
> "4 August 2020. Two thousand seven hundred and fifty tonnes of ammonium
> nitrate detonate in the Port of Beirut. In the first hours, nobody can walk
> into what's left - the ground is unstable, the air may be poisonous, fires are
> still burning. But somewhere in there, people are alive.
> This is how you find them."

**Title card:** *Beirut Port SAR Drone Simulator* - search and rescue, flat
screen and VR, built in Godot 4.5.

## 1. The project in thirty seconds (0:20 - 0:50) - Sanjeev

**On screen:** slow flyover of the site from altitude - silos, crater,
harbour, the ruined city - then drop down to the drone sitting on the
response van.

**Say:**
> "We built a drone simulator for exactly that first hour. A reconstructed
> blast site, a search drone carrying the sensors real rescue teams fly -
> thermal, night vision, gas detection - and a mission: find six survivors,
> map the toxic air, flag what's about to collapse, and get help to people
> before anyone else can reach them. It runs on a monitor and in VR, and
> everything you're about to see is live, not pre-rendered."

---

## 2. Sanjeev - the aircraft (0:50 - 2:40)

*Aircraft, flight, damage, VR piloting, sensors and integration.*

**On screen / Say:**

1. **Launch** - lift off the van, chase camera. Strafe left and right, climb,
   reverse.
   > "I built the aircraft. First thing - it has to fly beautifully. The drone
   > moves at 60 physics updates a second, but your screen draws at 144. Left
   > alone, that mismatch makes the camera stutter every time you strafe or
   > climb. We interpolate every frame - and we proved it: our test measures the
   > camera at 144 frames a second, in every view. Without the fix, more than
   > half the frames freeze. With it - zero."

2. **RB through the cameras** - chase, close follow, FPV nose cam. Fly FPV low
   over the crater.
   > "Three cameras - chase, close follow, and an FPV nose cam that leans with
   > the airframe, the way real FPV footage feels."

3. **Esc -> Flight model -> Flight Sim.** Pull back, climb away on RT, bank a
   turn, brake on LT.
   > "Two flight models. Arcade, where the drone goes wherever you push it.
   > And flight sim - pitch the nose, throttle on the trigger, and it carries
   > momentum like a real aircraft."
   Switch back to Arcade.

4. **Onboard sensors** - fly into the pipe corridor; the five-gas panel starts
   climbing, LEL alarm fires.
   > "It carries a five-gas detector - carbon monoxide, hydrogen sulphide,
   > nitrogen dioxide, flammable gas and oxygen - alarming at real occupational
   > exposure limits, and leaving a trail of every air sample it takes."

5. **Damage** - clip a wall at speed. Integrity drops, prop strike alarm, the
   airframe wobbles and trails smoke.
   > "And it's fragile, like a real quad. Hit something and you lose a motor -
   > it gets slower, it wobbles, it smokes. Fly into a fire or a blast and it
   > can come down entirely."

6. **Autopilot** - put the reticle on a survivor, **R3 to orbit**. Then **D-pad
   left** - a first-aid kit falls under its parachute, lands in green smoke.
   > "Once you've found someone, the autopilot can orbit them, gimbal locked on,
   > while you drop a first-aid kit right beside them."

7. **D-pad down - return home.** Cut to the drone descending onto the van.
   > "And one button brings it home - it climbs clear, flies back and lands on
   > the van, within eight centimetres, repaired and reloaded for the next
   > sortie. The same controls work in VR, where your head becomes the camera."

---

## 3. Vishnu - the world (2:40 - 4:10)

*World, terrain, buildings, lighting, gas and heat hazards, assets.*

**On screen / Say:**

1. **High orbit of the whole site** at dusk.
   > "I built the world it flies through. The terrain is generated from a single
   > function - a blast crater, its ejecta rim, rubble everywhere - and
   > everything in the scene stands on that same function."

2. **Godot editor:** open `main.tscn`, the scene tree full of pieces. Drag a
   ruined building across the map - it re-seats on the ground. Drag the
   **Collapse** slider - it falls down.
   > "Every building, vehicle and hazard is its own scene. Move one and it
   > settles onto the rubble wherever you drop it. This slider goes from
   > standing shell to completely pancaked."

3. **Back in game - the landmarks.** Silos, the collapsed crane over the
   containers, the harbour.
   > "The grain silos that became the image of that day. A quay crane folded
   > across the container yard. The harbour, with water that reads colder than
   > anything else on site. Thirteen ruined city blocks, and nearly a thousand
   > pieces of debris - drawn in three calls, so it runs on a laptop."

4. **The response** - the van, casualty point with triage bays, the coned
   access route, the fallen wall blocking it.
   > "And a response on the ground - a casualty point, an ambulance, a fire
   > engine, and the one vehicle route in, blocked by a fallen wall. Spotting
   > that is the most useful thing a survey flight can report."

5. **Esc -> Time of day -> Night.** Site lights come on, beacons strobe.
   > "Four times of day. At night the site really is dark - the van's light bar,
   > the work lights and the fires are all you've got."

6. **Gas and fire** - fly past a fire, press **B** near a fuel drum at a safe
   distance. Fireball, shockwave.
   > "Underneath it all is a physical hazard model - gas plumes that drift with
   > the wind, heat from every fire. And fuel drums that the pilot can set off
   > from the air."

---

## 4. Tejeshwar - seeing and the mission (4:10 - 5:40)

*Thermal, detection, mission, HUD and menus.*

**On screen / Say:**

1. **Still at night, EO view** - a dark rubble field. Nothing visible.
   > "I built how the drone sees, and what the operator does with it. Here's
   > the daylight camera, at night. There's a survivor in this shot. You can't
   > see them."

2. **Y to night vision.** The scene lifts to green.
   > "Night vision amplifies what little light there is - it adjusts its own gain
   > like a real image intensifier."

3. **Back to dusk. LB to thermal** over the pipe rack - the survivor glows.
   > "And thermal. This isn't a filter - every surface on the site has a
   > temperature: sun-warmed walls, ground cooling to the night sky, the crater
   > still holding heat. Against that, a body at thirty-four degrees is
   > unmistakable. This is why rescue drones carry thermal."

4. **A to tag.** Contact panel, confidence, the objective ticks up.
   > "The detector weighs range, angle, line of sight and sensor mode into a
   > confidence score. The operator confirms the find - and each person can only
   > ever be counted once."

5. **Y to the gas overlay** over the crater.
   > "The gas overlay makes the invisible visible - the same plume model the
   > detector reads, so the picture and the numbers can never disagree."

6. **Tab - the after-action report.** Then **Esc** - settings.
   > "Every finding lands in a report with GPS coordinates, ready to hand to the
   > rescue teams. And the whole mission runs on five objectives the operator can
   > see at all times."

7. **Close on the self-test** scrolling to PASS in a terminal.
   > "Behind all of it, a hundred and fifty-five automated checks fly the drone
   > through the entire site and prove every system still works."

---

## 5. Close (5:40 - 6:00) - all three / Sanjeev

**On screen:** the drone lifting off the van at dusk, slow pull-back to the
whole site. Title card, then team names.

**Say:**
> "Search, detect, report, and bring it home. A drone that goes where rescuers
> can't - so they know exactly where to go next."

**End card:** Sanjeev - Vishnu - Tejeshwar. GitHub link.

---

## Live demo (about 4 minutes)

Keep it short and certain. Arcade mode, dusk, chase camera.

| # | Action | Controls | Presenter |
| --- | --- | --- | --- |
| 1 | Launch from the van, strafe and climb | Left stick, RT | Sanjeev |
| 2 | Cycle cameras to FPV and back | RB | Sanjeev |
| 3 | Fly the pipe corridor, gas alarm | - | Sanjeev |
| 4 | Thermal on over the pipe-rack survivor, tag | LB, A | Tejeshwar |
| 5 | Orbit the survivor, drop a kit | R3, D-pad left | Sanjeev |
| 6 | Gas overlay over the crater | Y | Tejeshwar |
| 7 | Detonate a drum from a safe distance | B | Vishnu |
| 8 | Switch to night, then night vision | Esc, Y | Vishnu / Tejeshwar |
| 9 | Return home and land on the van | D-pad down | Sanjeev |
| 10 | Show the report | Tab | Tejeshwar |

**If something goes wrong:** Start (Backspace) resets the drone to the van.
Don't fly close to fires or drums during the live demo - damage is real.

---

## All controls

### Flight - Arcade (default)

| | Gamepad | Keyboard |
| --- | --- | --- |
| Forward / back, strafe | Left stick | W A S D |
| Up / down | RT / LT | Space / Shift |
| Turn | Right stick X | Q / E, arrows |
| Camera tilt / centre | Right stick Y | R / F, G |

### Flight - Flight Sim (Esc -> Flight model)

| | Gamepad | Keyboard |
| --- | --- | --- |
| Pitch the nose (**inverted**: back = nose up) | Left stick Y | S / W |
| Turn | Left stick X | A / D |
| Accelerate / brake | RT / LT | Space / Shift |
| Climb / descend directly | Right stick Y | R / F |
| Slide sideways | Right stick X | Q / E |

### Everything else

| Function | Gamepad | Keyboard |
| --- | --- | --- |
| Thermal on / off | LB | 2 or T |
| Cycle camera (chase / close / FPV) | RB | C |
| Cycle sensor (EO / thermal / NV / gas) | Y | V |
| Direct sensor: EO / night / gas | - | 1 / 3 / 4 |
| Thermal palette | - | M |
| Tag what the reticle is on | A | X |
| Photo | X | P |
| Detonate fuel drum | B | B |
| Return to the van (autopilot) | D-pad down | H |
| Orbit the contact (autopilot) | R3 | J |
| Drop first-aid kit | D-pad left | Z |
| Spotlight | D-pad up | L |
| Slow / precision flying | L3 | Ctrl |
| Reset to the van | Start | Backspace |
| Toggle HUD | D-pad right | F2 |
| Help | - | F1 |
| Settings / pause | - | Esc |
| Report | - | Tab |
| Obstacle braking assist | - | N |
| Air-sample trail | - | K |
| Zoom | - | PgUp / PgDn |
| Time of day nudge | - | [ / ] |

Any stick input cancels the autopilot.

### VR (Quest / Index)

| | Right hand | Left hand |
| --- | --- | --- |
| Stick | Pitch / roll | Throttle / yaw |
| Trigger | Tag what you look at | Precision |
| Grip | Spotlight | Detonate the drum you look at |
| A / X | Cycle sensor | Thermal on / off |
| B / Y | Drop first-aid kit | Return to the van |
| Stick click | Orbit the contact | Photo |
| Menu | - | Settings |

---

## Feature checklist

- **Flight:** arcade and flight-sim models, smooth camera at any frame rate,
  three camera views, landing assist, obstacle braking assist.
- **Autopilot:** return to home onto the van, orbit a contact.
- **Payload:** four first-aid kits on parachutes, credited to survivors.
- **Damage:** impacts, blasts and fire; motor loss, wobble, smoke; crash and
  spare launch; repair on landing.
- **Sensors:** EO, thermal (6 palettes, auto-gain), night vision (auto-gated),
  gas overlay; five-gas detector with alarms; air-sample trail; proximity ring.
- **Mission:** 6 survivors, gas hazards, structural hazards, 35% survey,
  first-aid drops; one-tag-per-contact; CSV report with GPS coordinates.
- **World:** crater terrain, silos, warehouse, collapsed block, container yard,
  pipe corridor, crane, harbour with water, 13 ruined blocks, city skyline,
  rubble field, response vehicles, casualty point, access route, 38 fuel drums.
- **Atmosphere:** four times of day, site lighting at night, strobing
  emergency lights, windsock, three graphics presets.
- **VR:** full OpenXR rig, head-as-gimbal, wrist gas display, haptics.
- **Quality:** 155-check self-test and a flight test, both headless.
