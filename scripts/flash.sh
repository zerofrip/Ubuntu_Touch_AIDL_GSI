#!/bin/bash
# =============================================================================
# scripts/flash.sh — Halium-style flasher (system + vbmeta + userdata)
# =============================================================================
# Never flashes boot.img or kernel-related partitions.
#
# Usage:
#   bash scripts/flash.sh                 # flash system + vbmeta-disabled + userdata
#   bash scripts/flash.sh --system-only   # flash system only
#   bash scripts/flash.sh --vbmeta-only   # flash vbmeta-disabled only
#   bash scripts/flash.sh --userdata-only # flash userdata only
#   bash scripts/flash.sh --no-userdata   # skip userdata in default mode
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/builder/out"

SYSTEM_IMG="$BUILD_DIR/system.img"
VBMETA_IMG="$BUILD_DIR/vbmeta-disabled.img"
USERDATA_IMG="$BUILD_DIR/userdata.img"

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
FLASH_USERDATA=true

case "${1:-}" in
    --system-only) FLASH_VBMETA=false; FLASH_USERDATA=false ;;
    --vbmeta-only) FLASH_SYSTEM=false; FLASH_USERDATA=false ;;
    --userdata-only) FLASH_SYSTEM=false; FLASH_VBMETA=false ;;
    --no-userdata) FLASH_USERDATA=false ;;
    --help|-h)
        cat <<USAGE
Usage: $0 [--system-only | --vbmeta-only | --userdata-only | --no-userdata]

  default         Flash system + vbmeta-disabled + userdata
  --system-only   Flash system only
  --vbmeta-only   Flash vbmeta-disabled only
  --userdata-only Flash userdata only
  --no-userdata   Skip userdata flash in default mode

This script NEVER flashes: boot, vendor_boot, dtbo, vendor.
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
if [ "$FLASH_USERDATA" = true ] && [ ! -f "$USERDATA_IMG" ]; then
    warn "userdata.img not found: $USERDATA_IMG"
    info "Auto-building userdata.img via scripts/build_userdata_img.sh"
    if [ "$(id -u)" -ne 0 ]; then
        sudo bash "$REPO_ROOT/scripts/build_userdata_img.sh"
    else
        bash "$REPO_ROOT/scripts/build_userdata_img.sh"
    fi
    [ -f "$USERDATA_IMG" ] || { error "Failed to auto-build userdata.img"; exit 1; }
fi

[ "$FLASH_SYSTEM" = true ] && info "system.img          : $(du -h "$SYSTEM_IMG" | cut -f1)"
[ "$FLASH_VBMETA" = true ] && info "vbmeta-disabled.img : $(du -h "$VBMETA_IMG" | cut -f1)"
[ "$FLASH_USERDATA" = true ] && info "userdata.img        : $(du -h "$USERDATA_IMG" | cut -f1)"

getvar_value() {
    local key="$1"
    local out=""
    out=$(timeout 12s fastboot getvar "$key" 2>&1 || true)
    echo "$out" | awk -v k="$key" '
        $0 ~ k":" {
            sub(/^.*: /, "", $0)
            gsub(/\r/, "", $0)
            print $0
            exit
        }'
}

wait_for_fastboot_device() {
    local wait=0
    local dev=""
    while [ $wait -lt 60 ]; do
        dev=$(fastboot devices 2>/dev/null | head -1 | awk '{print $1}')
        [ -n "$dev" ] && { echo "$dev"; return 0; }
        sleep 2
        wait=$((wait + 2))
    done
    return 1
}

hex_to_dec() {
    local v="$1"
    printf "%d" "$((v))"
}

ensure_fastbootd() {
    local mode
    mode=$(getvar_value is-userspace || true)
    if [ "$mode" = "yes" ]; then
        return 0
    fi
    warn "Device not in fastbootd userspace mode. Switching..."
    if ! timeout 20s fastboot reboot fastboot >/dev/null 2>&1; then
        warn "Timed out while running 'fastboot reboot fastboot'."
        warn "Please switch to fastbootd manually, then press Enter to continue."
        read -r _
    fi
    sleep 2
    wait_for_fastboot_device >/dev/null || {
        warn "Failed to auto-detect device after fastbootd switch."
        warn "Reconnect device in fastbootd and press Enter to retry."
        read -r _
        wait_for_fastboot_device >/dev/null || return 1
    }
    mode=$(getvar_value is-userspace || true)
    [ "$mode" = "yes" ] || return 1
}

