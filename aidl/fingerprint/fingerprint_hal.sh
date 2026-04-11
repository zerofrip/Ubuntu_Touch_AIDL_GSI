#!/bin/bash
# =============================================================================
# aidl/fingerprint/fingerprint_hal.sh — Fingerprint AIDL HAL Wrapper
# =============================================================================
# Bridges fprintd (libfprint) to Android vendor fingerprint HAL via
# AIDL binder interface android.hardware.biometrics.fingerprint.
#
# Detection flow:
#   1. Check vendor VINTF for biometrics.fingerprint AIDL HAL
#   2. Detect fingerprint device via sysfs / input subsystem
#   3. Configure fprintd for D-Bus fingerprint access
#   4. Set up PAM integration for unlock/sudo authentication
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "fingerprint" "android.hardware.biometrics.fingerprint.IFingerprint" "optional"

# ---------------------------------------------------------------------------
# Fingerprint device discovery
# ---------------------------------------------------------------------------
detect_fingerprint_device() {
    FP_FOUND=0
    FP_DEVICE=""
    FP_DRIVER=""

    # Method 1: Check for vendor fingerprint device nodes
    for fp_dev in /dev/fingerprint* /dev/goodix_fp /dev/fpc1020 /dev/silead_fp \
                  /dev/elan_fp /dev/cdfinger /dev/sunwave_fp; do
        if [ -c "$fp_dev" ] || [ -e "$fp_dev" ]; then
            FP_FOUND=1
            FP_DEVICE="$fp_dev"
            hal_info "Fingerprint device node found: $fp_dev"
            break
        fi
    done

    # Method 2: Scan sysfs for fingerprint-related platform devices
    if [ "$FP_FOUND" -eq 0 ]; then
        for sysfs_dev in /sys/devices/platform/*/fingerprint \
                         /sys/devices/platform/fingerprint* \
                         /sys/devices/soc/*/fingerprint; do
            if [ -d "$sysfs_dev" ]; then
                FP_FOUND=1
                FP_DEVICE="$sysfs_dev"
                hal_info "Fingerprint sysfs node found: $sysfs_dev"
                break
            fi
        done
    fi

    # Method 3: Check input devices for fingerprint
    if [ "$FP_FOUND" -eq 0 ]; then
        for input_dev in /sys/class/input/input*/name; do
            [ -f "$input_dev" ] || continue
            local name
            name=$(cat "$input_dev" 2>/dev/null)
            case "$name" in
                *fingerprint*|*fpc*|*goodix*|*silead*|*elan*|*cdfinger*|*sunwave*)
                    FP_FOUND=1
                    FP_DEVICE="$input_dev"
                    hal_info "Fingerprint input device: $name"
                    break
                    ;;
            esac
        done
    fi

    # Method 4: Check vendor init*.rc for fingerprint service
    if [ "$FP_FOUND" -eq 0 ]; then
        for rc_file in /vendor/etc/init/*.rc /odm/etc/init/*.rc; do
            [ -f "$rc_file" ] || continue
            if grep -qi "fingerprint" "$rc_file" 2>/dev/null; then
                FP_FOUND=1
                FP_DEVICE="vendor_hal"
                FP_DRIVER=$(grep -i "service.*fingerprint" "$rc_file" 2>/dev/null | head -1 | awk '{print $2}')
                hal_info "Vendor fingerprint service found in: $rc_file ($FP_DRIVER)"
                break
            fi
        done
    fi

    hal_set_state "fp_found" "$FP_FOUND"
    hal_set_state "fp_device" "$FP_DEVICE"

    if [ "$FP_FOUND" -eq 0 ]; then
        hal_warn "No fingerprint hardware detected"
    fi
    return $((1 - FP_FOUND))
}

# ---------------------------------------------------------------------------
# Configure fprintd and set device permissions
# ---------------------------------------------------------------------------
configure_fprintd() {
    hal_info "Configuring fprintd for fingerprint authentication"

    # Set permissions on fingerprint device nodes
    for fp_dev in /dev/fingerprint* /dev/goodix_fp /dev/fpc1020 /dev/silead_fp \
                  /dev/elan_fp /dev/cdfinger /dev/sunwave_fp; do
        if [ -c "$fp_dev" ] || [ -e "$fp_dev" ]; then
            chmod 0660 "$fp_dev" 2>/dev/null || true
            chgrp input "$fp_dev" 2>/dev/null || true
            hal_info "Set permissions on $fp_dev"
        fi
    done

    # Enable fprintd D-Bus service
    if command -v fprintd >/dev/null 2>&1; then
        # fprintd runs as a D-Bus activated service, just ensure the policy exists
        if [ -f /usr/share/dbus-1/system-services/net.reactivated.Fprint.service ]; then
            hal_info "fprintd D-Bus service file found"
        else
            hal_warn "fprintd installed but D-Bus service file missing"
        fi

        # Ensure fprintd can access the device
        if [ -d /etc/fprintd ]; then
            hal_info "fprintd configuration directory exists"
        fi

        hal_set_state "fprintd_available" "1"
    else
        hal_warn "fprintd not installed — fingerprint enrollment unavailable"
        hal_set_state "fprintd_available" "0"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# PAM integration for fingerprint unlock
# ---------------------------------------------------------------------------
configure_pam_fingerprint() {
    hal_info "Configuring PAM fingerprint authentication"

    # Check if pam_fprintd module is available
    local pam_fprintd=""
    for pam_path in /usr/lib/*/security/pam_fprintd.so /lib/*/security/pam_fprintd.so; do
        if [ -f "$pam_path" ]; then
            pam_fprintd="$pam_path"
            break
        fi
    done

    if [ -z "$pam_fprintd" ]; then
        hal_warn "pam_fprintd.so not found — PAM integration skipped"
        return 1
    fi

    # Add fingerprint auth to common-auth (before password auth, sufficient mode)
    local pam_common="/etc/pam.d/common-auth"
    if [ -f "$pam_common" ]; then
        if ! grep -q "pam_fprintd" "$pam_common" 2>/dev/null; then
            # Insert fingerprint auth before standard pam_unix
            sed -i '/^auth.*pam_unix\.so/i auth\tsufficient\tpam_fprintd.so' \
                "$pam_common" 2>/dev/null || true
            hal_info "pam_fprintd added to $pam_common"
        else
            hal_info "pam_fprintd already configured in $pam_common"
        fi
    fi

    hal_set_state "pam_fingerprint" "1"
    return 0
}

# ---------------------------------------------------------------------------
# Vendor HAL bridge (native mode)
# ---------------------------------------------------------------------------
handle_fingerprint_native() {
    hal_info "Starting fingerprint HAL in native mode (vendor HAL available)"

    detect_fingerprint_device
    configure_fprintd
    configure_pam_fingerprint

    # Monitor vendor fingerprint service health
    while true; do
        if binder_service_registered "android.hardware.biometrics.fingerprint"; then
            hal_set_state "vendor_status" "alive"
        else
            hal_set_state "vendor_status" "unavailable"
            hal_warn "Vendor fingerprint binder service not responding"
        fi
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock mode (no vendor HAL)
# ---------------------------------------------------------------------------
handle_fingerprint_mock() {
    hal_info "Fingerprint HAL in mock mode — checking for USB/host fingerprint readers"

    # Even without vendor HAL, USB fingerprint readers may work via libfprint
    detect_fingerprint_device

    if command -v fprintd >/dev/null 2>&1; then
        configure_fprintd
        configure_pam_fingerprint
        hal_info "fprintd available for USB fingerprint readers"
    fi

    # Keep alive for monitoring
    while true; do
        sleep 60
        hal_info "Fingerprint mock heartbeat (PID $$)"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
aidl_hal_run handle_fingerprint_native handle_fingerprint_mock
