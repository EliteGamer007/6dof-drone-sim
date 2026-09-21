"""Fetch the CC0 asset set used by the simulation from Poly Haven.

Everything downloaded here is CC0 (public domain) - no attribution is legally
required, but ASSETS/CREDITS.md is generated anyway because crediting is polite
and the course report asks for a licence trail.

Usage:  python tools/fetch_assets.py [--force]
"""

from __future__ import annotations

import concurrent.futures as futures
import hashlib
import json
import os
import sys
import urllib.parse
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) beirut-drone-sim/1.0"}
API = "https://api.polyhaven.com"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "polyhaven")

# --- what we pull -----------------------------------------------------------

HDRIS = [
    ("industrial_sunset_02_puresky", "2k"),   # dusk approach - best for thermal/NV demo
    ("kloofendal_overcast_puresky", "2k"),    # hazy daylight survey
    ("wasteland_clouds_puresky", "2k"),       # heavy smoke/dust day
]

# (id, resolution) - maps pulled: Diffuse, nor_gl, arm (= AO/Rough/Metal -> Godot ORM)
TEXTURES = [
    ("concrete_debris", "2k"),
    ("rubble", "2k"),
    ("damaged_concrete_floor", "2k"),
    ("asphalt_02", "2k"),
    ("cracked_concrete", "1k"),
    ("rust_coarse_01", "1k"),
    ("rustic_stone_wall", "1k"),
    # urban blast-wave zone: Beirut facades and warehouse cladding
    ("yellow_plaster_02", "1k"),
    ("beige_wall_001", "1k"),
    ("worn_cracked_plaster", "1k"),
    ("concrete_wall_008", "1k"),
    ("large_sandstone_blocks_01", "1k"),
    ("rusty_corrugated_iron", "1k"),
]

MODELS = [
    # obstacles / cover
    ("concrete_road_barrier", "1k"),
    ("concrete_road_barrier_02", "1k"),
    ("modular_chainlink_fence", "1k"),
    ("modular_industrial_pipes_01", "1k"),
    ("steel_frame_shelves_01", "1k"),
    # hazard sources (these carry the gas leaks in-scene)
    ("propane_tank", "1k"),
    ("small_lpg_tank", "1k"),
    ("metal_jerrycan", "1k"),
    ("Barrel_01", "1k"),
    ("Barrel_02", "1k"),
    ("barrel_03", "1k"),
    ("portable_generator", "1k"),
    # debris / clutter
    ("wooden_crate_01", "1k"),
    ("plastic_crate_01", "1k"),
    ("cardboard_box_01", "1k"),
    ("old_tyre", "1k"),
    ("cement_bag", "1k"),
    ("boulder_01", "1k"),
    ("rock_07", "1k"),
    ("namaqualand_boulder_02", "1k"),
    # street / vegetation
    ("street_lamp_01", "1k"),
    ("modular_electricity_poles", "1k"),
    ("fire_hydrant", "1k"),
    ("covered_car", "1k"),
    ("dead_tree_trunk", "1k"),
    ("dead_tree_trunk_02", "1k"),
    ("dry_branches_medium_01", "1k"),
    # street frontage, utilities and displaced interiors
    ("rollershutter_door", "1k"),
    ("rollershutter_window_01", "1k"),
    ("modular_electric_cables", "1k"),
    ("water_manhole_cover", "1k"),
    ("plastic_monobloc_chair_01", "1k"),
    ("Sofa_01", "1k"),
    ("painted_wooden_table", "1k"),
    ("rusted_wheel_rim_01", "1k"),
    # incident command post at the launch pad
    ("portable_searchlight", "1k"),
    ("tool_cart", "1k"),
    ("metal_toolbox", "1k"),
    ("industrial_storage_cart", "1k"),
]

TEXTURE_MAPS = ["Diffuse", "nor_gl", "arm"]


def api(path: str):
    req = urllib.request.Request(f"{API}/{path}", headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: str, expect_md5: str | None, force: bool) -> tuple[str, int]:
    if os.path.exists(dest) and not force:
        if expect_md5 is None or md5(dest) == expect_md5:
            return ("cached", os.path.getsize(dest))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(url, headers=UA)
    tmp = dest + ".part"
    with urllib.request.urlopen(req, timeout=300) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, dest)
    return ("fetched", os.path.getsize(dest))


def plan_hdri(asset_id: str, res: str, files: dict) -> list[tuple[str, str, str]]:
    entry = files["hdri"][res]["hdr"]
    dest = os.path.join(OUT, "hdris", f"{asset_id}_{res}.hdr")
    return [(entry["url"], dest, entry["md5"])]


