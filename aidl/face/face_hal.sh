#!/bin/bash
# =============================================================================
# aidl/face/face_hal.sh — Face Authentication AIDL HAL Wrapper
# =============================================================================
# Bridges vendor face authentication HAL to Linux userspace.
# Uses vendor android.hardware.biometrics.face AIDL interface when available,
# with fallback to camera-based face detection via Howdy (if installed).
#
# Detection flow:
#   1. Check vendor VINTF for biometrics.face AIDL HAL
#   2. Detect IR/depth camera for face auth hardware
#   3. Configure face authentication service
#   4. Set up PAM integration for unlock/sudo authentication
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "face" "android.hardware.biometrics.face.IFace" "optional"

# ---------------------------------------------------------------------------
# Face authentication hardware detection
# ---------------------------------------------------------------------------
detect_face_hardware() {
    FACE_HW_FOUND=0
    FACE_HW_TYPE=""
    IR_CAMERA=""

    # Method 1: Check for dedicated IR/depth camera
    for cam_dev in /dev/video*; do
        [ -c "$cam_dev" ] || continue
        local cam_info
        cam_info=$(v4l2-ctl --device="$cam_dev" --all 2>/dev/null || true)
        if echo "$cam_info" | grep -qi "ir\|infrared\|depth\|structured.light\|face"; then
            FACE_HW_FOUND=1
            FACE_HW_TYPE="ir_camera"
            IR_CAMERA="$cam_dev"
            hal_info "IR/depth camera detected: $cam_dev"
            break
        fi
    done

    # Method 2: Check sysfs for face auth hardware
    if [ "$FACE_HW_FOUND" -eq 0 ]; then
        for sysfs_dev in /sys/devices/platform/*/face_auth \
                         /sys/devices/platform/face* \
                         /sys/devices/soc/*/face_auth; do
            if [ -d "$sysfs_dev" ]; then
                FACE_HW_FOUND=1
                FACE_HW_TYPE="sysfs_device"
                hal_info "Face auth sysfs device found: $sysfs_dev"
                break
            fi
        done
    fi

    # Method 3: Check vendor init*.rc for face service
    if [ "$FACE_HW_FOUND" -eq 0 ]; then
        for rc_file in /vendor/etc/init/*.rc /odm/etc/init/*.rc; do
            [ -f "$rc_file" ] || continue
            if grep -qi "face.*auth\|biometric.*face" "$rc_file" 2>/dev/null; then
                FACE_HW_FOUND=1
                FACE_HW_TYPE="vendor_hal"
                hal_info "Vendor face auth service found in: $rc_file"
                break
            fi
        done
    fi

    # Method 4: Check if front camera exists (for software face unlock via Howdy)
    if [ "$FACE_HW_FOUND" -eq 0 ]; then
        for cam_dev in /dev/video*; do
            [ -c "$cam_dev" ] || continue
            local cam_caps
            cam_caps=$(v4l2-ctl --device="$cam_dev" --all 2>/dev/null || true)
            # Front camera often identified by name or facing direction
            if echo "$cam_caps" | grep -qi "front\|selfie\|user.facing"; then
                FACE_HW_FOUND=1
                FACE_HW_TYPE="front_camera"
                IR_CAMERA="$cam_dev"
                hal_info "Front camera found (software face unlock possible): $cam_dev"
                break
            fi
        done
    fi

    hal_set_state "face_hw_found" "$FACE_HW_FOUND"
    hal_set_state "face_hw_type" "$FACE_HW_TYPE"

    if [ "$FACE_HW_FOUND" -eq 0 ]; then
        hal_warn "No face authentication hardware detected"
    fi
    return $((1 - FACE_HW_FOUND))
}

# ---------------------------------------------------------------------------
# Configure Howdy (Linux face recognition via IR/webcam)
# ---------------------------------------------------------------------------
configure_howdy() {
    hal_info "Configuring Howdy for face authentication"

    if ! command -v howdy >/dev/null 2>&1; then
        hal_warn "Howdy not installed — face authentication unavailable"
        hal_set_state "howdy_available" "0"
        return 1
    fi

    # Configure Howdy device path
    local howdy_config="/etc/howdy/config.ini"
    if [ -f "$howdy_config" ] && [ -n "$IR_CAMERA" ]; then
        # Set the camera device for Howdy
        local dev_path="$IR_CAMERA"
        sed -i "s|^device_path.*=.*|device_path = $dev_path|" "$howdy_config" 2>/dev/null || true
        hal_info "Howdy configured with camera: $dev_path"

        # Prefer IR camera for better recognition
        if [ "$FACE_HW_TYPE" = "ir_camera" ]; then
            sed -i 's|^dark_threshold.*=.*|dark_threshold = 50|' "$howdy_config" 2>/dev/null || true
            hal_info "Howdy dark threshold lowered for IR camera"
        fi
    fi

    hal_set_state "howdy_available" "1"
    return 0
}

# ---------------------------------------------------------------------------
# PAM integration for face unlock
# ---------------------------------------------------------------------------
configure_pam_face() {
    hal_info "Configuring PAM face authentication"

    # Check if pam_howdy module is available
    local pam_howdy=""
    for pam_path in /usr/lib/*/security/pam_howdy.so /lib/*/security/pam_howdy.so; do
        if [ -f "$pam_path" ]; then
            pam_howdy="$pam_path"
            break
        fi
    done

    if [ -z "$pam_howdy" ]; then
        hal_warn "pam_howdy.so not found — PAM face integration skipped"
        return 1
    fi

    # Add face auth to common-auth (before password, sufficient)
    local pam_common="/etc/pam.d/common-auth"
    if [ -f "$pam_common" ]; then
        if ! grep -q "pam_howdy" "$pam_common" 2>/dev/null; then
            # Insert face auth before fingerprint or password auth
            if grep -q "pam_fprintd" "$pam_common" 2>/dev/null; then
                # Place face auth before fingerprint auth
                sed -i '/pam_fprintd/i auth\tsufficient\tpam_howdy.so' \
                    "$pam_common" 2>/dev/null || true
            else
                sed -i '/^auth.*pam_unix\.so/i auth\tsufficient\tpam_howdy.so' \
                    "$pam_common" 2>/dev/null || true
            fi
            hal_info "pam_howdy added to $pam_common"
        else
            hal_info "pam_howdy already configured in $pam_common"
        fi
    fi

    hal_set_state "pam_face" "1"
    return 0
}

# ---------------------------------------------------------------------------
# Vendor HAL bridge (native mode)
# ---------------------------------------------------------------------------
handle_face_native() {
    hal_info "Starting face auth HAL in native mode (vendor HAL available)"

    detect_face_hardware
    configure_howdy
    configure_pam_face

    # Monitor vendor face service health
    while true; do
        if binder_service_registered "android.hardware.biometrics.face"; then
            hal_set_state "vendor_status" "alive"
        else
            hal_set_state "vendor_status" "unavailable"
            hal_warn "Vendor face auth binder service not responding"
        fi
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock mode (no vendor HAL)
# ---------------------------------------------------------------------------
handle_face_mock() {
    hal_info "Face auth HAL in mock mode — checking for camera-based face unlock"

    detect_face_hardware

    if [ "$FACE_HW_FOUND" -eq 1 ]; then
        configure_howdy
        configure_pam_face
        hal_info "Software face unlock available via Howdy"
    else
        hal_info "No face auth hardware — face unlock disabled"
    fi

    # Keep alive for monitoring
    while true; do
        sleep 60
        hal_info "Face auth mock heartbeat (PID $$)"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
aidl_hal_run handle_face_native handle_face_mock
