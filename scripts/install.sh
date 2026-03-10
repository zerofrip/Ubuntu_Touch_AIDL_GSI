#!/bin/bash
# =============================================================================
# scripts/install.sh — Device Flash & Install Helper
# =============================================================================
# Automates flashing system.img via Fastboot and pushing rootfs via ADB.
# Includes safety checks, device detection, and confirmation prompts.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC}  $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/builder/out"

SYSTEM_IMG="$BUILD_DIR/system.img"
ROOTFS_SQUASHFS="$BUILD_DIR/linux_rootfs.squashfs"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}         Ubuntu GSI — Device Install Helper                   ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Verify build artifacts exist
# ---------------------------------------------------------------------------
info "Checking build artifacts..."

MISSING=0
if [ ! -f "$SYSTEM_IMG" ]; then
    error "system.img not found at: $SYSTEM_IMG"
    MISSING=1
fi
if [ ! -f "$ROOTFS_SQUASHFS" ]; then
    error "linux_rootfs.squashfs not found at: $ROOTFS_SQUASHFS"
    MISSING=1
fi
if [ "$MISSING" -eq 1 ]; then
    echo ""
    error "Run ./build.sh first to generate the artifacts."
    exit 1
fi

SIMG_SIZE=$(du -h "$SYSTEM_IMG" | cut -f1)
RIMG_SIZE=$(du -h "$ROOTFS_SQUASHFS" | cut -f1)
success "system.img ($SIMG_SIZE) and linux_rootfs.squashfs ($RIMG_SIZE) found"
echo ""

# ---------------------------------------------------------------------------
# 2. Verify host tools
# ---------------------------------------------------------------------------
info "Checking required tools..."

for tool in adb fastboot; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        error "$tool not found. Install: sudo apt install android-tools-adb android-tools-fastboot"
        exit 1
    fi
done
success "adb and fastboot are available"
echo ""

# ---------------------------------------------------------------------------
# 3. Detect device
# ---------------------------------------------------------------------------
info "Detecting connected device..."

# Check for fastboot device first
FB_DEVICE=$(fastboot devices 2>/dev/null | head -1 | awk '{print $1}')

if [ -n "$FB_DEVICE" ]; then
    success "Fastboot device detected: $FB_DEVICE"
    DEVICE_MODE="fastboot"
else
    # Try ADB
    ADB_DEVICE=$(adb devices 2>/dev/null | grep -w "device" | head -1 | awk '{print $1}')
    if [ -n "$ADB_DEVICE" ]; then
        success "ADB device detected: $ADB_DEVICE"
        DEVICE_MODE="adb"

        # Check Treble support
        info "Checking Treble support..."
        TREBLE=$(adb shell getprop ro.treble.enabled 2>/dev/null || echo "unknown")
        if [ "$TREBLE" = "true" ]; then
            success "Device supports Project Treble"
        else
            warning "Treble support: $TREBLE — GSI may not work on non-Treble devices"
        fi

        # Show device info
        DEVICE_MODEL=$(adb shell getprop ro.product.model 2>/dev/null || echo "Unknown")
        DEVICE_ANDROID=$(adb shell getprop ro.build.version.release 2>/dev/null || echo "Unknown")
        info "Device: $DEVICE_MODEL (Android $DEVICE_ANDROID)"
    else
        error "No device found. Connect a device via USB and enable USB debugging."
        echo ""
        info "To enter fastboot mode manually:"
        echo "  adb reboot bootloader"
        echo ""
        exit 1
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# 4. Flash sequence
# ---------------------------------------------------------------------------
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${RED}${BOLD}  ⚠  WARNING: This will OVERWRITE the system partition!  ⚠${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  system.img     : $SYSTEM_IMG ($SIMG_SIZE)"
echo -e "  rootfs squashfs: $ROOTFS_SQUASHFS ($RIMG_SIZE)"
echo ""
echo -n -e "${YELLOW}Proceed with installation? [y/N]: ${NC}"
read -r CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    info "Installation cancelled by user."
    exit 0
fi

echo ""

# Step A: Reboot to bootloader if in ADB mode
if [ "$DEVICE_MODE" = "adb" ]; then
    info "Rebooting device to bootloader..."
    adb reboot bootloader
    info "Waiting for fastboot device (up to 30s)..."
    WAIT=0
    while [ $WAIT -lt 30 ]; do
        FB_DEVICE=$(fastboot devices 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$FB_DEVICE" ]; then
            break
        fi
        sleep 1
        WAIT=$((WAIT + 1))
    done
    if [ -z "$FB_DEVICE" ]; then
        error "Fastboot device not detected after 30s. Check USB connection."
        exit 1
    fi
    success "Device in fastboot mode: $FB_DEVICE"
fi

# Step B: Flash system.img
info "Flashing system.img..."
if fastboot flash system "$SYSTEM_IMG"; then
    success "system.img flashed successfully"
else
    error "Fastboot flash failed!"
    exit 1
fi

# Step C: Reboot to system and push rootfs
info "Rebooting device..."
fastboot reboot
info "Waiting for ADB device (up to 60s)..."
WAIT=0
while [ $WAIT -lt 60 ]; do
    ADB_DEVICE=$(adb devices 2>/dev/null | grep -w "device" | head -1 | awk '{print $1}')
    if [ -n "$ADB_DEVICE" ]; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done
if [ -z "$ADB_DEVICE" ]; then
    error "ADB device not detected after 60s. Push rootfs manually:"
    echo "  adb push $ROOTFS_SQUASHFS /data/"
    exit 1
fi

info "Pushing rootfs to /data/..."
if adb push "$ROOTFS_SQUASHFS" /data/; then
    success "rootfs pushed to /data/linux_rootfs.squashfs"
else
    error "ADB push failed!"
    exit 1
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo -e "  Reboot your device to start Ubuntu Touch GSI."
echo -e "  If the system fails to boot, force a rollback:"
echo -e "    adb shell touch /data/uhl_overlay/rollback"
echo -e "    adb reboot"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
