#!/bin/bash
# =============================================================================
# scripts/flash.sh — Halium-style flasher (system + vbmeta only)
# =============================================================================
# Never flashes boot.img or kernel-related partitions.
#
# Usage:
#   bash scripts/flash.sh                # flash system + vbmeta-disabled
#   bash scripts/flash.sh --system-only  # flash system only
#   bash scripts/flash.sh --vbmeta-only  # flash vbmeta-disabled only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/builder/out"

SYSTEM_IMG="$BUILD_DIR/system.img"
VBMETA_IMG="$BUILD_DIR/vbmeta-disabled.img"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[Flash]${NC}  $1"; }
success() { echo -e "${GREEN}[Flash]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[Flash]${NC}  $1"; }
error()   { echo -e "${RED}[Flash]${NC}  $1"; }

FLASH_SYSTEM=true
FLASH_VBMETA=true

case "${1:-}" in
    --system-only) FLASH_VBMETA=false ;;
    --vbmeta-only) FLASH_SYSTEM=false ;;
    --help|-h)
        cat <<USAGE
Usage: $0 [--system-only | --vbmeta-only]

  default         Flash system + vbmeta-disabled
  --system-only   Flash system only
  --vbmeta-only   Flash vbmeta-disabled only

This script NEVER flashes: boot, vendor_boot, dtbo, vendor, userdata.
USAGE
        exit 0
        ;;
    "") ;;
    *) error "Unknown argument: $1"; exit 1 ;;
esac

if ! command -v fastboot >/dev/null 2>&1; then
    error "fastboot not found. Install: sudo apt install android-tools-fastboot"
    exit 1
fi

if [ "$FLASH_SYSTEM" = true ] && [ ! -f "$SYSTEM_IMG" ]; then
    error "system.img not found: $SYSTEM_IMG"
    error "Build with: make build"
    exit 1
fi
if [ "$FLASH_VBMETA" = true ] && [ ! -f "$VBMETA_IMG" ]; then
    error "vbmeta-disabled.img not found: $VBMETA_IMG"
    error "Build with: bash scripts/build_vbmeta_disabled.sh"
    exit 1
fi

[ "$FLASH_SYSTEM" = true ] && info "system.img          : $(du -h "$SYSTEM_IMG" | cut -f1)"
[ "$FLASH_VBMETA" = true ] && info "vbmeta-disabled.img : $(du -h "$VBMETA_IMG" | cut -f1)"

echo ""
info "Waiting for fastboot device..."
WAIT=0
FB_DEVICE=""
while [ $WAIT -lt 60 ]; do
    FB_DEVICE=$(fastboot devices 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$FB_DEVICE" ] && break
    sleep 2
    WAIT=$((WAIT + 2))
done

if [ -z "$FB_DEVICE" ]; then
    error "No fastboot device detected after 60s."
    exit 1
fi
success "Device detected: $FB_DEVICE"

UNLOCKED=$(fastboot getvar unlocked 2>&1 | awk -F': ' '/unlocked:/ {print $2}' || true)
case "$UNLOCKED" in
    yes) success "Bootloader unlocked" ;;
    no)  error "Bootloader locked. Run: fastboot flashing unlock"; exit 1 ;;
    *)   warn "Bootloader lock state unknown - continuing" ;;
esac

echo ""
echo -e "${BOLD}${RED}This will overwrite:${NC}"
[ "$FLASH_SYSTEM" = true ] && echo "  - system"
[ "$FLASH_VBMETA" = true ] && echo "  - vbmeta"
echo "  boot/vendor_boot/dtbo/vendor/userdata are untouched"
echo -n "Type 'FLASH' to confirm: "
read -r CONFIRM
[ "$CONFIRM" = "FLASH" ] || { info "Cancelled."; exit 0; }

if [ "$FLASH_VBMETA" = true ]; then
    info "Flashing vbmeta (verity disabled)"
    fastboot --disable-verity --disable-verification flash vbmeta "$VBMETA_IMG"
fi

if [ "$FLASH_SYSTEM" = true ]; then
    info "Flashing system"
    fastboot flash system "$SYSTEM_IMG"
fi

echo -n "Reboot now? [Y/n]: "
read -r REBOOT
if [[ "$REBOOT" != "n" && "$REBOOT" != "N" ]]; then
    fastboot reboot
fi

success "Flash complete"
echo "To disable Ubuntu launcher: adb shell setprop persist.ubuntu_gsi.enable 0 && adb reboot"
