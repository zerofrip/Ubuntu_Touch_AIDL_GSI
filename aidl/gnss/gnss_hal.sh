#!/bin/bash
# =============================================================================
# aidl/gnss/gnss_hal.sh — GNSS/GPS AIDL HAL Wrapper
# =============================================================================
# Bridges gpsd to Android vendor GNSS HAL via
# AIDL binder interface android.hardware.gnss.IGnss.
#
# Detection flow:
#   1. Scan for GNSS serial ports (/dev/ttyHS*, /dev/gnss*, /dev/ttyUSB*)
#   2. Configure gpsd with detected devices
#   3. Start gpsd for NMEA processing
#   4. Start geoclue for D-Bus location API
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "gnss" "android.hardware.gnss.IGnss" "optional"

# ---------------------------------------------------------------------------
# GNSS device discovery
# ---------------------------------------------------------------------------
detect_gnss_devices() {
    GNSS_DEVICES=""
    GNSS_COUNT=0

    # Android GNSS serial ports
    for pattern in /dev/ttyHS* /dev/ttyMSM* /dev/gnss* /dev/ttyUSB*; do
        for dev in $pattern; do
            [ -c "$dev" ] || continue
            GNSS_DEVICES="${GNSS_DEVICES} ${dev}"
            GNSS_COUNT=$((GNSS_COUNT + 1))
            hal_info "GNSS device candidate: $dev"
        done
    done

    # Check for GNSS via USB (some devices use /dev/ttyACM*)
    for dev in /dev/ttyACM*; do
        [ -c "$dev" ] || continue
        # Check if it's a GNSS device by vendor sysfs
        local sysdev
        sysdev=$(readlink -f "/sys/class/tty/$(basename "$dev")/device" 2>/dev/null || true)
        if [ -n "$sysdev" ] && grep -qi "gnss\|gps\|u-blox\|sirf\|broadcom" "$sysdev/uevent" 2>/dev/null; then
            GNSS_DEVICES="${GNSS_DEVICES} ${dev}"
            GNSS_COUNT=$((GNSS_COUNT + 1))
            hal_info "GNSS USB device: $dev"
        fi
    done

    hal_set_state "gnss_count" "$GNSS_COUNT"
    hal_info "Detected $GNSS_COUNT GNSS device(s):$GNSS_DEVICES"
}

# ---------------------------------------------------------------------------
# Set permissions on GNSS device nodes
# ---------------------------------------------------------------------------
prepare_gnss_permissions() {
    for dev in $GNSS_DEVICES; do
        chmod 0666 "$dev" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Configure and start gpsd
# ---------------------------------------------------------------------------
start_gpsd() {
    if ! command -v gpsd >/dev/null 2>&1; then
        hal_warn "gpsd not installed"
        return 1
    fi

    if [ "$GNSS_COUNT" -eq 0 ]; then
        hal_warn "No GNSS devices found — starting gpsd in auto-detect mode"
        gpsd -n -G /var/run/gpsd.sock 2>/dev/null &
    else
        # shellcheck disable=SC2086
        gpsd -n -G $GNSS_DEVICES 2>/dev/null &
    fi
    hal_info "gpsd started (PID $!)"
    return 0
}

# ---------------------------------------------------------------------------
# Start geoclue for D-Bus location API
# ---------------------------------------------------------------------------
start_geoclue() {
    if [ -x /usr/libexec/geoclue ]; then
        hal_info "geoclue available for D-Bus location API"
    fi
    # geoclue is D-Bus activated — no manual start needed
    # Just ensure the service is enabled
    if systemctl list-unit-files geoclue.service >/dev/null 2>&1; then
        systemctl enable geoclue.service 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Native handler — vendor GNSS HAL available
# ---------------------------------------------------------------------------
gnss_native() {
    hal_info "GNSS provider available — initializing GPS subsystem"

    detect_gnss_devices
    prepare_gnss_permissions

    if start_gpsd; then
        hal_set_state "status" "active"
    else
        hal_set_state "status" "no_gpsd"
    fi

    start_geoclue

    # Keep alive
    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor GNSS HAL
# ---------------------------------------------------------------------------
gnss_mock() {
    hal_info "GNSS HAL mock: checking for standalone GNSS devices"

    detect_gnss_devices

    if [ "$GNSS_COUNT" -gt 0 ]; then
        prepare_gnss_permissions
        start_gpsd
        start_geoclue
        hal_set_state "status" "standalone"
    else
        hal_info "No GNSS devices available"
        hal_set_state "gnss_count" "0"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run gnss_native gnss_mock
