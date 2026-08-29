#!/bin/bash
# =============================================================================
# scripts/restore_stock_f8.sh — Full stock ROM restore via fastboot (F8)
# =============================================================================
# Use when BOTH slots bootloop (shared userdata/metadata/vbmeta damage).
# Flashes stock super + stock vbmeta chain on slots A/B, reformats userdata/metadata.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ROM_DIR="${1:-/home/zero/F8_V2.0_20260313/F8_V2.0_20260313}"
SUPER_IMG="$ROM_DIR/super.img"
ACTIVE_SLOT="${ACTIVE_SLOT:-a}"


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[stock]${NC} $1"; }
ok()    { echo -e "${GREEN}[stock]${NC} $1"; }
warn()  { echo -e "${YELLOW}[stock]${NC} $1"; }
fail()  { echo -e "${RED}[stock]${NC} $1"; exit 1; }

is_fastbootd() {
    [ "$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/is-userspace/{print $2; exit}')" = "yes" ]
}

ensure_bootloader() {
    if is_fastbootd; then
        warn "Switching fastbootd → bootloader (required for vbmeta/super)..."
        fastboot reboot bootloader
        sleep 12
    fi
    fastboot devices 2>/dev/null | grep -q . || fail "No device in bootloader fastboot"
    is_fastbootd && fail "Still in fastbootd — hold Vol+ and reboot to bootloader manually"
    ok "Bootloader fastboot (is-userspace=no)"
}

ensure_fastbootd() {
    if ! is_fastbootd; then
        info "Switching bootloader → fastbootd (for format/metadata)..."
        fastboot reboot fastboot
        sleep 15
    fi
    fastboot devices 2>/dev/null | grep -q . || fail "No device in fastbootd"
    is_fastbootd || fail "Not in fastbootd"
    ok "fastbootd (is-userspace=yes)"
}

command -v fastboot >/dev/null 2>&1 || fail "fastboot not found"
fastboot devices 2>/dev/null | grep -q . || fail "Connect device in fastboot"

[ -f "$SUPER_IMG" ] || fail "Missing $SUPER_IMG"
for f in vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
    [ -f "$ROM_DIR/$f" ] || fail "Missing $ROM_DIR/$f"
done

echo -e "${BOLD}${RED}WARNING:${NC} This overwrites super + vbmeta on BOTH slots and wipes userdata/metadata."
echo -n "Type RESTORE to continue: "
read -r confirm
[ "$confirm" = "RESTORE" ] || { info "Cancelled."; exit 0; }


ensure_bootloader

info "Flashing stock vbmeta chain (slots A + B)..."
for slot in a b; do
    fastboot flash "vbmeta_${slot}" "$ROM_DIR/vbmeta.img"
    fastboot flash "vbmeta_system_${slot}" "$ROM_DIR/vbmeta_system.img"
    fastboot flash "vbmeta_vendor_${slot}" "$ROM_DIR/vbmeta_vendor.img"
done
ok "Stock vbmeta flashed (a+b)"

info "Flashing stock super.img (~4.4GB, several minutes)..."
fastboot flash super "$SUPER_IMG"
ok "super.img flashed"

ensure_fastbootd

info "Formatting userdata (f2fs)..."
fastboot format:f2fs userdata || { fastboot erase userdata; fastboot format:f2fs userdata; }
ok "userdata formatted"

info "Formatting metadata as f2fs (vendor_boot fstab)..."
if fastboot format:f2fs metadata 2>/dev/null; then
    ok "metadata formatted (f2fs)"
elif fastboot format:ext4 metadata 2>/dev/null; then
    warn "f2fs failed; metadata formatted as ext4 fallback"
else
    warn "metadata format failed — boot may still loop until fixed manually"
fi

info "Setting active slot: $ACTIVE_SLOT"
fastboot set_active "$ACTIVE_SLOT"


ok "Stock restore complete. Rebooting..."
fastboot reboot
