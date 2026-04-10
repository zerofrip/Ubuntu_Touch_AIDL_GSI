#!/bin/bash
# =============================================================================
# input_daemon.sh — Input/Touchscreen HAF Daemon
# =============================================================================
# Manages touchscreen device detection, permission setup, and libinput
# configuration within the HAF (Hardware Abstraction Framework).
# =============================================================================

SERVICE="input"
PIPE="/dev/uhl/$SERVICE"
HAL="android.hardware.input"

source /system/haf/common_hal.sh
log_daemon "$SERVICE" "Initializing input/touchscreen subsystem..."

evaluate_hal_provider "$SERVICE" "$HAL" "$PIPE" "SCAN" "STATUS=NO_INPUT"

# ---------------------------------------------------------------------------
# Set permissions on /dev/input devices
# ---------------------------------------------------------------------------
for event_dev in /dev/input/event*; do
    [ -c "$event_dev" ] || continue
    chmod 0660 "$event_dev" 2>/dev/null || true
    chgrp input "$event_dev" 2>/dev/null || true
done
log_daemon "$SERVICE" "Input device permissions set"

# ---------------------------------------------------------------------------
# Trigger udev to apply our rules
# ---------------------------------------------------------------------------
if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    log_daemon "$SERVICE" "udev input rules triggered"
fi

# ---------------------------------------------------------------------------
# Detect touchscreen devices
# ---------------------------------------------------------------------------
TS_COUNT=0
for event_dev in /dev/input/event*; do
    [ -c "$event_dev" ] || continue
    dev_name=""
    sysfs="/sys/class/input/$(basename "$event_dev")/device/name"
    [ -f "$sysfs" ] && dev_name=$(cat "$sysfs" 2>/dev/null)

    abs_path="/sys/class/input/$(basename "$event_dev")/device/capabilities/abs"
    if [ -f "$abs_path" ]; then
        abs_caps=$(cat "$abs_path" 2>/dev/null)
        if [ -n "$abs_caps" ] && [ "$abs_caps" != "0" ]; then
            log_daemon "$SERVICE" "Touchscreen candidate: $event_dev ($dev_name)"
            TS_COUNT=$((TS_COUNT + 1))
        fi
    fi
done

if [ "$TS_COUNT" -gt 0 ]; then
    log_daemon "$SERVICE" "Touchscreen(s) detected: $TS_COUNT"
else
    log_daemon "$SERVICE" "No touchscreen detected — input devices may still work via evdev"
fi

# ---------------------------------------------------------------------------
# Monitor pipe for requests
# ---------------------------------------------------------------------------
tail -f "$PIPE" 2>/dev/null | while read -r line; do
    log_daemon "$SERVICE" "Input request -> $line"
done &
