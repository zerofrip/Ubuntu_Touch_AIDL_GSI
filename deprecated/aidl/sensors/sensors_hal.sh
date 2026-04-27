#!/bin/bash
# =============================================================================
# aidl/sensors/sensors_hal.sh — Sensors AIDL HAL Wrapper
# =============================================================================
# Bridges iio-sensor-proxy to Android vendor sensor HAL via
# AIDL binder interface android.hardware.sensors.ISensors.
#
# Detection flow:
#   1. Enumerate /sys/bus/iio/devices for IIO sensors
#   2. Classify light (in_illuminance), proximity (in_proximity), accel, gyro
#   3. Set permissions on IIO device nodes
#   4. Start iio-sensor-proxy for D-Bus sensor access
#   5. Enable auto-brightness / proximity-wakelock hints for Lomiri
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "sensors" "android.hardware.sensors.ISensors" "optional"

# ---------------------------------------------------------------------------
# IIO device discovery and classification
# ---------------------------------------------------------------------------
detect_iio_sensors() {
    IIO_COUNT=0
    HAS_LIGHT=0
    HAS_PROXIMITY=0
    HAS_ACCEL=0
    HAS_GYRO=0
    HAS_MAGN=0
    IIO_SENSOR_LIST=""

    for dev in /sys/bus/iio/devices/iio:device*; do
        [ -d "$dev" ] || continue

        IIO_COUNT=$((IIO_COUNT + 1))
        local name
        name=$(cat "$dev/name" 2>/dev/null || echo "unknown")
        IIO_SENSOR_LIST="${IIO_SENSOR_LIST} ${name}"

        # Classify by available channels
        if [ -e "$dev/in_illuminance_raw" ] || [ -e "$dev/in_illuminance_input" ]; then
            HAS_LIGHT=1
            hal_info "  Light sensor: $name ($dev)"
        fi
        if [ -e "$dev/in_proximity_raw" ] || [ -e "$dev/in_proximity_input" ]; then
            HAS_PROXIMITY=1
            hal_info "  Proximity sensor: $name ($dev)"
        fi
        if [ -e "$dev/in_accel_x_raw" ]; then
            HAS_ACCEL=1
            hal_info "  Accelerometer: $name ($dev)"
        fi
        if [ -e "$dev/in_anglvel_x_raw" ]; then
            HAS_GYRO=1
            hal_info "  Gyroscope: $name ($dev)"
        fi
        if [ -e "$dev/in_magn_x_raw" ] || [ -e "$dev/in_magn_x_input" ]; then
            HAS_MAGN=1
            hal_info "  Magnetometer: $name ($dev)"
        fi
    done

    hal_info "Detected $IIO_COUNT IIO devices:$IIO_SENSOR_LIST"
    hal_set_state "iio_devices" "$IIO_COUNT"
    hal_set_state "has_light" "$HAS_LIGHT"
    hal_set_state "has_proximity" "$HAS_PROXIMITY"
    hal_set_state "has_accel" "$HAS_ACCEL"
    hal_set_state "has_gyro" "$HAS_GYRO"
    hal_set_state "has_magn" "$HAS_MAGN"
}

# ---------------------------------------------------------------------------
# Set permissions on IIO device nodes
# ---------------------------------------------------------------------------
prepare_iio_permissions() {
    # sysfs IIO attribute files
    for dev in /sys/bus/iio/devices/iio:device*; do
        [ -d "$dev" ] || continue
        chmod -R a+r "$dev" 2>/dev/null || true
    done

    # Character devices for buffered/trigger access
    for iio_cdev in /dev/iio:device*; do
        [ -c "$iio_cdev" ] || continue
        chmod 0666 "$iio_cdev" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Start iio-sensor-proxy (provides D-Bus API for sensors)
# ---------------------------------------------------------------------------
start_sensor_proxy() {
    if [ -x /usr/libexec/iio-sensor-proxy ]; then
        /usr/libexec/iio-sensor-proxy &
        hal_info "iio-sensor-proxy started (PID $!)"
        return 0
    fi

    # Fallback: check alternative path
    if [ -x /usr/lib/iio-sensor-proxy/iio-sensor-proxy ]; then
        /usr/lib/iio-sensor-proxy/iio-sensor-proxy &
        hal_info "iio-sensor-proxy started from alt path (PID $!)"
        return 0
    fi

    hal_warn "iio-sensor-proxy binary not found"
    return 1
}

# ---------------------------------------------------------------------------
# Native handler — vendor sensor HAL available
# ---------------------------------------------------------------------------
sensors_native() {
    hal_info "Sensor HAL available — initializing sensor subsystem"

    # Step 1: Permissions
    prepare_iio_permissions

    # Step 2: Detect and classify sensors
    detect_iio_sensors

    if [ "$IIO_COUNT" -eq 0 ]; then
        hal_warn "No IIO sensors found — checking vendor sysfs"
        # Some Android vendors expose sensors via /sys/class/sensors
        if [ -d /sys/class/sensors ]; then
            local vendor_count=0
            for s in /sys/class/sensors/*; do
                [ -d "$s" ] || continue
                vendor_count=$((vendor_count + 1))
                local sname
                sname=$(basename "$s")
                hal_info "  Vendor sensor: $sname"
            done
            hal_set_state "vendor_sensors" "$vendor_count"
        fi
    fi

    # Step 3: Start iio-sensor-proxy for D-Bus integration
    start_sensor_proxy

    # Step 4: Enable iio-sensor-proxy systemd service if available
    if systemctl list-unit-files iio-sensor-proxy.service >/dev/null 2>&1; then
        systemctl enable --now iio-sensor-proxy.service 2>/dev/null || true
        hal_info "iio-sensor-proxy.service enabled"
    fi

    hal_set_state "status" "active"

    # Keep alive
    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor sensor HAL
# ---------------------------------------------------------------------------
sensors_mock() {
    hal_info "Sensor HAL mock: checking for standalone IIO sensors"

    prepare_iio_permissions
    detect_iio_sensors

    if [ "$IIO_COUNT" -gt 0 ]; then
        hal_info "IIO sensors found without vendor HAL — using iio-sensor-proxy"
        start_sensor_proxy
        hal_set_state "status" "iio_only"
    else
        hal_info "No sensors available"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run sensors_native sensors_mock
