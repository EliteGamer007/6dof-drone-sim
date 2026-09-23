"""Generate project.godot (the input map is long and easy to typo by hand).

Run:  python tools/gen_project_godot.py
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- Godot key constants we use --------------------------------------------
K = {
    "A": 65, "B": 66, "C": 67, "D": 68, "E": 69, "F": 70, "G": 71, "H": 72,
    "I": 73, "J": 74, "K": 75, "L": 76, "M": 77, "N": 78, "O": 79, "P": 80,
    "Q": 81, "R": 82, "S": 83, "T": 84, "U": 85, "V": 86, "W": 87, "X": 88,
    "Y": 89, "Z": 90,
    "1": 49, "2": 50, "3": 51, "4": 52, "5": 53, "6": 54, "7": 55, "8": 56,
    "9": 57, "0": 48,
    "SPACE": 32, "BRACKETLEFT": 91, "BRACKETRIGHT": 93, "COMMA": 44, "PERIOD": 46,
    "ESCAPE": 4194305, "TAB": 4194306, "BACKSPACE": 4194308, "ENTER": 4194309,
    "DELETE": 4194312, "HOME": 4194317, "END": 4194318,
    "LEFT": 4194319, "UP": 4194320, "RIGHT": 4194321, "DOWN": 4194322,
    "PAGEUP": 4194323, "PAGEDOWN": 4194324,
    "SHIFT": 4194325, "CTRL": 4194326, "ALT": 4194328,
    "F1": 4194332, "F2": 4194333, "F3": 4194334, "F4": 4194335,
}

# --- Godot 4 JoyButton -------------------------------------------------------
JB = {
    "A": 0, "B": 1, "X": 2, "Y": 3, "BACK": 4, "GUIDE": 5, "START": 6,
    "LS": 7, "RS": 8, "LB": 9, "RB": 10,
    "DPAD_UP": 11, "DPAD_DOWN": 12, "DPAD_LEFT": 13, "DPAD_RIGHT": 14,
}

# --- Godot 4 JoyAxis ---------------------------------------------------------
JA = {"LX": 0, "LY": 1, "RX": 2, "RY": 3, "LT": 4, "RT": 5}


def key(name: str) -> str:
    code = K[name]
    return (
        'Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"",'
        '"device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,'
        '"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,'
        f'"physical_keycode":{code},"key_label":0,"unicode":0,"location":0,'
        '"echo":false,"script":null)'
    )


def btn(name: str) -> str:
    return (
        'Object(InputEventJoypadButton,"resource_local_to_scene":false,'
        f'"resource_name":"","device":-1,"button_index":{JB[name]},"pressure":0.0,'
        '"pressed":true,"script":null)'
    )


def axis(name: str, value: float) -> str:
    return (
        'Object(InputEventJoypadMotion,"resource_local_to_scene":false,'
        f'"resource_name":"","device":-1,"axis":{JA[name]},"axis_value":{value:.1f},'
        '"script":null)'
    )


def mouse(button_index: int) -> str:
    return (
        'Object(InputEventMouseButton,"resource_local_to_scene":false,'
        '"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,'
        '"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,'
        '"button_mask":0,"position":Vector2(0, 0),"global_position":Vector2(0, 0),'
        '"factor":1.0,'
        f'"button_index":{button_index},"canceled":false,"pressed":true,'
        '"double_click":false,"script":null)'
    )


# action -> (deadzone, [events])
ACTIONS: dict[str, tuple[float, list[str]]] = {
    # ---- flight -------------------------------------------------------------
    # Same gamepad layout as project-test (RT/LT lift, left stick move, right
    # stick X turn), plus a normal WASD keyboard layout. Nothing inverted.
    "throttle_up":   (0.2, [axis("RT", 1.0), key("SPACE")]),
    "throttle_down": (0.2, [axis("LT", 1.0), key("SHIFT")]),
    "pitch_up":      (0.2, [axis("LY", -1.0), key("W"), key("UP")]),
    "pitch_down":    (0.2, [axis("LY", 1.0), key("S"), key("DOWN")]),
    "roll_left":     (0.2, [axis("LX", -1.0), key("A")]),
    "roll_right":    (0.2, [axis("LX", 1.0), key("D")]),
    "yaw_left":      (0.2, [axis("RX", -1.0), key("Q"), key("LEFT")]),
    "yaw_right":     (0.2, [axis("RX", 1.0), key("E"), key("RIGHT")]),
    "precision_mode": (0.5, [btn("LS"), key("CTRL")]),
    "reset_drone":   (0.5, [btn("START"), key("BACKSPACE")]),
    # Autopilot and payload. The pad buttons were freed by moving a few
    # rarely-used functions to the keyboard only.
    "return_home":   (0.5, [btn("DPAD_DOWN"), key("H")]),
    "orbit_poi":     (0.5, [btn("RS"), key("J")]),
    "drop_supply":   (0.5, [btn("DPAD_LEFT"), key("Z")]),
    "toggle_avoidance":   (0.5, [key("N")]),
    # ---- camera / gimbal ----------------------------------------------------
    # RB is the camera switch: it is the button the thumb is already near.
    "switch_camera": (0.5, [btn("RB"), btn("BACK"), key("C")]),
    "gimbal_up":     (0.25, [axis("RY", -1.0), key("R")]),
    "gimbal_down":   (0.25, [axis("RY", 1.0), key("F")]),
    "gimbal_center": (0.5, [key("G")]),
    "zoom_in":       (0.5, [key("PAGEUP"), mouse(4)]),
    "zoom_out":      (0.5, [key("PAGEDOWN"), mouse(5)]),
    "free_look":     (0.5, [mouse(2)]),
    # ---- vision modes -------------------------------------------------------
    "vision_next":   (0.5, [btn("Y"), key("V")]),
    "vision_prev":   (0.5, [key("COMMA")]),
    # One button straight to thermal and straight back again - the sensor the
    # demo is about should never be three presses away.
    "toggle_thermal": (0.5, [btn("LB"), key("2"), key("T")]),
    "vision_normal": (0.5, [key("1")]),
    "vision_night":  (0.5, [key("3")]),
    "vision_gas":    (0.5, [key("4")]),
    "thermal_palette": (0.5, [key("M")]),
    # B is the detonate key on both, which is why the palette moved to M.
    "detonate":      (0.5, [btn("B"), key("B")]),
    "toggle_trail":  (0.5, [key("K")]),
    # ---- mission ------------------------------------------------------------
    "drop_marker":   (0.5, [btn("A"), key("X")]),
    "capture_photo": (0.5, [btn("X"), key("P")]),
    "toggle_spotlight": (0.5, [btn("DPAD_UP"), key("L")]),
    "toggle_report": (0.5, [key("TAB")]),
    "toggle_help":   (0.5, [key("F1")]),
    "toggle_hud":    (0.5, [btn("DPAD_RIGHT"), key("F2")]),
    "cycle_map_zoom": (0.5, [key("O")]),
    "time_forward":  (0.5, [key("BRACKETRIGHT")]),
    "time_back":     (0.5, [key("BRACKETLEFT")]),
    "pause_menu":    (0.5, [key("ESCAPE")]),
}


def render_actions() -> str:
    out = ["[input]", ""]
    for name, (deadzone, events) in ACTIONS.items():
        out.append(f"{name}={{")
        out.append(f'"deadzone": {deadzone},')
        out.append('"events": [' + ", ".join(events))
        out.append("]")
        out.append("}")
    return "\n".join(out)


TEMPLATE = """; Engine configuration file.
; Generated by tools/gen_project_godot.py - edit that script, not this file,
; if you need to change the input map.

