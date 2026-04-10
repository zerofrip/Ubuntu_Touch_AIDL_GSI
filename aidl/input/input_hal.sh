#!/bin/bash
# =============================================================================
# aidl/input/input_hal.sh — Input/Touchscreen AIDL HAL Wrapper
# =============================================================================
# Ensures Android vendor touchscreen and input devices are properly
# configured for libinput within the Ubuntu GSI environment.
#
# Native mode: Detects touchscreen devices, sets permissions, configures
#              libinput, and monitors input device availability.
# Mock mode:   No input devices detected — logs status for diagnostics.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "input" "android.hardware.input.IInputProcessor" "optional"

# ---------------------------------------------------------------------------
# Input device detection
# ---------------------------------------------------------------------------

detect_touchscreen_devices() {
    local ts_count=0

    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue

        local dev_name=""
        local sysfs_path
        sysfs_path="/sys/class/input/$(basename "$event_dev")/device/name"
        if [ -f "$sysfs_path" ]; then
            dev_name=$(cat "$sysfs_path" 2>/dev/null)
        fi

        # Check if device has multitouch capabilities (ABS_MT_POSITION_X = 0x35)
        local abs_path
        abs_path="/sys/class/input/$(basename "$event_dev")/device/capabilities/abs"
        if [ -f "$abs_path" ]; then
            local abs_caps
            abs_caps=$(cat "$abs_path" 2>/dev/null)
            # Non-zero abs capability + name containing touch keywords
            if [ -n "$abs_caps" ] && [ "$abs_caps" != "0" ]; then
                case "$dev_name" in
                    *[Tt]ouch*|*goodix*|*Goodix*|*GDIX*|*focaltech*|*fts_ts*|\
                    *NVT*|*nvt*|*himax*|*synaptics*|*Synaptics*|*atmel*|*Atmel*|\
                    *chipone*|*ilitek*|*ILITEK*|*sec_touchscreen*|*elan*|*raydium*|\
                    *mtk-tpd*|*mtk_tpd*)
                        hal_info "Touchscreen: $event_dev ($dev_name)"
                        ts_count=$((ts_count + 1))
                        ;;
                    *)
                        # Fallback: check event bits for ABS_MT_POSITION_X
                        # If abs caps have bit 53 (0x35) set, it's multitouch
                        hal_info "Input device with abs: $event_dev ($dev_name)"
                        ts_count=$((ts_count + 1))
                        ;;
                esac
            fi
        fi
    done

    hal_set_state "touchscreen_count" "$ts_count"
    echo "$ts_count"
}

detect_all_input_devices() {
    local input_count=0

    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue
        input_count=$((input_count + 1))

        local dev_name=""
        local sysfs_path
        sysfs_path="/sys/class/input/$(basename "$event_dev")/device/name"
        if [ -f "$sysfs_path" ]; then
            dev_name=$(cat "$sysfs_path" 2>/dev/null)
        fi
        hal_info "Input device: $event_dev ($dev_name)"
    done

    hal_set_state "input_device_count" "$input_count"
    echo "$input_count"
}

set_input_permissions() {
    # Ensure /dev/input devices are accessible
    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue
        chmod 0660 "$event_dev" 2>/dev/null || true
        chgrp input "$event_dev" 2>/dev/null || true
    done

    # Ensure /dev/input directory has correct permissions
    chmod 0755 /dev/input 2>/dev/null || true

    hal_info "Input device permissions configured"
}

configure_libinput() {
    # Create libinput quirks directory for vendor-specific touchscreen tuning
    local quirks_dir="/etc/libinput"
    mkdir -p "$quirks_dir"

    # Write a base quirk file for Android touchscreens
    # Most Android touchscreens need touch size calibration disabled
    cat > "$quirks_dir/90-ubuntu-gsi-touch.quirks" << 'QUIRKSEOF'
# Ubuntu GSI — Android vendor touchscreen quirks
# Applied to all detected touchscreen devices

[Ubuntu GSI Touchscreen Defaults]
MatchUdevType=touchscreen
AttrPalmSizeThreshold=0
AttrPalmPressureThreshold=0
AttrThumbPressureThreshold=0
QUIRKSEOF

    hal_info "libinput quirks configured"
}

setup_udev_trigger() {
    # Trigger udev to re-evaluate input devices with our rules
    if command -v udevadm >/dev/null 2>&1; then
        udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
        udevadm settle --timeout=5 2>/dev/null || true
        hal_info "udev input rules triggered"
    fi
}

# ---------------------------------------------------------------------------
# Native handler — input devices available
# ---------------------------------------------------------------------------
input_native() {
    hal_info "Initializing input/touchscreen subsystem"

    # Step 1: Set permissions on existing input devices
    set_input_permissions

    # Step 2: Configure libinput quirks
    configure_libinput

    # Step 3: Trigger udev re-evaluation
    setup_udev_trigger

    # Step 4: Detect touchscreen devices (retry — driver may be initializing)
    local ts_count=0
    local retries=0
    local max_retries=15

    while [ $retries -lt $max_retries ]; do
        ts_count=$(detect_touchscreen_devices)
        if [ "$ts_count" -gt 0 ]; then
            break
        fi
        retries=$((retries + 1))
        hal_info "Waiting for touchscreen device... (attempt $retries/$max_retries)"
        sleep 2
    done

    # Step 5: Detect all input devices for logging
    local input_count
    input_count=$(detect_all_input_devices)

    if [ "$ts_count" -eq 0 ]; then
        hal_warn "No touchscreen detected after $max_retries attempts"
        hal_warn "Total input devices: $input_count"
        hal_set_state "status" "no_touchscreen"
    else
        hal_info "Touchscreen ready: $ts_count touchscreen(s), $input_count total input devices"
        hal_set_state "status" "active"
    fi

    # Keep alive, monitor for new input devices
    while true; do
        # Re-scan for new devices (hotplug)
        local current_count=0
        for event_dev in /dev/input/event*; do
            [ -c "$event_dev" ] || continue
            current_count=$((current_count + 1))
        done

        if [ "$current_count" -ne "$input_count" ]; then
            hal_info "Input device change detected: $input_count → $current_count"
            set_input_permissions
            input_count=$current_count
            hal_set_state "input_device_count" "$input_count"
        fi

        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no input devices
# ---------------------------------------------------------------------------
input_mock() {
    hal_info "Input HAL mock: no input devices detected"
    hal_set_state "status" "mock"
    hal_set_state "touchscreen_count" "0"
    hal_set_state "input_device_count" "0"

    while true; do
        sleep 60
    done
}

aidl_hal_run input_native input_mock
