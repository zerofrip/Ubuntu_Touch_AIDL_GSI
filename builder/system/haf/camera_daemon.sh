#!/bin/bash
# =============================================================================
# camera_daemon.sh (HAF Camera Daemon)
# =============================================================================
# Manages camera device discovery and provides a named-pipe interface
# for camera enumeration queries. Falls back to mock if no V4L2 devices
# or vendor camera HAL is available.
# =============================================================================

SERVICE="camera"
PIPE="/dev/uhl/$SERVICE"
HAL="android.hardware.camera.provider"

# Import Library Bounds
source /system/haf/common_hal.sh

log_daemon "$SERVICE" "Initializing camera daemon..."

# Evaluate dependencies — falls back to mock if HAL missing
evaluate_hal_provider "$SERVICE" "$HAL" "$PIPE" "ENUMERATE" "DEVICES=0"

# ---------------------------------------------------------------------------
# Enumerate V4L2 capture devices
# ---------------------------------------------------------------------------
cam_count=0
cam_list=""

for dev in /dev/video*; do
    [ -c "$dev" ] || continue
    # Only count actual capture devices
    if command -v v4l2-ctl >/dev/null 2>&1; then
        caps=$(v4l2-ctl --device="$dev" --all 2>/dev/null | grep -i "video capture" || true)
        [ -z "$caps" ] && continue
    fi
    cam_count=$((cam_count + 1))
    cam_list="${cam_list} ${dev}"
done

log_daemon "$SERVICE" "Found $cam_count V4L2 capture devices:$cam_list"

# ---------------------------------------------------------------------------
# Configure libcamera environment
# ---------------------------------------------------------------------------
export LIBCAMERA_LOG_LEVELS="*:WARN"

# Test if libcamera can start (non-blocking check)
if command -v cam >/dev/null 2>&1; then
    cam_output=$(timeout 5 cam --list 2>&1 || true)
    log_daemon "$SERVICE" "libcamera probe: $cam_output"
fi

# ---------------------------------------------------------------------------
# Named pipe request handler
# ---------------------------------------------------------------------------
log_daemon "$SERVICE" "Listening on $PIPE for camera queries..."

tail -f "$PIPE" 2>/dev/null | while read -r line; do
    case "$line" in
        ENUMERATE)
            echo "DEVICES=$cam_count" > "${PIPE}_out" 2>/dev/null || true
            log_daemon "$SERVICE" "ENUMERATE → DEVICES=$cam_count"
            ;;
        LIST)
            echo "CAMERAS=$cam_list" > "${PIPE}_out" 2>/dev/null || true
            log_daemon "$SERVICE" "LIST → CAMERAS=$cam_list"
            ;;
        *)
            log_daemon "$SERVICE" "Unknown request: $line"
            ;;
    esac
done &
