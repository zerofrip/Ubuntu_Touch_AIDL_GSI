#!/bin/bash
# =============================================================================
# volume-key-daemon.sh — Hardware Volume Button → PulseAudio Bridge
# =============================================================================
# Monitors /dev/input/event* for volume key events and translates them
# to PulseAudio volume changes. Runs as a lightweight daemon.
#
# Requires: evtest (for device identification), pactl (pulseaudio-utils)
# =============================================================================

set -euo pipefail

LOG="/data/uhl_overlay/volume-keys.log"
VOLUME_STEP="5%"

log() { echo "[$(date -Iseconds)] [VolumeKeys] $1" >> "$LOG" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Find the input device that emits volume key events
# ---------------------------------------------------------------------------
find_volume_device() {
    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue

        local dev_name=""
        local sysfs
        sysfs="/sys/class/input/$(basename "$event_dev")/device/name"
        [ -f "$sysfs" ] && dev_name=$(cat "$sysfs" 2>/dev/null)

        # Check capabilities for KEY events (bit 1 in ev capabilities)
        local ev_path
        ev_path="/sys/class/input/$(basename "$event_dev")/device/capabilities/ev"
        [ -f "$ev_path" ] || continue
        local _ev_caps
        _ev_caps=$(cat "$ev_path" 2>/dev/null)

        # Check for KEY capability (bit 1 set → ev_caps has 0x2 or higher odd bits)
        # Also check if this device has key bits for volume keys
        local key_path
        key_path="/sys/class/input/$(basename "$event_dev")/device/capabilities/key"
        [ -f "$key_path" ] || continue
        local key_caps
        key_caps=$(cat "$key_path" 2>/dev/null)
        [ -n "$key_caps" ] && [ "$key_caps" != "0" ] || continue

        # Match known button device names
        case "$dev_name" in
            *gpio-keys*|*pmic-keys*|*mtk-kpd*|*[Vv]olume*|*[Pp]ower*|*[Kk]eypad*|*[Bb]utton*)
                echo "$event_dev"
                return 0
                ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# Read raw input events from /dev/input/event*
# Key event struct: struct input_event { time(16B), type(2B), code(2B), value(4B) }
# type=1 (EV_KEY), code=114 (KEY_VOLUMEDOWN), code=115 (KEY_VOLUMEUP)
# value=1 (press), value=0 (release)
# ---------------------------------------------------------------------------
monitor_volume_keys() {
    local device="$1"
    log "Monitoring volume keys on $device"

    # Use od to read raw binary input events (24 bytes each on 64-bit)
    # struct input_event: tv_sec(8) + tv_usec(8) + type(2) + code(2) + value(4) = 24 bytes
    od -A n -t u2 -w24 "$device" 2>/dev/null | while read -r _ _ _ _ _ _ _ _ ev_type ev_code val_lo _val_hi; do
        # ev_type=1 means EV_KEY
        [ "$ev_type" = "1" ] || continue

        # value = val_lo (only care about press events, value=1)
        [ "$val_lo" = "1" ] || continue

        case "$ev_code" in
            115)
                # KEY_VOLUMEUP
                if command -v pactl >/dev/null 2>&1; then
                    pactl set-sink-volume @DEFAULT_SINK@ +"$VOLUME_STEP" 2>/dev/null || true
                elif command -v amixer >/dev/null 2>&1; then
                    amixer -q set Master "$VOLUME_STEP"+ 2>/dev/null || true
                fi
                log "Volume UP"
                ;;
            114)
                # KEY_VOLUMEDOWN
                if command -v pactl >/dev/null 2>&1; then
                    pactl set-sink-volume @DEFAULT_SINK@ -"$VOLUME_STEP" 2>/dev/null || true
                elif command -v amixer >/dev/null 2>&1; then
                    amixer -q set Master "$VOLUME_STEP"- 2>/dev/null || true
                fi
                log "Volume DOWN"
                ;;
            113)
                # KEY_MUTE
                if command -v pactl >/dev/null 2>&1; then
                    pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null || true
                elif command -v amixer >/dev/null 2>&1; then
                    amixer -q set Master toggle 2>/dev/null || true
                fi
                log "Mute TOGGLE"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Starting volume key daemon..."

# Wait for input devices to appear (driver init may be slow)
DEVICE=""
for _attempt in $(seq 1 20); do
    DEVICE=$(find_volume_device) && break
    sleep 1
done

if [ -z "$DEVICE" ]; then
    log "No volume key device found — daemon idle"
    # Stay alive in case device appears later via hotplug
    while true; do
        DEVICE=$(find_volume_device 2>/dev/null) || true
        if [ -n "$DEVICE" ]; then
            log "Late-detected volume key device: $DEVICE"
            break
        fi
        sleep 10
    done
fi

log "Using input device: $DEVICE"

# Restart monitoring if it exits (device removed/re-added)
while true; do
    monitor_volume_keys "$DEVICE"
    log "Monitor exited — restarting in 2s..."
    sleep 2
    # Re-detect in case device node changed
    DEVICE=$(find_volume_device 2>/dev/null) || true
    [ -n "$DEVICE" ] || break
done

log "Volume key daemon stopped"
