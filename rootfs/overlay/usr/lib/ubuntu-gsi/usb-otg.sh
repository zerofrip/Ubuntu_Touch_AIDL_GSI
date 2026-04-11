#!/bin/bash
# =============================================================================
# usb-otg.sh — USB OTG Role Switch Handler
# =============================================================================
# Handles USB dual-role switching between:
#   - Device mode (gadget): MTP/RNDIS for PC connection
#   - Host mode (OTG): External USB devices (storage, keyboard, mouse, etc.)
#
# Triggered by udev when USB ID pin state changes, or called manually.
# =============================================================================

set -euo pipefail

LOG="/dev/kmsg"
log() { echo "usb-otg: $1" > "$LOG" 2>/dev/null || echo "[USB-OTG] $1"; }

USB_ROLE_DIR=""
GADGET_SERVICE="usb-gadget.service"

# ---------------------------------------------------------------------------
# Detect USB role switch interface
# ---------------------------------------------------------------------------
detect_role_switch() {
    # Method 1: /sys/class/usb_role (kernel 4.19+)
    for rs in /sys/class/usb_role/*; do
        if [ -d "$rs" ] && [ -f "$rs/role" ]; then
            USB_ROLE_DIR="$rs"
            return 0
        fi
    done

    # Method 2: typec port role
    for tc in /sys/class/typec/port*/data_role; do
        if [ -f "$tc" ]; then
            USB_ROLE_DIR="$(dirname "$tc")"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Get current role
# ---------------------------------------------------------------------------
get_current_role() {
    if [ -n "$USB_ROLE_DIR" ]; then
        if [ -f "$USB_ROLE_DIR/role" ]; then
            cat "$USB_ROLE_DIR/role" | grep -oE 'host|device' || echo "unknown"
        elif [ -f "$USB_ROLE_DIR/data_role" ]; then
            cat "$USB_ROLE_DIR/data_role" | sed 's/\[//;s/\]//' | grep -oE 'host|device' || echo "unknown"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Switch to host mode (OTG: connect external devices)
# ---------------------------------------------------------------------------
switch_to_host() {
    log "Switching to HOST mode (OTG)"

    # Stop gadget service first
    systemctl stop "$GADGET_SERVICE" 2>/dev/null || true

    if [ -n "$USB_ROLE_DIR" ]; then
        if [ -f "$USB_ROLE_DIR/role" ]; then
            echo "host" > "$USB_ROLE_DIR/role" 2>/dev/null || true
        elif [ -f "$USB_ROLE_DIR/data_role" ]; then
            echo "host" > "$USB_ROLE_DIR/data_role" 2>/dev/null || true
        fi
    fi

    # Enable VBUS power for OTG (device-specific paths)
    for vbus in \
        /sys/devices/platform/soc/*/usb_otg/vbus \
        /sys/class/power_supply/otg/online \
        /sys/devices/platform/*.usb/power/otg \
        ; do
        if [ -f "$vbus" ]; then
            echo 1 > "$vbus" 2>/dev/null || true
            log "VBUS enabled: $vbus"
            break
        fi
    done

    log "HOST mode active — external USB devices supported"
}

# ---------------------------------------------------------------------------
# Switch to device mode (gadget: PC connection)
# ---------------------------------------------------------------------------
switch_to_device() {
    log "Switching to DEVICE mode (gadget)"

    # Disable VBUS power
    for vbus in \
        /sys/devices/platform/soc/*/usb_otg/vbus \
        /sys/class/power_supply/otg/online \
        /sys/devices/platform/*.usb/power/otg \
        ; do
        if [ -f "$vbus" ]; then
            echo 0 > "$vbus" 2>/dev/null || true
            break
        fi
    done

    if [ -n "$USB_ROLE_DIR" ]; then
        if [ -f "$USB_ROLE_DIR/role" ]; then
            echo "device" > "$USB_ROLE_DIR/role" 2>/dev/null || true
        elif [ -f "$USB_ROLE_DIR/data_role" ]; then
            echo "device" > "$USB_ROLE_DIR/data_role" 2>/dev/null || true
        fi
    fi

    # Restart gadget service
    systemctl start "$GADGET_SERVICE" 2>/dev/null || true

    log "DEVICE mode active — MTP/RNDIS available"
}

# ---------------------------------------------------------------------------
# Auto-detect based on ID pin / cable state
# ---------------------------------------------------------------------------
auto_detect() {
    # Check USB ID pin (OTG cable detection)
    # ID pin grounded = host (OTG adapter plugged in)
    # ID pin floating = device (normal cable or no cable)
    for id_pin in \
        /sys/class/power_supply/usb/usb_otg \
        /sys/devices/platform/soc/*/extcon/*/state \
        /sys/class/extcon/*/state \
        ; do
        if [ -f "$id_pin" ]; then
            STATE=$(cat "$id_pin" 2>/dev/null || echo "")
            if echo "$STATE" | grep -qiE "USB-HOST=1|USB_HOST=1|1"; then
                switch_to_host
                return
            fi
        fi
    done

    # Default: device mode
    switch_to_device
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
detect_role_switch || log "WARN: No USB role switch interface found — using fallback"

case "${1:-auto}" in
    host)   switch_to_host   ;;
    device) switch_to_device ;;
    auto)   auto_detect      ;;
    status)
        ROLE=$(get_current_role)
        echo "USB role: $ROLE"
        echo "Role switch: ${USB_ROLE_DIR:-not detected}"
        ;;
    *)
        echo "Usage: $0 {host|device|auto|status}"
        exit 1
        ;;
esac
