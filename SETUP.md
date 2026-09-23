# Getting it running

Clone, open, press F5. Everything the simulator needs is in the repository —
there is no asset download step, no package manager, and nothing to configure.

---

## 1. Get Godot 4.5

Download **Godot 4.5 (standard, not .NET)** from
<https://godotengine.org/download>. It is a single executable; there is no
installer and nothing else to set up.

This project is built and tested against `Godot_v4.5-stable`, Forward+
renderer. It will not open correctly in Godot 3.x.

## 2. Clone

```bash
git clone https://github.com/EliteGamer007/6dof-drone-sim.git
```

About 210 MB, which on a normal connection is a couple of minutes. If you only
want to run it and never push, add `--depth 1` to skip the history.

## 3. Open it

Launch Godot, click **Import**, and pick the `project.godot` file inside the
folder you just cloned.

**The first open takes two to five minutes and looks like it has frozen. It has
not.** Godot is importing every texture, mesh and HDRI in `assets/` and writing
the results into a local `.godot/` folder. That folder is deliberately not in
the repository — it is over 500 MB of derived data and it is not portable
between machines. It is built once, on your machine, and then reused.

Let it finish. When the editor window appears with the project tree, it is
done.

## 4. Run it

Press **F5**, or the ▶ button at the top right.

If Godot asks which scene to run, choose `scenes/main.tscn`.

You should get the briefing screen. Press **Space** to launch.

---

## Controls, quickly

Full tables are in the main [README](README.md), and `F1` brings them up in
game at any time.

Arcade flight model (the default):

| | Keyboard | Gamepad |
| --- | --- | --- |
| Move | `W` `A` `S` `D` | Left stick |
| Up / down | `Space` / `Shift` | RT / LT |
| Turn | `Q` `E` | Right stick |
| Thermal camera on/off | `2` or `T` | LB |
| Camera view | `C` | RB |
| Tag a survivor | `X` | A |
| Return to the van | `H` | D-pad down |
| Drop a first-aid kit | `Z` | D-pad left |
| Detonate a fuel drum | `B` | B |
| Settings | `Esc` | — |

`Esc` -> Flight model switches to **Flight sim**: point the nose with the left
stick, RT to accelerate, LT to brake.

---

## Troubleshooting

**It hangs on a black window for over a minute at startup, before the editor
even appears.**
That is OpenXR looking for a VR runtime that is not installed. The repository
ships with OpenXR **off**, so this should not happen — but if someone has
turned it on, switch it back:

```bash
./vr_mode.sh off        # macOS / Linux
vr_mode off             # Windows
```

`on` instead of `off` turns it back on. Only launch with OpenXR on if a
headset is already connected.

**It runs, but slowly.**
Press `Esc` and set **Graphics** to `LOW`. That drops everything costing a
full-screen pass and is the preset for integrated graphics. `MEDIUM` is the
default; use `HIGH` only for recording.

**The thermal camera shows nothing interesting.**
Press `Esc` and set **Time of day** to `NIGHT` or `DUSK`. At `DAY` everything
has been sitting in the sun and there is genuinely very little thermal
contrast — that is the physics, not a bug, and it is a large part of why the
scenario is set at dusk.

**Godot says a resource is missing, or the scene opens with broken nodes.**
Close Godot, delete the `.godot/` folder, and open the project again to force a
clean re-import.

**Git says files are modified that I never touched.**
You have an old clone made before `.gitattributes` existed. Run:

```bash
git rm --cached -r . && git reset --hard
```

---

## For whoever is adding models

Drop `.glb` or `.gltf` files into `assets/team/` and list where they go in
`assets/team/placement.json`. The format is documented in
`assets/team/README.md`. If that folder is empty the scene builds exactly as it
does now, so you can work on models without blocking anyone and merge by adding
one file.

Please do not commit a `.godot/` folder, an `export_presets.cfg`, or anything
from `shots/` — `.gitignore` already covers all three.

---

## Checking nothing is broken

Two headless harnesses, neither of which needs a window:

```bash
godot --headless --path . -- --selftest
```

Flies the aircraft through the whole site, exercises every sensor and every
action that writes something out, and prints `PASS` or a list of failures.
155 checks; it takes about 90 seconds.

```bash
godot --headless --path . -- --flighttest
```

Measures the handling: hands-off drift, time to reach cruise speed, stopping
distance and yaw. Prints the numbers rather than asserting on them, because a
regression here is a feel problem rather than a pass/fail one.

Run the first one before you push.
