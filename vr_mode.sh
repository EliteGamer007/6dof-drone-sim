#!/usr/bin/env bash
# Switch the project between the flat testing build and the VR demo build.
#
#   ./vr_mode.sh on    enable OpenXR (do this with the headset plugged in)
#   ./vr_mode.sh off   disable OpenXR (instant startup, keyboard/gamepad)
#
# The macOS/Linux counterpart of vr_mode.bat. Both do the same thing: rewrite
# project.godot with OpenXR on or off.
#
# Leave it off unless a headset is actually connected. Godot asks the OpenXR
# loader for a runtime during engine start-up, and on a machine with no runtime
# installed that call blocks for well over a minute before giving up.
set -euo pipefail
cd "$(dirname "$0")"

PY=$(command -v python3 || command -v python || true)
if [ -z "$PY" ]; then
	echo "error: python is required to regenerate project.godot" >&2
	exit 1
fi

case "${1:-}" in
	on)
		"$PY" tools/gen_project_godot.py --vr
		echo "VR ENABLED  - connect your headset before launching"
		;;
	off)
		"$PY" tools/gen_project_godot.py
		echo "VR DISABLED - flat keyboard/gamepad build"
		;;
	*)
		echo "Usage: ./vr_mode.sh on | ./vr_mode.sh off" >&2
		exit 1
		;;
esac
