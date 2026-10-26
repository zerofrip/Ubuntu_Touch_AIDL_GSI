#!/bin/bash
# Sample Lomiri wake/display state (stdout summary).
# Usage: bash scripts/diag_lomiri_wake.sh [label]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="${1:-sample}"

lomiri_pid=$(adb shell su 0 pidof lomiri 2>/dev/null | tr -d '\r' || true)
bl=$(adb shell su 0 cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null | tr -d '\r' || echo na)
blmax=$(adb shell su 0 cat /sys/class/leds/lcd-backlight/max_brightness 2>/dev/null | tr -d '\r' || echo na)
fb=$(adb shell su 0 "grep -A3 'plane\\[39\\]:' /sys/kernel/debug/dri/0/state | grep 'fb=' | head -1" 2>/dev/null | tr -d '\r' || true)
crtc=$(adb shell su 0 "grep -A3 'plane\\[39\\]:' /sys/kernel/debug/dri/0/state | grep 'crtc=' | head -1" 2>/dev/null | tr -d '\r' || true)
present_n=$(adb shell su 0 "logcat -d 2>/dev/null | grep -c 'presentDisplay raw=0' || true" | tr -d '\r')
egl_line=$(rg -n 'matching egl|Selected Mir display format' "$REPO/builder/out/start-lomiri.host.log" 2>/dev/null | tail -5 || true)

echo "label=$LABEL lomiri=$lomiri_pid brightness=$bl/$blmax presents=$present_n"
echo "fb=$fb"
echo "crtc=$crtc"
echo "egl:"
echo "$egl_line"
