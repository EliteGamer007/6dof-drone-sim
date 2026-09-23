"""Lay out scenes/main.tscn from the site plan below.

Run:  python tools/gen_main_scene.py

This is the *initial* layout. Once it has been generated, main.tscn is the
source of truth: open it in Godot and drag things wherever they should be.
Re-running this script overwrites those edits, except for the Survivors node,
which is always carried over from the existing file untouched.

Every position is (x, z) on the ground. The height is computed here from the
same terrain function the game uses (scripts/world/terrain.gd), but it only
has to be close - every piece seats itself on the terrain when it loads.
"""

from __future__ import annotations

import math
import os
import random
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "scenes", "main.tscn")

# ------------------------------------------------------------ terrain port
# Mirrors Terrain.height() in scripts/world/terrain.gd.

EPICENTRE = (0.0, -12.0)
CRATER_RADIUS, CRATER_DEPTH = 58.0, 9.5
PAD = (0.0, 96.0)


def _hash2(x, y):
    v = math.sin(x * 127.1 + y * 311.7) * 43758.5453
    return v - math.floor(v)


def _noise(px, py):
    ix, iy = math.floor(px), math.floor(py)
    fx, fy = px - ix, py - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = _hash2(ix, iy), _hash2(ix + 1, iy)
    c, d = _hash2(ix, iy + 1), _hash2(ix + 1, iy + 1)
    top, bottom = a + (b - a) * fx, c + (d - c) * fx
    return top + (bottom - top) * fy


def _fbm(px, py):
    total = norm = 0.0
    amp = freq = 1.0
    for _ in range(4):
        total += _noise(px * freq, py * freq) * amp
        norm += amp
        amp *= 0.5
        freq *= 2.07
    return (total / norm) * 2.0 - 1.0


def ground(x, z):
    d = math.hypot(x - EPICENTRE[0], z - EPICENTRE[1])
    h = 0.0
    if d < CRATER_RADIUS:
        t = d / CRATER_RADIUS
        h -= CRATER_DEPTH * (1 - t * t) * (1 - t * 0.35)
    h += math.exp(-((d - CRATER_RADIUS * 1.06) / 22.0) ** 2) * 3.2
    w = max(0.25, min(1.4, 1.4 - d / 150.0))
    h += _fbm(x * 0.035, z * 0.035) * 2.1 * w
    h += _fbm(x * 0.14 + 19.0, z * 0.14 + 7.0) * 0.55 * w
    pad = max(0.0, min(0.92, math.exp(-(math.hypot(x - PAD[0], z - PAD[1]) / 14.0) ** 2)))
    return h + (0.35 - h) * pad


# -------------------------------------------------------------- site plan

VAN = (0.0, 96.0, 8.0)

STAGING_KIT = [   # model, x, z, yaw
    ("portable_searchlight", -4.2, 93.2, 42.0), ("portable_generator", -5.0, 95.4, 100.0),
    ("wooden_crate_01", 4.4, 94.0, 18.0), ("plastic_crate_01", 4.9, 95.6, 200.0),
    ("metal_toolbox", 3.9, 96.8, 72.0), ("tool_cart", -4.6, 99.0, 140.0),
    ("street_lamp_01", -11.5, 103.0, 18.0),
]
CORDON_ANGLES = [-62.0, -34.0, 34.0, 62.0, 118.0, 152.0, 208.0, 242.0]

SITE = [   # scene, node name, x, z, yaw, extra properties
    ("grain_silos", "GrainSilos", -54.0, -66.0, 0.0, {}),
    ("warehouse", "Warehouse", 46.0, -34.0, 0.0, {}),
    ("collapsed_block", "CollapsedBlock", -38.0, 34.0, 0.0, {}),
    ("container_yard", "ContainerYard", 24.0, 48.0, 0.0, {}),
    ("pipe_corridor", "PipeCorridor", -70.0, 8.0, 0.0, {}),
    ("collapsed_crane", "CollapsedCrane", 38.0, 52.0, -12.0, {}),
    ("harbour", "Harbour", -1.0, -122.0, 0.0, {}),
]

