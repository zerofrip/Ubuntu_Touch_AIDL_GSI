#!/bin/bash
# =============================================================================
# aidl/bluetooth/bluetooth_hal.sh — Bluetooth AIDL HAL Wrapper
# =============================================================================
# Bridges BlueZ to Android vendor Bluetooth HAL via
# AIDL binder interface android.hardware.bluetooth.IBluetoothHci.
#
# Detection flow:
#   1. Unblock Bluetooth radio via rfkill
#   2. Detect HCI devices (hci0, etc.)
#   3. Configure and start BlueZ
#   4. Symlink vendor Bluetooth firmware
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "bluetooth" "android.hardware.bluetooth.IBluetoothHci" "optional"

# ---------------------------------------------------------------------------
# Bluetooth radio preparation
# ---------------------------------------------------------------------------
prepare_bluetooth_radio() {
    # Unblock Bluetooth radio
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock bluetooth 2>/dev/null || true
        hal_info "rfkill: unblocked Bluetooth"
    fi

    # Some Android devices need a vendor binary to initialize BT firmware
    for bt_init in /vendor/bin/hw/android.hardware.bluetooth* \
                   /vendor/bin/brcm_patchram_plus \
                   /vendor/bin/btnvtool; do
        if [ -x "$bt_init" ]; then
            hal_info "Vendor BT init found: $bt_init"
        fi
    done
}

# ---------------------------------------------------------------------------
# Symlink vendor Bluetooth firmware
# ---------------------------------------------------------------------------
symlink_bt_firmware() {
    for fw_dir in /vendor/firmware /vendor/firmware/bt /odm/firmware; do
        [ -d "$fw_dir" ] || continue
        for fw_file in "$fw_dir"/BCM*.hcd "$fw_dir"/bt_*.bin "$fw_dir"/*.btp \
                       "$fw_dir"/WCNSS*.bin "$fw_dir"/crc*.bin; do
            [ -f "$fw_file" ] || continue
            local base
            base=$(basename "$fw_file")
            if [ ! -e "/lib/firmware/$base" ]; then
                ln -sf "$fw_file" "/lib/firmware/$base" 2>/dev/null || true
                hal_info "Linked BT firmware: $base"
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Detect HCI devices
# ---------------------------------------------------------------------------
detect_hci_devices() {
    HCI_COUNT=0
    HCI_DEVICES=""

    for hci in /sys/class/bluetooth/hci*; do
        [ -d "$hci" ] || continue
        HCI_COUNT=$((HCI_COUNT + 1))
        local hci_name
        hci_name=$(basename "$hci")
        HCI_DEVICES="${HCI_DEVICES} ${hci_name}"
        hal_info "HCI device: $hci_name"
    done

    hal_set_state "hci_count" "$HCI_COUNT"
    hal_info "Detected $HCI_COUNT HCI device(s):$HCI_DEVICES"
}

# ---------------------------------------------------------------------------
# Start BlueZ
# ---------------------------------------------------------------------------
start_bluez() {
    if ! command -v bluetoothd >/dev/null 2>&1; then
        hal_warn "BlueZ (bluetoothd) not installed"
        return 1
    fi

    # Enable and start bluetooth.service
    if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
        systemctl enable --now bluetooth.service 2>/dev/null || true
        hal_info "bluetooth.service enabled and started"
    else
        # Manual start
        bluetoothd &
        hal_info "bluetoothd started manually (PID $!)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Native handler — vendor Bluetooth HAL available
# ---------------------------------------------------------------------------
bluetooth_native() {
    hal_info "Bluetooth HAL available — initializing BT subsystem"

    # Step 1: Prepare radio
    prepare_bluetooth_radio
    symlink_bt_firmware

    # Step 2: Wait briefly for HCI to appear after rfkill unblock
    sleep 2
    detect_hci_devices

    # Step 3: Start BlueZ
    if [ "$HCI_COUNT" -gt 0 ]; then
        start_bluez
        hal_set_state "status" "active"
    else
        hal_warn "No HCI devices found — Bluetooth hardware may not be accessible"
        start_bluez  # BlueZ can still wait for hotplug
        hal_set_state "status" "no_hci"
    fi

    # Keep alive
    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor Bluetooth HAL
# ---------------------------------------------------------------------------
bluetooth_mock() {
    hal_info "Bluetooth HAL mock: checking for standalone HCI"

    prepare_bluetooth_radio
    symlink_bt_firmware
    sleep 2
    detect_hci_devices

    if [ "$HCI_COUNT" -gt 0 ]; then
        hal_info "HCI found without vendor HAL — using BlueZ directly"
        start_bluez
        hal_set_state "status" "standalone"
    else
        hal_info "No Bluetooth hardware available"
        hal_set_state "hci_count" "0"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run bluetooth_native bluetooth_mock
