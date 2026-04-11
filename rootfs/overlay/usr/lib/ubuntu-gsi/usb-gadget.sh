#!/bin/bash
# =============================================================================
# usb-gadget.sh — USB Gadget ConfigFS Setup (MTP + RNDIS)
# =============================================================================
# Configures the USB gadget via configfs to expose:
#   - MTP (Media Transfer Protocol) for file access from PC
#   - RNDIS (USB Ethernet) for network/SSH access from PC
# Charging works at the hardware level regardless of this script.
# =============================================================================

set -euo pipefail

CONFIGFS="/sys/kernel/config/usb_gadget"
GADGET="$CONFIGFS/g1"
UDC=""

log() { echo "[$(date -Iseconds)] [USB-Gadget] $1"; }

# ---------------------------------------------------------------------------
# Detect UDC (USB Device Controller)
# ---------------------------------------------------------------------------
detect_udc() {
    for udc in /sys/class/udc/*; do
        if [ -d "$udc" ]; then
            UDC="$(basename "$udc")"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Cleanup on stop
# ---------------------------------------------------------------------------
cleanup() {
    if [ -d "$GADGET" ]; then
        # Disable gadget
        echo "" > "$GADGET/UDC" 2>/dev/null || true

        # Remove configurations
        rm "$GADGET/configs/c.1/ffs.mtp" 2>/dev/null || true
        rm "$GADGET/configs/c.1/rndis.usb0" 2>/dev/null || true
        rmdir "$GADGET/configs/c.1/strings/0x409" 2>/dev/null || true
        rmdir "$GADGET/configs/c.1" 2>/dev/null || true

        # Remove functions
        rmdir "$GADGET/functions/ffs.mtp" 2>/dev/null || true
        rmdir "$GADGET/functions/rndis.usb0" 2>/dev/null || true

        # Remove gadget
        rmdir "$GADGET/strings/0x409" 2>/dev/null || true
        rmdir "$GADGET" 2>/dev/null || true
    fi

    log "Gadget cleaned up"
}

# ---------------------------------------------------------------------------
# Main setup
# ---------------------------------------------------------------------------
setup() {
    # Mount configfs if not mounted
    if [ ! -d "$CONFIGFS" ]; then
        mount -t configfs none /sys/kernel/config 2>/dev/null || true
    fi

    if [ ! -d "$CONFIGFS" ]; then
        log "ERROR: configfs not available — USB gadget not supported"
        exit 1
    fi

    if ! detect_udc; then
        log "ERROR: No UDC found — USB device controller not available"
        exit 1
    fi
    log "UDC detected: $UDC"

    # Clean up any existing gadget
    cleanup

    # Create gadget
    mkdir -p "$GADGET"

    # Device descriptors
    echo 0x1d6b > "$GADGET/idVendor"   # Linux Foundation
    echo 0x0104 > "$GADGET/idProduct"   # Multifunction Composite Gadget
    echo 0x0100 > "$GADGET/bcdDevice"
    echo 0x0200 > "$GADGET/bcdUSB"

    # Device class: use interface association
    echo 0xEF > "$GADGET/bDeviceClass"
    echo 0x02 > "$GADGET/bDeviceSubClass"
    echo 0x01 > "$GADGET/bDeviceProtocol"

    # Strings
    mkdir -p "$GADGET/strings/0x409"
    echo "Ubuntu GSI"        > "$GADGET/strings/0x409/manufacturer"
    echo "Ubuntu Touch GSI"  > "$GADGET/strings/0x409/product"

    # Generate a persistent serial number based on device
    SERIAL="$(cat /etc/machine-id 2>/dev/null | head -c 16 || echo 'ubuntugsi0000001')"
    echo "$SERIAL" > "$GADGET/strings/0x409/serialnumber"

    # Configuration
    mkdir -p "$GADGET/configs/c.1/strings/0x409"
    echo "MTP + RNDIS" > "$GADGET/configs/c.1/strings/0x409/configuration"
    echo 500 > "$GADGET/configs/c.1/MaxPower"

    # --- Function: RNDIS (USB Ethernet) ---
    mkdir -p "$GADGET/functions/rndis.usb0"
    ln -sf "$GADGET/functions/rndis.usb0" "$GADGET/configs/c.1/rndis.usb0"
    log "RNDIS function created"

    # --- Function: MTP (FunctionFS) ---
    mkdir -p "$GADGET/functions/ffs.mtp"
    ln -sf "$GADGET/functions/ffs.mtp" "$GADGET/configs/c.1/ffs.mtp"
    log "MTP function created"

    # Mount FunctionFS for MTP
    mkdir -p /dev/ffs-mtp
    mount -t functionfs mtp /dev/ffs-mtp 2>/dev/null || true

    # Enable gadget
    echo "$UDC" > "$GADGET/UDC"
    log "USB Gadget enabled on $UDC (MTP + RNDIS)"

    # Configure RNDIS network interface
    if ip link show usb0 >/dev/null 2>&1; then
        ip addr add 10.15.19.1/24 dev usb0 2>/dev/null || true
        ip link set usb0 up 2>/dev/null || true
        log "RNDIS interface usb0 configured (10.15.19.1/24)"
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-start}" in
    start)  setup   ;;
    stop)   cleanup ;;
    *)      echo "Usage: $0 {start|stop}"; exit 1 ;;
esac