# (name, x, z, width, height, depth, collapse). Spread round the site rather
# than piled up behind the launch point: three stand behind the silos and the
# warehouse, where the horizon used to be empty.
RUINS = [
    ("NorthTerrace", -58.0, 132.0, 18.0, 22.0, 14.0, 0.62),
    ("HarbourOffices", -16.0, 148.0, 24.0, 15.0, 16.0, 0.30),
    ("CornerShops", 74.0, 120.0, 20.0, 19.0, 15.0, 0.45),
    ("SiloWestA", -100.0, -60.0, 16.0, 26.0, 13.0, 0.75),
    ("SiloWestB", -96.0, -96.0, 15.0, 17.0, 12.0, 0.55),
    ("DockOffice", 92.0, -100.0, 22.0, 24.0, 17.0, 0.35),
    ("Terrace3", -84.0, -22.0, 16.0, 18.0, 13.0, 0.55),
    ("Flats", -22.0, 60.0, 19.0, 12.0, 15.0, 0.85),
    ("Depot", 64.0, 10.0, 15.0, 20.0, 12.0, 0.40),
    ("Pancaked", 26.0, -80.0, 18.0, 9.0, 14.0, 1.00),
    ("Stores", 78.0, -68.0, 20.0, 16.0, 16.0, 0.70),
    ("Garages", -88.0, 58.0, 17.0, 11.0, 13.0, 0.95),
    ("Tower", -70.0, -78.0, 14.0, 21.0, 12.0, 0.25),
]

GAS_LEAKS = [   # name, x, z, gas, strength, radius, length, tank, label
    ("LpgLeak", -46.0, 10.0, 3, 78.0, 3.4, 30.0, "small_lpg_tank",
     "Ruptured LPG line under the pipe rack"),
    ("PropaneLeak", 44.0, -22.0, 3, 55.0, 2.6, 22.0, "propane_tank",
     "Propane cylinder venting inside the warehouse"),
    ("CraterNO2", -6.0, -20.0, 2, 14.0, 9.0, 46.0, "",
     "Residual nitrogen dioxide over the detonation seat"),
    ("DrainageH2S", -34.0, 40.0, 1, 34.0, 4.2, 18.0, "",
     "Hydrogen sulphide from the drainage void under the collapse"),
    ("ContainerYardCO", 26.0, 44.0, 0, 260.0, 3.0, 26.0, "metal_jerrycan",
     "Fuel fire smouldering in the container yard"),
    ("SiloO2", -52.0, -60.0, 4, 3.8, 5.0, 8.0, "",
     "Oxygen-deficient atmosphere inside the ruptured silo"),
]

FIRES = [
    ("ContainerYardFire", 30.0, 40.0, 1.35, "Container yard fire"),
    ("SiloApronFire", -18.0, -44.0, 0.9, "Burning debris on the silo apron"),
    ("WarehouseDoorFire", 52.0, -8.0, 0.65, "Vehicle fire at the warehouse door"),
]

STRUCTURAL = [   # name, x, y (absolute), z, label, detail, action
    ("RupturedSiloWall", -46.0, 6.0, -66.0, "Ruptured silo wall",
     "Vertical crack running the full height of the silo shell. Any further movement "
     "drops several hundred tonnes onto the apron below, which is the only vehicle "
     "route into the site.", "Exclusion zone 30 m. Survey by air only."),
    ("UnsupportedSlabEdge", -30.0, 9.0, 34.0, "Unsupported slab edge",
     "The upper floor slab is cantilevered over the void with no remaining column "
     "support on its northern edge.", "Prop before any rescuer enters the void beneath."),
    ("DisplacedRoofTruss", 46.0, 8.0, -20.0, "Displaced roof truss",
     "Roof truss has dropped at one end and is resting on stacked material rather than "
     "its seat.", "Stabilise the truss before working under it."),
]

SIGNS = [
    ("SiloExclusion", -44.0, -50.0, 24.0, "Silo exclusion zone", "0.95, 0.78, 0.1, 1"),
    ("FlammableAtmosphere", -42.0, 16.0, -68.0, "Flammable atmosphere", "0.92, 0.2, 0.16, 1"),
    ("ActiveFire", 24.0, 44.0, 150.0, "Active fire - no entry", "0.92, 0.2, 0.16, 1"),
]

DRUM_CLUSTERS = [
    (38.0, -24.0, 5), (-30.0, -34.0, 4), (56.0, 30.0, 4), (-62.0, 30.0, 5),
    (12.0, 30.0, 3), (-14.0, -62.0, 4), (70.0, -50.0, 3), (-78.0, -14.0, 4),
    (30.0, 66.0, 3), (-40.0, 62.0, 3),
]
DRUM_MODELS = [("Barrel_01", 1.15), ("Barrel_02", 0.95), ("barrel_03", 0.95),
               ("propane_tank", 1.35), ("small_lpg_tank", 1.2)]


# ------------------------------------------------------------ tscn output

