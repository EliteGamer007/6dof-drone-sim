@echo off
REM Switch the project between the flat testing build and the VR demo build.
REM   vr_mode on    - enable OpenXR (do this with the headset plugged in)
REM   vr_mode off   - disable OpenXR (instant startup, keyboard/gamepad)
setlocal
if /I "%~1"=="on"  ( python tools\gen_project_godot.py --vr & echo VR ENABLED  - connect your headset before launching & goto :eof )
if /I "%~1"=="off" ( python tools\gen_project_godot.py       & echo VR DISABLED - flat keyboard/gamepad build & goto :eof )
echo Usage: vr_mode on ^| vr_mode off
