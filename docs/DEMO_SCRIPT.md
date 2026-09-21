# Demo script

A seven-minute run that shows every system doing something, in an order that
builds an argument rather than just listing features. Written for the headset;
the flat-screen key for each step is in brackets.

Before you start: headset connected, then `vr_mode on`, then launch. Check the
gas readout is on your left wrist and that you can see the instrument panel by
looking down.

---

## 0. The opening screen — 20 seconds

Leave the briefing up while you say what the scenario is. It carries the content
note, so the framing is on screen rather than only in your voice: this is a
reconstruction of an assessment task, not a re-enactment of the event.

Push the throttle up to launch. *(Flat: `W`, or `E`.)*

---

## 1. "Here is the site, and here is why nobody can walk into it" — 1 minute

Climb to about 40 m and look around. Point out:

- the crater and the raised rim of ejecta at the centre,
- the ruptured silos to the north-west, the warehouse shell to the east,
- fires still burning in the container yard,
- that at this hour the light is going, which is exactly when these flights
  actually happen.

Fly a slow lap. The **survey map** in the lower left fills in as you go — that
is the coverage record, and the first question anyone asks about a drone survey
is which parts of the site were actually looked at.

---

## 2. The point of the whole thing: EO versus thermal — 1 minute 30

Descend towards the collapsed block at roughly `(-38, 34)` — the pancaked floor
slabs west of the crater.

**In EO**, hold on the rubble. Nobody is visible. Say so plainly: a grey person
in grey concrete at dusk is invisible to a camera, and this is where a visual
search stalls.

**Switch to thermal** *(right A / `2`)*. The casualties in the void light up.

Then put the reticle on one and let the detector settle — it logs the contact,
pings, and plants a beacon. The **contact briefing** appears: what it is, how
confident the detector is, and what the extraction team needs to know.

If you want the palette point, cycle it *(left grip / `B`)* — white hot, black
hot, ironbow, rainbow — and note the **thermal scale** on screen showing the
live gain window in degrees, so the false colour is readable rather than
decorative.

---

## 3. The atmosphere: what you cannot see at all — 1 minute 30

Fly west towards the pipe corridor at roughly `(-46, 10)`.

The **hiss** comes up in your headphones before anything appears on the
instruments. Follow it.

Watch the wrist readout: **LEL** starts climbing, the alarm changes tone, and
the panel border changes colour. Explain the two-stage alarm and that 100% LEL
is an atmosphere that ignites from any spark — including a drone motor.

Now **switch to the gas overlay** *(right A twice / `4`)*. The plume acquires a
shape and a direction: it is blowing downwind, it has a core, and you can see
where its edge is. Fly around it rather than through it, and say why that
matters — the numbers tell you the air is bad *where you are*; the overlay tells
you where to *not go next*.

Repeat briefly over the crater for **NO₂** — the signature product of an
ammonium nitrate detonation, and the reason the real plume was that colour.

---

## 4. Getting the information to somebody else — 1 minute

This is the part that usually gets skipped, so give it time.

- Tag a contact *(right trigger / `E`)*. A labelled beacon goes into the world
  and the finding goes into the log with coordinates.
- Capture a still *(right B / `P`)*. It is saved with the sensor mode and the
  position in the filename.
- Open the **report** *(left menu / `Tab`)*. Every finding, with position, time,
  severity and WGS84 coordinates, plus flight time, distance and coverage.
- From the settings menu, **Export mission report** writes it out as CSV.

The point: the aircraft's output is not a video, it is a list of located
problems that somebody on the ground can act on.

---

## 5. Flying it properly — 45 seconds

If there is time, and only if you are comfortable:

- Switch to **Acro** *(left X / `M`)* for a few seconds to show the difference
  between a self-levelling camera drone and a manual aircraft, then switch back.
- Fly close to a wall and let the **proximity ring** and its closing tone run
  up, then let the **obstacle assist** stop you.
- Mention the battery model — it drains with thrust and sags under load, and
  warns at 25%.

---

## 6. Closing — 20 seconds

Fly back over the pad and set down on the van's deck.

Close on the argument the demo has been making: the drone is not the point, and
neither is the headset. The point is that a single aircraft with the right two
sensors turns "we cannot enter that sector" into a list of specific, located,
classified problems in under ten minutes.

---

## If something goes wrong

| Problem | Fix |
| --- | --- |
| Startup hangs for a minute | OpenXR is on with no headset connected. `vr_mode off`. |
| Frame rate drops in the headset | Settings → Graphics preset → `VR`. |
| Motion discomfort | Settings → Motion vignette on, and turn *off* "View follows aircraft heading". |
| Lost the aircraft | Reset *(right menu / `Backspace`)* returns it to the pad with a fresh battery. |
| Nothing is detected | Contacts need about a second of steady view above 72% confidence before they log. Hold the reticle still. |
| Thermal looks flat | You are in daylight. Press `]` to advance time, or use Settings → "Jump to night". |