class Scene:
    def __init__(self):
        self.ext = []          # (type, path, id, uid)
        self.nodes = []

    def ext_res(self, kind, path, uid=None):
        for e in self.ext:
            if e[1] == path:
                return e[2]
        rid = "%d_%s" % (len(self.ext) + 1, os.path.splitext(os.path.basename(path))[0])
        self.ext.append((kind, path, rid, uid))
        return rid

    def node(self, name, parent, *, type_=None, instance=None, xform=None, props=None):
        head = '[node name="%s"' % name
        if type_:
            head += ' type="%s"' % type_
        if parent is not None:
            head += ' parent="%s"' % parent
        if instance:
            head += ' instance=ExtResource("%s")' % instance
        head += "]"
        body = [head]
        if xform:
            body.append("transform = %s" % xform)
        for k, v in (props or {}).items():
            body.append("%s = %s" % (k, v))
        self.nodes.append("\n".join(body))

    def text(self, tail=""):
        out = ['[gd_scene load_steps=%d format=3 uid="uid://ekvakpcg0gvd"]' % (len(self.ext) + 1), ""]
        for kind, path, rid, uid in self.ext:
            u = ' uid="%s"' % uid if uid else ""
            out.append('[ext_resource type="%s"%s path="%s" id="%s"]' % (kind, u, path, rid))
        out.append("")
        return "\n".join(out) + "\n" + "\n\n".join(self.nodes) + "\n" + tail


def xform(x, y, z, yaw_deg=0.0):
    c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    f = lambda v: ("%.6f" % v).rstrip("0").rstrip(".") if abs(v) > 1e-9 else "0"
    return "Transform3D(%s, 0, %s, 0, 1, 0, %s, 0, %s, %s, %s, %s)" % (
        f(c), f(s), f(-s), f(c), f(x), f(y), f(z))


def at(x, z, yaw=0.0, lift=0.0):
    return xform(x, ground(x, z) + lift, z, yaw)


