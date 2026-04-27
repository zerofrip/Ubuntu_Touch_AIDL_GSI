#!/bin/bash
# =============================================================================
# aidl/power/power_hal.sh — Power AIDL HAL Wrapper
# =============================================================================
# Bridges Ubuntu power management (upower) to Android vendor power HAL
# via AIDL binder interface android.hardware.power.IPower.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "power" "android.hardware.power.IPower" "critical"

# ---------------------------------------------------------------------------
# Native handler — vendor power HAL available
# ---------------------------------------------------------------------------
power_native() {
    hal_info "Mapping upower → vendor power HAL via binder"

    # Start upower daemon for Linux-side power management
    if [ -x /usr/libexec/upowerd ]; then
        /usr/libexec/upowerd &
        hal_info "upowerd started (PID $!)"
    else
        hal_warn "upowerd not found — battery info unavailable"
    fi

    # Monitor vendor power state via sysfs
    while true; do
        # Read battery status from Android sysfs paths
        for bat_path in /sys/class/power_supply/battery /sys/class/power_supply/Battery; do
            if [ -d "$bat_path" ]; then
                CAPACITY=$(cat "$bat_path/capacity" 2>/dev/null || echo "?")
                STATUS=$(cat "$bat_path/status" 2>/dev/null || echo "Unknown")
                hal_info "Battery: ${CAPACITY}% ($STATUS)"
                hal_set_state "battery_capacity" "$CAPACITY"
                hal_set_state "battery_status" "$STATUS"
                break
            fi
        done
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor power HAL
# ---------------------------------------------------------------------------
power_mock() {
    hal_info "Power HAL mock: reporting AC power, no battery"
    hal_set_state "battery_capacity" "100"
    hal_set_state "battery_status" "Full"

    # Still start upower for desktop-like behavior
    if [ -x /usr/libexec/upowerd ]; then
        /usr/libexec/upowerd &
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run power_native power_mock
