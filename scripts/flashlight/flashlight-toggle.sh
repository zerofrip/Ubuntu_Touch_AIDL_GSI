#!/bin/bash
# =============================================================================
# scripts/flashlight/flashlight-toggle.sh — Camera Flashlight/Torch Toggle
# =============================================================================
# Toggles the camera flash LED as a flashlight/torch.
# Detection priority:
#   1. /sys/class/leds/flashlight/brightness
#   2. /sys/class/leds/torch-light*/brightness
#   3. /sys/class/leds/led:flash_*/brightness
#   4. /sys/class/leds/white:flash/brightness
#   5. V4L2 flash control via v4l2-ctl
# =============================================================================

STATE_FILE="/run/ubuntu-gsi/flashlight_state"
mkdir -p /run/ubuntu-gsi

find_flash_led() {
    for pattern in \
        /sys/class/leds/flashlight \
        /sys/class/leds/torch-light* \
        /sys/class/leds/led:flash_* \
        /sys/class/leds/led:torch_* \
        /sys/class/leds/white:flash \
        /sys/class/leds/white:torch; do
        for led in $pattern; do
            if [ -d "$led" ] && [ -e "$led/brightness" ]; then
                echo "$led"
                return 0
            fi
        done
    done
    return 1
}

get_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "off"
}

flash_on() {
    local led_path
    led_path=$(find_flash_led)
    if [ -n "$led_path" ]; then
        local max_brightness
        max_brightness=$(cat "$led_path/max_brightness" 2>/dev/null || echo "255")
        echo "$max_brightness" > "$led_path/brightness" 2>/dev/null
        echo "on" > "$STATE_FILE"
        echo "Flashlight ON ($led_path)"
        return 0
    fi

    # V4L2 fallback
    if command -v v4l2-ctl >/dev/null 2>&1; then
        for vdev in /dev/video*; do
            [ -c "$vdev" ] || continue
            if v4l2-ctl -d "$vdev" --list-ctrls 2>/dev/null | grep -q "flash_led_mode"; then
                v4l2-ctl -d "$vdev" --set-ctrl flash_led_mode=2 2>/dev/null
                echo "on" > "$STATE_FILE"
                echo "Flashlight ON (V4L2: $vdev)"
                return 0
            fi
        done
    fi

    echo "No flash LED found"
    return 1
}

flash_off() {
    local led_path
    led_path=$(find_flash_led)
    if [ -n "$led_path" ]; then
        echo 0 > "$led_path/brightness" 2>/dev/null
    fi

    # Also turn off V4L2 flash
    if command -v v4l2-ctl >/dev/null 2>&1; then
        for vdev in /dev/video*; do
            [ -c "$vdev" ] || continue
            v4l2-ctl -d "$vdev" --set-ctrl flash_led_mode=0 2>/dev/null || true
        done
    fi

    echo "off" > "$STATE_FILE"
    echo "Flashlight OFF"
}

case "${1:-toggle}" in
    on)    flash_on ;;
    off)   flash_off ;;
    toggle)
        if [ "$(get_state)" = "on" ]; then
            flash_off
        else
            flash_on
        fi
        ;;
    status)
        get_state
        ;;
    *)
        echo "Usage: $0 {on|off|toggle|status}"
        exit 1
        ;;
esac