def plan_texture(asset_id: str, res: str, files: dict) -> list[tuple[str, str, str]]:
    jobs = []
    for map_name in TEXTURE_MAPS:
        node = files.get(map_name)
        if not node or res not in node:
            continue
        fmt = "jpg" if "jpg" in node[res] else next(iter(node[res]))
        entry = node[res][fmt]
        name = urllib.parse.unquote(entry["url"].rsplit("/", 1)[-1])
        jobs.append((entry["url"], os.path.join(OUT, "textures", asset_id, name), entry["md5"]))
    return jobs


def plan_model(asset_id: str, res: str, files: dict) -> list[tuple[str, str, str]]:
    node = files.get("gltf", {}).get(res, {}).get("gltf")
    if node is None:
        return []
    base = os.path.join(OUT, "models", asset_id)
    name = urllib.parse.unquote(node["url"].rsplit("/", 1)[-1])
    jobs = [(node["url"], os.path.join(base, name), node["md5"])]
    for rel, entry in node.get("include", {}).items():
        jobs.append((entry["url"], os.path.join(base, *rel.split("/")), entry["md5"]))
    return jobs


def main() -> int:
    force = "--force" in sys.argv
    os.makedirs(OUT, exist_ok=True)

    groups = (
        [("hdris", i, r, plan_hdri) for i, r in HDRIS]
        + [("textures", i, r, plan_texture) for i, r in TEXTURES]
        + [("models", i, r, plan_model) for i, r in MODELS]
    )

    jobs: list[tuple[str, str, str]] = []
    credits: list[tuple[str, str, str]] = []
    for kind, asset_id, res, planner in groups:
        try:
            files = api(f"files/{asset_id}")
            info = api(f"info/{asset_id}")
        except Exception as exc:  # noqa: BLE001 - report and keep going
            print(f"  !! {kind}/{asset_id}: {exc}", flush=True)
            continue
        planned = planner(asset_id, res, files)
        if not planned:
            print(f"  !! {kind}/{asset_id}: no {res} files", flush=True)
            continue
        jobs += planned
        authors = ", ".join(info.get("authors", {}).keys()) or "Poly Haven"
        credits.append((kind, asset_id, authors))
        print(f"  .. {kind}/{asset_id} ({res}) -> {len(planned)} files", flush=True)

    print(f"\nDownloading {len(jobs)} files...", flush=True)
    total = 0
    failed = []
    with futures.ThreadPoolExecutor(max_workers=6) as pool:
        future_map = {pool.submit(download, u, d, m, force): d for u, d, m in jobs}
        for done in futures.as_completed(future_map):
            dest = future_map[done]
            try:
                status, size = done.result()
                total += size
                print(f"  {status:>7}  {os.path.relpath(dest, ROOT)}  ({size/1e6:.1f} MB)", flush=True)
            except Exception as exc:  # noqa: BLE001
                failed.append((dest, exc))
                print(f"  FAILED   {os.path.relpath(dest, ROOT)}: {exc}", flush=True)

    write_credits(credits)
    print(f"\nDone. {total/1e6:.1f} MB across {len(jobs)-len(failed)} files, {len(failed)} failed.")
    for dest, exc in failed:
        print(f"  failed: {dest}: {exc}")
    return 1 if failed else 0


def write_credits(credits: list[tuple[str, str, str]]) -> None:
    path = os.path.join(ROOT, "assets", "CREDITS.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [
        "# Asset credits",
        "",
        "## Poly Haven (CC0 1.0 - public domain, attribution not required)",
        "",
        "| Kind | Asset | Author(s) | Source |",
        "| --- | --- | --- | --- |",
    ]
    for kind, asset_id, authors in sorted(credits):
        lines.append(
            f"| {kind} | `{asset_id}` | {authors} | https://polyhaven.com/a/{asset_id} |"
        )
    lines += [
        "",
        "## Author-supplied",
        "",
        "| Asset | Origin |",
        "| --- | --- |",
        "| `assets/drone/*.glb` | DJI FPV model carried over from the author's `project-test` prototype. |",
        "| `assets/audio/*.wav` | Synthesised procedurally by `tools/make_audio.py` - no third-party rights. |",
        "",
        "## Fonts (SIL Open Font License 1.1)",
        "",
        "| Asset | Family | Source |",
        "| --- | --- | --- |",
        "| `assets/fonts/ui.ttf` | Barlow Semi Condensed Medium | https://github.com/jpt/barlow |",
        "| `assets/fonts/mono.ttf` | Share Tech Mono | https://fonts.google.com/specimen/Share+Tech+Mono |",
        "",
        "Generated by `tools/fetch_assets.py`.",
        "",
    ]
    with open(path, "w", encoding="utf8") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    raise SystemExit(main())
