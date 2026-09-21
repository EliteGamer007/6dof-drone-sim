# Architecture

Notes on how the simulator is put together and why, for the project report.

---

## One field, two consumers

The central design decision is that there is exactly one description of the
hazards on site, held by the `Hazards` autoload, and both the sensor readouts
and the sensor imagery are derived from it.

```
                    Hazards (autoload)
        plumes: Gaussian capsules along the wind
        heat:   Gaussian point sources
                    │
        ┌───────────┴────────────┐
        │                        │
   CPU sampling             GPU packing
   sample_gas(p)            apply_to_material(mat)
   sample_temperature(p)    → vec4 arrays + counts
        │                        │
   GasSensor, spot temp,    vision_post.gdshader
   detector confidence      (per fragment, per eye)
```

The shader and the GDScript evaluate the *same* falloff function on the same
data. That is what makes the simulation defensible rather than decorative: the
cloud you can see and the number on the instrument cannot disagree, because
neither is authored — both are read from one model.

A plume is a capsule: an origin, a downwind axis whose direction comes from the
live wind vector, a core radius, and a spread factor that widens it downwind.
Concentration at a point is `strength · exp(−d²/2r²)` where `d` is the distance
to the capsule axis and `r` grows along it.

### Why the shader integrates analytically

For the gas overlay, every fragment needs the total concentration along its view
ray. Ray-marching 24 plumes per pixel is expensive and noisy. Instead the shader
solves the closest approach between the view ray and the plume's axis segment,
then uses the closed form of a Gaussian line integral:

```
∫ strength · exp(−d²/2r²) ds  =  strength · exp(−d_min²/2r²) · r · √(2π)
```

clipped to the visible portion of the ray by the depth buffer. One evaluation
per plume per pixel, no marching, no temporal noise, and it is consistent with
what the CPU sampler would report.

---

## Rendering path

The payload treatment is a full-screen quad parented to whichever camera is
active, using Godot's documented post-process recipe: the vertex stage writes
`POSITION` directly in clip space at the near plane, and the fragment stage
samples `hint_screen_texture` and `hint_depth_texture`.

World position is reconstructed per fragment from the depth buffer:

```glsl
vec3 ndc   = vec3(SCREEN_UV * 2.0 - 1.0, texture(depth_tex, SCREEN_UV).x);
vec4 view  = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz / view.w, 1.0)).xyz;
```

Because this is derived per fragment from that eye's matrices, it is correct in
stereo without any extra work — the thermal field and the gas plumes resolve at
the right depth in each eye.

Surface normals for the solar-heating term come from screen-space derivatives of
the reconstructed world position, which avoids a second G-buffer fetch.

### Draw order in VR

The post-process quad has no depth test and covers the frame. Anything that must
remain readable *through* the sensor image is therefore drawn after it, by
render priority:

| Priority | Layer |
| --- | --- |
| 100 | payload post-process |
| 106 | controller laser |
| 108 | world beacon labels |
| 110 | contact briefing cards |
| 112 | cockpit frame |
| 118–119 | instrument panel and its backing |

This is the bug that is invisible on a flat screen, where the HUD is a
`CanvasLayer` composited after 3D and never interacts with the post-process at
all. In VR the interface is geometry, and it has to earn its place in the sort.

---

## Flight model

`RigidBody3D` with explicit torque control rather than four independent rotor
forces. Lift is applied along the airframe's local up axis; attitude is a
PD controller producing an angular acceleration, converted to torque through an
explicit inertia tensor.

```
STABILIZED: stick → target attitude angle
            centred sticks → lean against horizontal velocity (position brake)
            centred throttle → hold the altitude captured on release
ACRO:       stick → target body rate
```

The four-motor mixer still exists but drives only prop RPM, rotor-wash intensity
and motor-damage state — the flight response itself is resolved before it.
Keeping the visuals downstream of the physics means a damaged motor visibly
spins slower without the flight model needing a second code path.

Also modelled: ground effect within one rotor diameter, quadratic drag against
the *relative* wind (so gusts move the aircraft), battery drain as a function of
thrust with voltage sag, and prop-strike damage on hard contact.

---

## Detection

Confidence is assembled from four terms — range, off-boresight angle, line of
sight, and the active sensor's advantage against that target class:

```
confidence = (0.35 + 0.45·range_score + 0.20·angle_score)
           × sensor_advantage(target, mode)
           × (1.0 if clear line of sight else 0.28)
```

`sensor_advantage` is where the argument of the project lives: a person has a
`thermal_contrast` of 1.0, so thermal multiplies their detection confidence by
2.35, while a structural defect gets nothing from it. A contact must hold above
the logging threshold for about a second before it is recorded, which stops a
momentary glimpse through rubble from filling the report.

---

## Input

Every control path converges on the same `InputMap` actions. The VR bridge reads
the OpenXR controllers and injects them with `Input.action_press(action,
strength)` rather than reading them inside the flight model.

That is a deliberate choice: it means there is exactly one flight-control code
path, so anything verified on the desktop build behaves identically in the
headset, and the keyboard mapping cannot silently drift away from the controller
mapping.

---

## Scene construction

`scenes/main.tscn` contains a single node. Everything else — the terrain mesh,
the structures, the drone, its sensors, the interface — is built in code.

This is unusual, and it is deliberate. The rotor positions have to match the
flight model's arm length, the gas sensor has to sit clear of the prop wash, the
hazard field has to agree with the particle effects, and the terrain's collision
has to agree with the height function the prop scatter samples. Holding those
relationships in a scene file means they can be edited apart; holding them in
code means they cannot.

The cost is that the scene is not editable in the Godot inspector. For a project
where the geometry is procedural anyway, that is a cheap price.

---

## Terrain

A 420 m heightfield at 2.5 m resolution, generated from a crater profile plus
four octaves of value noise, with the launch pad flattened by a Gaussian.
Tangents are generated with `SurfaceTool` because the terrain shader writes
`NORMAL_MAP`, and collision is a `ConcavePolygonShape3D` built from the same
vertex data, so the physics and the visible surface cannot drift.

The material blends three CC0 texture sets by position: asphalt along the access
corridor, pulverised rubble inside the crater lip, damaged concrete elsewhere,
with the boundaries broken up by noise so the transitions do not read as drawn
circles.

---

## Testing

`--selftest` flies the aircraft through nine stops, each declaring what it is
supposed to find, and asserts against the scenario rather than against "did
anything happen":

```bash
Godot_v4.5-stable_win64_console.exe --headless --path . -- --selftest
```

113 checks covering sensor finiteness and range, gas presence in the field
versus what reaches the display, oxygen depletion, thermal contrast at hot
spots, proximity reporting, battery, findings logging, beacon spawning and
report export. It exits non-zero on failure, so it can be run in CI.

The stops hold for nine seconds each because the detector cells have a T90 of
12–25 seconds. An earlier version held for a third of a second and "failed" —
correctly, as it turned out: it was measuring the filter rather than the
scenario.

There is also a screenshot harness (`--capture=<path> --capture-after=<frames>`,
plus `--vision=`, `--view=`, `--pos=`, `--look=`, `--time=`) used to verify the
rendering path without a human at the controls.