check_partition_capacity() {
    local part="$1"
    local img="$2"
    local img_size part_hex part_size
    img_size=$(stat -c '%s' "$img")
    part_hex=$(getvar_value "partition-size:$part" || true)
    if [ -z "$part_hex" ]; then
        warn "Could not query partition-size:$part; skipping size check."
        return 0
    fi
    part_size=$(hex_to_dec "$part_hex")
    if [ "$img_size" -le "$part_size" ]; then
        return 0
    fi
    return 1
}

ensure_system_partition_capacity() {
    [ "$FLASH_SYSTEM" = true ] || return 0
    if ! ensure_fastbootd; then
        warn "Unable to verify fastbootd mode; skipping auto partition resize check."
        warn "If system flash fails, run in fastbootd and retry."
        return 0
    fi

    local slot part img_size part_hex part_size target_size
    slot=$(getvar_value current-slot || true)
    [ -n "$slot" ] || slot="a"
    part="system_${slot}"

    if check_partition_capacity "$part" "$SYSTEM_IMG"; then
        info "Partition check: $part has sufficient capacity."
        return 0
    fi

    img_size=$(stat -c '%s' "$SYSTEM_IMG")
    part_hex=$(getvar_value "partition-size:$part")
    part_size=$(hex_to_dec "$part_hex")
    target_size=$((img_size + 64 * 1024 * 1024))

    warn "Partition check: $part too small."
    warn "  current: ${part_size} bytes"
    warn "  image  : ${img_size} bytes"
    warn "  target : ${target_size} bytes"
    echo -n "Type 'RESIZE' to auto-resize $part: "
    read -r RESIZE_CONFIRM
    [ "$RESIZE_CONFIRM" = "RESIZE" ] || { error "Resize required but not confirmed."; exit 1; }

    if fastboot resize-logical-partition "$part" "$target_size"; then
        success "Resized $part to $target_size bytes"
        return 0
    fi

    warn "resize-logical-partition failed; trying delete/create fallback."
    fastboot delete-logical-partition "$part"
    fastboot create-logical-partition "$part" "$target_size"
    success "Recreated $part with $target_size bytes"
}

echo ""
info "Waiting for fastboot device..."
FB_DEVICE=$(wait_for_fastboot_device || true)

if [ -z "$FB_DEVICE" ]; then
    error "No fastboot device detected after 60s."
    exit 1
fi
success "Device detected: $FB_DEVICE"

UNLOCKED=$(getvar_value unlocked || true)
case "$UNLOCKED" in
    yes) success "Bootloader unlocked" ;;
    no)  error "Bootloader locked. Run: fastboot flashing unlock"; exit 1 ;;
    *)   warn "Bootloader lock state unknown or timed out - continuing" ;;
esac

ensure_system_partition_capacity

echo ""
echo -e "${BOLD}${RED}This will overwrite:${NC}"
[ "$FLASH_SYSTEM" = true ] && echo "  - system"
[ "$FLASH_VBMETA" = true ] && echo "  - vbmeta"
[ "$FLASH_USERDATA" = true ] && echo "  - userdata"
echo "  boot/vendor_boot/dtbo/vendor are untouched"
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

if [ "$FLASH_USERDATA" = true ]; then
    info "Flashing userdata"
    fastboot flash userdata "$USERDATA_IMG"
fi

echo -n "Reboot now? [Y/n]: "
read -r REBOOT
if [[ "$REBOOT" != "n" && "$REBOOT" != "N" ]]; then
    fastboot reboot
fi

success "Flash complete"
echo "To disable Ubuntu launcher: adb shell setprop persist.ubuntu_gsi.enable 0 && adb reboot"
