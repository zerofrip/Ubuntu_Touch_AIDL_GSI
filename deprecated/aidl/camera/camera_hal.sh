#!/bin/bash
# =============================================================================
# aidl/camera/camera_hal.sh — Camera AIDL HAL Wrapper
# =============================================================================
# Bridges libcamera / V4L2 to Android vendor camera HAL via
# AIDL binder interface android.hardware.camera.provider.ICameraProvider.
#
# Detection flow:
#   1. Enumerate /dev/video* (V4L2 capture devices)
#   2. Classify front/rear via v4l2-ctl or sysfs hints
#   3. Configure libcamera pipeline (vendor HAL → V4L2 → libcamera)
#   4. Set permissions on camera device nodes
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "camera" "android.hardware.camera.provider.ICameraProvider" "optional"

# ---------------------------------------------------------------------------
# Camera device discovery
# ---------------------------------------------------------------------------
detect_camera_devices() {
    CAM_CAPTURE_COUNT=0
    CAM_DEVICES=""

    for dev in /dev/video*; do
        [ -c "$dev" ] || continue

        # Check if it's a video capture device (not output/overlay/m2m)
        if command -v v4l2-ctl >/dev/null 2>&1; then
            caps=$(v4l2-ctl --device="$dev" --all 2>/dev/null | grep -i "video capture" || true)
            if [ -z "$caps" ]; then
                continue
            fi
        fi

        CAM_CAPTURE_COUNT=$((CAM_CAPTURE_COUNT + 1))
        CAM_DEVICES="${CAM_DEVICES} ${dev}"
    done

    hal_info "Detected $CAM_CAPTURE_COUNT V4L2 capture devices:$CAM_DEVICES"
    hal_set_state "camera_count" "$CAM_CAPTURE_COUNT"
}

# ---------------------------------------------------------------------------
# Classify cameras as front/rear by checking V4L2 or sysfs info
# ---------------------------------------------------------------------------
classify_cameras() {
    local front_count=0
    local rear_count=0

    for dev in $CAM_DEVICES; do
        local facing="unknown"

        # Try v4l2-ctl card name for hints
        if command -v v4l2-ctl >/dev/null 2>&1; then
            local card_name
            card_name=$(v4l2-ctl --device="$dev" --info 2>/dev/null | grep "Card type" | sed 's/.*: *//' || true)

            case "$card_name" in
                *front*|*Front*|*FRONT*|*selfie*|*Selfie*)
                    facing="front"
                    front_count=$((front_count + 1))
                    ;;
                *rear*|*Rear*|*REAR*|*back*|*Back*|*main*|*Main*)
                    facing="rear"
                    rear_count=$((rear_count + 1))
                    ;;
            esac
        fi

        # Fallback: check sysfs sensor position
        if [ "$facing" = "unknown" ]; then
            local dev_num
            dev_num=$(basename "$dev" | sed 's/video//')
            local sysfs_facing="/sys/class/video4linux/video${dev_num}/device/facing"
            if [ -r "$sysfs_facing" ]; then
                local pos
                pos=$(cat "$sysfs_facing" 2>/dev/null || true)
                case "$pos" in
                    0|front) facing="front"; front_count=$((front_count + 1)) ;;
                    1|back)  facing="rear";  rear_count=$((rear_count + 1)) ;;
                esac
            fi
        fi

        hal_info "  $dev → $facing"
    done

    hal_set_state "camera_front" "$front_count"
    hal_set_state "camera_rear" "$rear_count"
}

# ---------------------------------------------------------------------------
# Set permissions on camera device nodes
# ---------------------------------------------------------------------------
prepare_camera_permissions() {
    for dev in /dev/video* /dev/media*; do
        [ -e "$dev" ] || continue
        chmod 0666 "$dev" 2>/dev/null || true
    done

    # Ensure vendor camera firmware/config is accessible
    for cfg_dir in /vendor/etc/camera /vendor/lib64/camera /odm/etc/camera; do
        if [ -d "$cfg_dir" ]; then
            hal_info "Vendor camera config found: $cfg_dir"
        fi
    done
}

# ---------------------------------------------------------------------------
# Configure libcamera environment
# ---------------------------------------------------------------------------
setup_libcamera_env() {
    export LIBCAMERA_LOG_LEVELS="*:WARN"

    # If vendor provides a camera HAL, try the Android pipeline handler
    if [ -d /vendor/lib64/camera ] || [ -d /vendor/lib64/hw ]; then
        hal_info "Vendor camera libraries detected — using vendor pipeline"
    fi

    # Tell GStreamer to prefer libcamera source
    export GST_PLUGIN_FEATURE_RANK="libcamerasrc:512,v4l2src:256"
}

# ---------------------------------------------------------------------------
# Native handler — vendor camera HAL available
# ---------------------------------------------------------------------------
camera_native() {
    hal_info "Camera provider available — initializing camera subsystem"

    # Step 1: Permissions
    prepare_camera_permissions

    # Step 2: Detect cameras
    detect_camera_devices

    if [ "$CAM_CAPTURE_COUNT" -eq 0 ]; then
        hal_warn "No V4L2 capture devices found — cameras may not be exposed"
        hal_set_state "status" "no_devices"
    else
        hal_set_state "status" "active"
    fi

    # Step 3: Classify front/rear
    classify_cameras

    # Step 4: Configure libcamera
    setup_libcamera_env

    # Step 5: Verify libcamera can see cameras
    if command -v cam >/dev/null 2>&1; then
        local cam_list
        cam_list=$(cam --list 2>/dev/null || true)
        if [ -n "$cam_list" ]; then
            hal_info "libcamera cameras: $cam_list"
        else
            hal_info "libcamera found no cameras (V4L2 devices may need vendor pipeline)"
        fi
    fi

    # Keep alive for camera service consumers
    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor camera HAL
# ---------------------------------------------------------------------------
camera_mock() {
    hal_info "Camera HAL mock: checking for standalone V4L2 cameras"

    prepare_camera_permissions
    detect_camera_devices

    if [ "$CAM_CAPTURE_COUNT" -gt 0 ]; then
        hal_info "V4L2 cameras found without vendor HAL — limited functionality"
        classify_cameras
        setup_libcamera_env
        hal_set_state "status" "v4l2_only"
    else
        hal_info "No cameras available"
        hal_set_state "camera_count" "0"
        hal_set_state "camera_front" "0"
        hal_set_state "camera_rear" "0"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run camera_native camera_mock
