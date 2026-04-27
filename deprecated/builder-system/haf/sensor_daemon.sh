#!/bin/bash
# =============================================================================
# sensor_daemon.sh (HAF Sensor Daemon)
# =============================================================================
# Manages IIO sensor discovery and provides a named-pipe interface for
# sensor enumeration. Falls back to mock if no IIO devices found.
# =============================================================================

SERVICE="sensor"
PIPE="/dev/uhl/$SERVICE"
HAL="android.hardware.sensors"

# Import Library Bounds
source /system/haf/common_hal.sh

log_daemon "$SERVICE" "Initializing sensor daemon..."

# Evaluate dependencies — falls back to mock if HAL missing
evaluate_hal_provider "$SERVICE" "$HAL" "$PIPE" "" "STATUS=MOCK"

# ---------------------------------------------------------------------------
# Enumerate IIO sensors
# ---------------------------------------------------------------------------
iio_count=0
light_found=0
prox_found=0
accel_found=0
gyro_found=0
magn_found=0
sensor_list=""

for dev in /sys/bus/iio/devices/iio:device*; do
    [ -d "$dev" ] || continue
    name=$(cat "$dev/name" 2>/dev/null || echo "unknown")
    iio_count=$((iio_count + 1))
    sensor_list="${sensor_list} ${name}"

    if [ -e "$dev/in_illuminance_raw" ] || [ -e "$dev/in_illuminance_input" ]; then
        light_found=1
        log_daemon "$SERVICE" "Light sensor: $name"
    fi
    if [ -e "$dev/in_proximity_raw" ] || [ -e "$dev/in_proximity_input" ]; then
        prox_found=1
        log_daemon "$SERVICE" "Proximity sensor: $name"
    fi
    if [ -e "$dev/in_accel_x_raw" ]; then
        accel_found=1
        log_daemon "$SERVICE" "Accelerometer: $name"
    fi
    if [ -e "$dev/in_anglvel_x_raw" ]; then
        gyro_found=1
        log_daemon "$SERVICE" "Gyroscope: $name"
    fi
    if [ -e "$dev/in_magn_x_raw" ] || [ -e "$dev/in_magn_x_input" ]; then
        magn_found=1
        log_daemon "$SERVICE" "Magnetometer: $name"
    fi
done

log_daemon "$SERVICE" "Found $iio_count IIO sensors:$sensor_list (light=$light_found prox=$prox_found accel=$accel_found gyro=$gyro_found magn=$magn_found)"

# ---------------------------------------------------------------------------
# Start iio-sensor-proxy if available
# ---------------------------------------------------------------------------
if [ -x /usr/libexec/iio-sensor-proxy ]; then
    /usr/libexec/iio-sensor-proxy > /dev/null 2>&1 &
    log_daemon "$SERVICE" "iio-sensor-proxy started (PID $!)"
elif [ -x /usr/lib/iio-sensor-proxy/iio-sensor-proxy ]; then
    /usr/lib/iio-sensor-proxy/iio-sensor-proxy > /dev/null 2>&1 &
    log_daemon "$SERVICE" "iio-sensor-proxy started from alt path (PID $!)"
else
    log_daemon "$SERVICE" "iio-sensor-proxy not found — sensor D-Bus API unavailable"
fi

# ---------------------------------------------------------------------------
# Named pipe request handler
# ---------------------------------------------------------------------------
log_daemon "$SERVICE" "Listening on $PIPE for sensor queries..."

tail -f "$PIPE" 2>/dev/null | while read -r line; do
    case "$line" in
        STATUS)
            echo "IIO=$iio_count LIGHT=$light_found PROXIMITY=$prox_found ACCEL=$accel_found GYRO=$gyro_found MAGN=$magn_found" > "${PIPE}_out" 2>/dev/null || true
            log_daemon "$SERVICE" "STATUS → IIO=$iio_count LIGHT=$light_found PROX=$prox_found ACCEL=$accel_found GYRO=$gyro_found MAGN=$magn_found"
            ;;
        LIST)
            echo "SENSORS=$sensor_list" > "${PIPE}_out" 2>/dev/null || true
            log_daemon "$SERVICE" "LIST → SENSORS=$sensor_list"
            ;;
        *)
            log_daemon "$SERVICE" "Unknown request: $line"
            ;;
    esac
done &