def gd_string(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def main():
    old = open(MAIN, encoding="utf8").read()
    uid_of = {}
    for m in re.finditer(r'\[ext_resource type="[^"]+" (?:uid="([^"]+)" )?path="([^"]+)"', old):
        if m.group(1):
            uid_of[m.group(2)] = m.group(1)
    survivors = old[old.index('[node name="Survivors"'):]

    sc = Scene()
    r_main = sc.ext_res("Script", "res://scripts/main.gd", uid_of.get("res://scripts/main.gd"))
    r_world = sc.ext_res("Script", "res://scripts/world/world_builder.gd",
                         uid_of.get("res://scripts/world/world_builder.gd"))
    r_drone = sc.ext_res("PackedScene", "res://scenes/drone.tscn")
    r_victim = sc.ext_res("PackedScene", "res://scenes/victim.tscn",
                          uid_of.get("res://scenes/victim.tscn"))
    survivors = re.sub(r'instance=ExtResource\("[^"]+"\)', 'instance=ExtResource("%s")' % r_victim,
                       survivors)

    def scene(rel):
        return sc.ext_res("PackedScene", "res://scenes/%s.tscn" % rel)

    sc.node("Main", None, type_="Node3D", props={"script": 'ExtResource("%s")' % r_main})
    sc.node("World", ".", type_="Node3D",
            props={"script": 'ExtResource("%s")' % r_world, "place_victims": "false"})
    sc.node("Drone", ".", instance=r_drone, xform=xform(0, 1.8, 96))

    # --- staging area --------------------------------------------------
    sc.node("StagingArea", ".", type_="Node3D")
    sc.node("ResponseVan", "StagingArea", instance=scene("staging/response_van"),
            xform=at(VAN[0], VAN[1], VAN[2]))
    sc.node("WindMast", "StagingArea", instance=scene("staging/wind_mast"), xform=at(-20, 84))
    prop = scene("props/prop_model")
    sc.node("Cordon", "StagingArea", type_="Node3D")
    for i, a in enumerate(CORDON_ANGLES):
        x = math.sin(math.radians(a)) * 8.5
        z = VAN[1] + math.cos(math.radians(a)) * 8.5
        sc.node("Barrier%d" % (i + 1), "StagingArea/Cordon", instance=prop, xform=at(x, z, a + 90),
                props={"model_name": '"concrete_road_barrier"'})
    sc.node("Kit", "StagingArea", type_="Node3D")
    for model, x, z, yaw in STAGING_KIT:
        name = "".join(w.capitalize() for w in model.split("_") if not w.isdigit())
        sc.node(name, "StagingArea/Kit", instance=prop, xform=at(x, z, yaw),
                props={"model_name": gd_string(model)})

    # --- response ------------------------------------------------------
    sc.node("Response", ".", type_="Node3D")
    sc.node("CasualtyPoint", "Response", instance=scene("staging/casualty_point"),
            xform=at(26, 78, -24))
    sc.node("Ambulance", "Response", instance=scene("staging/ambulance"),
            xform=at(18.81, 76.44, -12))
    sc.node("FireAppliance", "Response", instance=scene("staging/fire_appliance"),
            xform=at(38, 32, 158))
    sc.node("AccessRoute", "Response", instance=scene("staging/access_route"),
            xform=xform(0, 0, 0))

    # --- site ----------------------------------------------------------
    sc.node("Site", ".", type_="Node3D")
    for rel, name, x, z, yaw, extra in SITE:
        sc.node(name, "Site", instance=scene("structures/" + rel), xform=at(x, z, yaw),
                props=extra)

    # --- city ----------------------------------------------------------
    rng = random.Random(20200804)
    sc.node("City", ".", type_="Node3D")
    ruin = scene("structures/ruined_building")
    for name, x, z, w, h, d, collapse in RUINS:
        sc.node(name, "City", instance=ruin, xform=at(x, z, rng.uniform(0, 360)), props={
            "seed": str(rng.randint(1, 9999)), "width": "%.1f" % w, "height": "%.1f" % h,
            "depth": "%.1f" % d, "collapse": "%.2f" % collapse})

    # --- hazards -------------------------------------------------------
    sc.node("Hazards", ".", type_="Node3D")
    sc.node("GasLeaks", "Hazards", type_="Node3D")
    gas = scene("hazards/gas_leak")
    for name, x, z, g, strength, radius, length, tank, label in GAS_LEAKS:
        sc.node(name, "Hazards/GasLeaks", instance=gas, xform=at(x, z, 0, 0.6), props={
            "label": gd_string(label), "gas": str(g), "strength": "%.1f" % strength,
            "plume_radius": "%.1f" % radius, "plume_length": "%.1f" % length,
            "visible_vapour": "true" if g in (2, 3) else "false"})
        if tank:
            sc.node("Tank", "Hazards/GasLeaks/" + name, instance=prop,
                    xform=xform(0, 0, 0, rng.uniform(0, 360)),
                    props={"model_name": gd_string(tank)})
    sc.node("Fires", "Hazards", type_="Node3D")
    fire = scene("hazards/fire")
    for name, x, z, intensity, label in FIRES:
        sc.node(name, "Hazards/Fires", instance=fire, xform=at(x, z, 0, 0.1),
                props={"label": gd_string(label), "intensity": "%.2f" % intensity})
    sc.node("Structural", "Hazards", type_="Node3D")
    structural = scene("hazards/structural_hazard")
    for name, x, y, z, label, detail, action in STRUCTURAL:
        sc.node(name, "Hazards/Structural", instance=structural, xform=xform(x, y, z), props={
            "label": gd_string(label), "detail": gd_string(detail),
            "recommended_action": gd_string(action)})
    sc.node("Signs", "Hazards", type_="Node3D")
    sign = scene("props/hazard_sign")
    for name, x, z, yaw, text, colour in SIGNS:
        sc.node(name, "Hazards/Signs", instance=sign, xform=at(x, z, yaw),
                props={"text": gd_string(text), "board_colour": "Color(%s)" % colour})

    # --- drums ---------------------------------------------------------
    sc.node("ExplosiveDrums", ".", type_="Node3D")
    drum = scene("props/explosive_drum")
    n = 0
    for cx, cz, count in DRUM_CLUSTERS:
        for _ in range(count):
            x, z = cx + rng.uniform(-3.4, 3.4), cz + rng.uniform(-3.4, 3.4)
            if math.hypot(x - PAD[0], z - PAD[1]) < 19.0:
                continue
            model, power = rng.choice(DRUM_MODELS)
            n += 1
            sc.node("Drum%02d" % n, "ExplosiveDrums", instance=drum,
                    xform=at(x, z, rng.uniform(0, 360)),
                    props={"model_name": gd_string(model), "power": "%.2f" % power})

    text = sc.text("\n" + survivors.rstrip() + "\n")
    open(MAIN, "w", encoding="utf8", newline="\n").write(text)
    print("wrote %s: %d nodes, %d drums" % (os.path.relpath(MAIN, ROOT),
                                            text.count("[node "), n))


if __name__ == "__main__":
    main()
