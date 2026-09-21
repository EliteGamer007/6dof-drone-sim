#!/usr/bin/env bash
# Screenshot harness: tools/shot.sh <name> [extra godot user args...]
GODOT="/c/Users/Sanjeev Srinivas/Downloads/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe"
PROJ="C:/Users/Sanjeev Srinivas/OneDrive/Documents/beirut-drone-sim"
NAME="$1"; shift
timeout 240 "$GODOT" --path "$PROJ" --resolution 1600x900 --position 30,30 -- \
  --no-vr --capture="$PROJ/shots/$NAME.png" --capture-after=150 "$@" \
  >"$PROJ/shots/$NAME.log" 2>&1
echo "$NAME -> $(ls -la "$PROJ/shots/$NAME.png" 2>/dev/null | awk '{print $5}') bytes"
grep -E "SCRIPT ERROR|Parse Error|Shader|shader" "$PROJ/shots/$NAME.log" | head -8
