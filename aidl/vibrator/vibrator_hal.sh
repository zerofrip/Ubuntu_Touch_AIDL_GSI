#!/bin/bash
# =============================================================================
# aidl/vibrator/vibrator_hal.sh — Vibrator AIDL HAL Wrapper
# =============================================================================
# Bridges Linux Force Feedback / Android sysfs vibrator to
# AIDL binder interface android.hardware.vibrator.IVibrator.
#
# Detection flow:
#   1. Check Android sysfs: /sys/class/timed_output/vibrator/enable
#   2. Check LED-class vibrator: /sys/class/leds/vibrator/
#   3. Check Linux input FF: /dev/input/event* with EV_FF + FF_RUMBLE
#   4. Provide trigger interface via named state file
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "vibrator" "android.hardware.vibrator.IVibrator" "optional"

VIBRATOR_PATH=""
VIBRATOR_TYPE=""

# ---------------------------------------------------------------------------
# Detect vibrator device
# ---------------------------------------------------------------------------
detect_vibrator() {
    # Path 1: Android timed_output vibrator
    if [ -e /sys/class/timed_output/vibrator/enable ]; then
        VIBRATOR_PATH="/sys/class/timed_output/vibrator/enable"
        VIBRATOR_TYPE="timed_output"
        hal_info "Vibrator: timed_output at $VIBRATOR_PATH"
        return 0
    fi

    # Path 2: LED-class vibrator (newer Android kernels)
    for led in /sys/class/leds/vibrator /sys/class/leds/vibrator_0; do
        if [ -d "$led" ]; then
            if [ -e "$led/activate" ]; then
                VIBRATOR_PATH="$led"
                VIBRATOR_TYPE="led"
                hal_info "Vibrator: LED-class at $VIBRATOR_PATH"
                return 0
            elif [ -e "$led/brightness" ]; then
                VIBRATOR_PATH="$led"
                VIBRATOR_TYPE="led_brightness"
                hal_info "Vibrator: LED brightness at $VIBRATOR_PATH"
                return 0
            fi
        fi
    done

    # Path 3: Linux input Force Feedback
    for evdev in /dev/input/event*; do
        [ -c "$evdev" ] || continue
        # Check if device supports FF_RUMBLE via evtest
        if command -v evtest >/dev/null 2>&1; then
            if evtest --query "$evdev" EV_FF FF_RUMBLE 2>/dev/null; then
                VIBRATOR_PATH="$evdev"
                VIBRATOR_TYPE="ff_rumble"
                hal_info "Vibrator: FF_RUMBLE at $VIBRATOR_PATH"
                return 0
            fi
        fi
    done

    hal_warn "No vibrator device found"
    return 1
}

# ---------------------------------------------------------------------------
# Trigger vibration (duration in ms)
# ---------------------------------------------------------------------------
vibrate_ms() {
    local duration_ms=$1

    case "$VIBRATOR_TYPE" in
        timed_output)
            echo "$duration_ms" > "$VIBRATOR_PATH" 2>/dev/null || true
            ;;
        led)
            # Set duration then activate
            echo "$duration_ms" > "$VIBRATOR_PATH/duration" 2>/dev/null || true
            echo 1 > "$VIBRATOR_PATH/activate" 2>/dev/null || true
            ;;
        led_brightness)
            echo 1 > "$VIBRATOR_PATH/brightness" 2>/dev/null || true
            sleep "$(echo "scale=3; $duration_ms/1000" | bc 2>/dev/null || echo "0.1")"
            echo 0 > "$VIBRATOR_PATH/brightness" 2>/dev/null || true
            ;;
        ff_rumble)
            if command -v fftest >/dev/null 2>&1; then
                timeout "$((duration_ms / 1000 + 1))" fftest "$VIBRATOR_PATH" 2>/dev/null || true
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Set permissions on vibrator device nodes
# ---------------------------------------------------------------------------
prepare_vibrator_permissions() {
    case "$VIBRATOR_TYPE" in
        timed_output)
            chmod 0666 "$VIBRATOR_PATH" 2>/dev/null || true
            ;;
        led|led_brightness)
            chmod 0666 "$VIBRATOR_PATH/brightness" 2>/dev/null || true
            chmod 0666 "$VIBRATOR_PATH/activate" 2>/dev/null || true
            chmod 0666 "$VIBRATOR_PATH/duration" 2>/dev/null || true
            ;;
        ff_rumble)
            chmod 0666 "$VIBRATOR_PATH" 2>/dev/null || true
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Native handler — vendor vibrator HAL available
# ---------------------------------------------------------------------------
vibrator_native() {
    hal_info "Vibrator HAL available — detecting vibrator device"

    if detect_vibrator; then
        prepare_vibrator_permissions
        hal_set_state "vibrator_type" "$VIBRATOR_TYPE"
        hal_set_state "vibrator_path" "$VIBRATOR_PATH"
        hal_set_state "status" "active"

        # Test vibration (short buzz on boot)
        vibrate_ms 100
        hal_info "Vibrator test: 100ms buzz"
    else
        hal_set_state "vibrator_type" "none"
        hal_set_state "status" "no_device"
    fi

    # Keep alive
    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor vibrator HAL
# ---------------------------------------------------------------------------
vibrator_mock() {
    hal_info "Vibrator HAL mock: checking for standalone vibrator"

    if detect_vibrator; then
        prepare_vibrator_permissions
        hal_set_state "vibrator_type" "$VIBRATOR_TYPE"
        hal_set_state "status" "standalone"
    else
        hal_set_state "vibrator_type" "none"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run vibrator_native vibrator_mock