config_version=5

[application]

config/name="Beirut Port SAR Drone Simulator"
config/description="Search-and-rescue drone simulation over a post-blast industrial zone. Educational reconstruction."
config/version="1.0.0"
run/main_scene="res://scenes/main.tscn"
config/features=PackedStringArray("4.5", "Forward Plus")
config/icon="res://icon.svg"
boot_splash/show_image=false

[autoload]

Sim="*res://scripts/autoload/sim.gd"
Hazards="*res://scripts/autoload/hazards.gd"
Sfx="*res://scripts/autoload/sfx.gd"

[display]

window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/mode=2
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"

[xr]

openxr/enabled={openxr}
openxr/default_action_map="res://openxr_action_map.tres"
shaders/enabled=true

[physics]

3d/default_gravity=9.81
common/physics_ticks_per_second=60
; The aircraft moves at the physics rate and the screen draws faster than that.
; Interpolation renders every moving body between its last two physics states,
; which is what removes the stepping from strafe and climb. The jitter fix is
; the older workaround for the same problem and fights interpolation, so off.
common/physics_interpolation=true
common/physics_jitter_fix=0.0

[rendering]

renderer/rendering_method="forward_plus"
anti_aliasing/quality/msaa_3d=0
anti_aliasing/quality/screen_space_aa=1
lights_and_shadows/directional_shadow/soft_shadow_filter_quality=3
environment/defaults/default_clear_color=Color(0.05, 0.06, 0.08, 1)
textures/default_filters/anisotropic_filtering_level=3
global_illumination/gi/use_half_resolution=true

{input}
"""


def main() -> None:
    # OpenXR is switched on only for the headset demo. Godot asks the OpenXR
    # loader for a runtime during engine init, and on a machine with no runtime
    # installed that call blocks for over a minute before giving up - so the
    # flat build, which is what you test with, leaves it off.
    openxr = "true" if "--vr" in sys.argv else "false"
    text = TEMPLATE.format(input=render_actions(), openxr=openxr)
    path = os.path.join(ROOT, "project.godot")
    with open(path, "w", encoding="utf8", newline="\n") as f:
        f.write(text)
    print(f"wrote {path} ({len(ACTIONS)} actions, openxr={openxr})")


if __name__ == "__main__":
    main()
