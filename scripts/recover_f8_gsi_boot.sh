#!/bin/bash
# =============================================================================
# scripts/recover_f8_gsi_boot.sh — Recover F8 from GSI bootloop (fastboot only)
# =============================================================================
# F8 rules (runtime verified):
#   - vbmeta* MUST be flashed in bootloader fastboot (is-userspace=no)
#   - system_a / userdata / metadata MUST use fastbootd (is-userspace=yes)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Prefer shared HIDL debug session log when present

VBMETA_IMG="$REPO_ROOT/builder/out/vbmeta-disabled.img"
ROM_DIR="${ROM_DIR:-/home/zero/F8_V2.0_20260313/F8_V2.0_20260313}"
# empty = unsigned flags=3 (correct for GSI on unlocked F8)
# hybrid = stock-signed + flags patched in-place (INVALID signature — often bootloops)
# stock  = OEM hashtree kept (not for GSI)
VBMETA_MODE="${VBMETA_MODE:-empty}"
CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
SYSTEM_IMG="${SYSTEM_IMG:-$REPO_ROOT/builder/out/${RELEASE_SYSTEM_IMG:-system.img}}"
if [ ! -f "$SYSTEM_IMG" ] && [ -f "$REPO_ROOT/builder/out/system.img" ]; then
    SYSTEM_IMG="$REPO_ROOT/builder/out/system.img"
fi
SKIP_SYSTEM="${SKIP_SYSTEM:-0}"
SKIP_VBMETA="${SKIP_VBMETA:-0}"
WIPE_USERDATA="${WIPE_USERDATA:-1}"
FORMAT_METADATA="${FORMAT_METADATA:-1}"
SET_ACTIVE_SLOT="${SET_ACTIVE_SLOT:-a}"
# H93 CONFIRMED: empty product/system_ext placeholders bootloop stock on F8.
# Default OFF — only enable for explicit overlays-only experiments.
REPLACE_OEM_OVERLAYS="${REPLACE_OEM_OVERLAYS:-${DELETE_OEM_OVERLAYS:-0}}"
EMPTY_PRODUCT_IMG="$REPO_ROOT/builder/out/empty-product.img"
EMPTY_SYSTEM_EXT_IMG="$REPO_ROOT/builder/out/empty-system_ext.img"
EMPTY_OVERLAY_BYTES="${EMPTY_OVERLAY_BYTES:-33554432}"


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
# shellcheck disable=SC2034
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[recover]${NC} $1"; }
ok()    { echo -e "${GREEN}[recover]${NC} $1"; }
warn()  { echo -e "${YELLOW}[recover]${NC} $1"; }
fail()  { echo -e "${RED}[recover]${NC} $1"; exit 1; }

is_fastbootd() {
    [ "$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/is-userspace/{print $2; exit}')" = "yes" ]
}

ensure_bootloader() {
    if is_fastbootd; then
        warn "fastbootd → bootloader (vbmeta requires is-userspace=no)..."
        fastboot reboot bootloader
        sleep 12
    fi
    fastboot devices 2>/dev/null | grep -q . || fail "No bootloader device"
    if is_fastbootd; then
        fail "Still in fastbootd. Hold Vol+ at boot to enter bootloader."
    fi
    ok "Bootloader fastboot"
}

ensure_fastbootd() {
    if ! is_fastbootd; then
        info "bootloader → fastbootd (system/userdata/metadata)..."
        fastboot reboot fastboot
        sleep 15
    fi
    fastboot devices 2>/dev/null | grep -q . || fail "No fastbootd device"
    is_fastbootd || fail "Not in fastbootd after reboot fastboot"
    ok "fastbootd"
}

format_metadata_fastbootd() {
    # vendor_boot fstab: metadata must be f2fs (H70)
    info "Formatting metadata as f2fs (fstab requires f2fs)..."
    if fastboot format:f2fs metadata 2>/dev/null; then
        ok "metadata formatted (f2fs)"
        return 0
    fi
    warn "format:f2fs metadata failed — trying ext4 fallback (may still fail first_stage)"
    if fastboot format:ext4 metadata 2>/dev/null; then
        ok "metadata formatted (ext4 fallback)"
        return 0
    fi
    return 1
}

part_size_hex() {
    fastboot getvar "partition-size:$1" 2>&1 | awk -F': ' -v p="$1" \
        '$0 ~ ("partition-size:" p ":") {print $2; exit}'
}

ensure_empty_img() {
    local out="$1" label="$2"
    if [ -f "$out" ] && [ "$(stat -c '%s' "$out")" -ge 1048576 ]; then
        return 0
    fi
    truncate -s "$EMPTY_OVERLAY_BYTES" "$out"
    mkfs.ext4 -F -L "$label" -O ^metadata_csum "$out" >/dev/null
}

recreate_empty_logical() {
    local part="$1" img="$2"
    local cow="${part}-cow"
    fastboot delete-logical-partition "$cow" 2>/dev/null || true
    fastboot delete-logical-partition "$part" 2>/dev/null || true
    fastboot create-logical-partition "$part" "$EMPTY_OVERLAY_BYTES" || return 1
    fastboot flash "$part" "$img" || return 1
    ok "recreated empty $part ($(part_size_hex "$part"))"
}

replace_oem_overlays_fastbootd() {
    ensure_empty_img "$EMPTY_PRODUCT_IMG" product
    ensure_empty_img "$EMPTY_SYSTEM_EXT_IMG" system_ext

    local before_product before_sext before_sdlkm
    # shellcheck disable=SC2034
    before_product=$(part_size_hex product_a)
    # shellcheck disable=SC2034
    before_sext=$(part_size_hex system_ext_a)
    before_sdlkm=$(part_size_hex system_dlkm_a)

    if [ -z "${before_sdlkm:-}" ] || [ "${before_sdlkm}" = "0x0" ] || [ "${before_sdlkm}" = "0" ]; then
        fail "system_dlkm_a missing — fstab requires it. Run: bash scripts/restore_stock_f8.sh first"
    fi

    info "Replacing OEM product/system_ext with empty ext4 (keep system_dlkm)..."
    recreate_empty_logical product_a "$EMPTY_PRODUCT_IMG"
    recreate_empty_logical system_ext_a "$EMPTY_SYSTEM_EXT_IMG"
    # Slot B placeholders (best-effort)
    recreate_empty_logical product_b "$EMPTY_PRODUCT_IMG" 2>/dev/null || warn "product_b recreate skipped"
    recreate_empty_logical system_ext_b "$EMPTY_SYSTEM_EXT_IMG" 2>/dev/null || warn "system_ext_b recreate skipped"

}

command -v fastboot >/dev/null 2>&1 || fail "fastboot not found"
fastboot devices 2>/dev/null | grep -q . || fail "No fastboot device"

if [ "$(id -u)" -eq 0 ]; then
    fail "Do not run recover/isolate as root (sudo). make_f2fs/fastboot break under sudo. Use: MODE=... bash scripts/isolate_gsi_bootloop.sh"
fi

bash "$REPO_ROOT/scripts/capture_fastboot_diag.sh" "$REPO_ROOT/builder/logs/recover_$(date +%Y%m%d_%H%M%S)"

if [ "$SKIP_VBMETA" != "1" ]; then
    ensure_bootloader
    bash "$REPO_ROOT/scripts/build_vbmeta_disabled.sh" >/dev/null
    bash "$REPO_ROOT/scripts/build_vbmeta_stock_patched.sh" "$ROM_DIR" >/dev/null
    TOP_VBMETA="$REPO_ROOT/builder/out/vbmeta-stock-patched.img"
    EMPTY_VBMETA="$VBMETA_IMG"
    STOCK_SYS="$ROM_DIR/vbmeta_system.img"
    STOCK_VND="$ROM_DIR/vbmeta_vendor.img"

    case "$VBMETA_MODE" in
        empty)
            info "Empty unsigned vbmeta flags=3 on vbmeta/system/vendor (slot A)..."
            fastboot flash vbmeta_a "$EMPTY_VBMETA"
            fastboot flash vbmeta_system_a "$EMPTY_VBMETA"
            fastboot flash vbmeta_vendor_a "$EMPTY_VBMETA"
            ;;
        empty-keep-vendor)
            # H91: keep stock vbmeta_vendor (vendor avb chain); disable only top+system
            info "Empty vbmeta/system flags=3; KEEP stock vbmeta_vendor (slot A)..."
            fastboot flash vbmeta_a "$EMPTY_VBMETA"
            fastboot flash vbmeta_system_a "$EMPTY_VBMETA"
            [ -f "$STOCK_VND" ] || fail "Missing $STOCK_VND"
            fastboot flash vbmeta_vendor_a "$STOCK_VND"
            ;;
        hybrid)
            warn "hybrid uses stock-signed vbmeta with flags patched in-place (signature INVALID)"
            warn "Prefer VBMETA_MODE=empty on unlocked F8"
            info "Hybrid vbmeta on slot A (bootloader)..."
            fastboot flash vbmeta_a "$TOP_VBMETA"
            fastboot flash vbmeta_system_a "$EMPTY_VBMETA"
            [ -f "$STOCK_VND" ] && fastboot flash vbmeta_vendor_a "$STOCK_VND"
            ;;
        stock)
            warn "stock vbmeta_system has OEM system hashtree — not for GSI"
            fastboot flash vbmeta_a "$TOP_VBMETA"
            [ -f "$STOCK_SYS" ] && fastboot flash vbmeta_system_a "$STOCK_SYS"
            [ -f "$STOCK_VND" ] && fastboot flash vbmeta_vendor_a "$STOCK_VND"
            ;;
        *) fail "Unknown VBMETA_MODE=$VBMETA_MODE (use empty|empty-keep-vendor|hybrid|stock)" ;;
    esac
    ok "vbmeta slot A flashed ($VBMETA_MODE)"
fi

ensure_fastbootd

if [ "$REPLACE_OEM_OVERLAYS" = "1" ]; then
    replace_oem_overlays_fastbootd
fi

if [ "$WIPE_USERDATA" = "1" ]; then
    info "Formatting userdata as f2fs..."
    if ! fastboot format:f2fs userdata; then
        warn "format:f2fs failed — erase + retry"
        fastboot erase userdata || true
        if ! fastboot format:f2fs userdata; then
            warn "userdata format still failed after erase — continuing (first boot may reformat)"
        else
            ok "userdata formatted"
        fi
    else
        ok "userdata formatted"
    fi
fi

if [ "$FORMAT_METADATA" = "1" ]; then
    format_metadata_fastbootd || warn "metadata format failed — try: fastboot reboot fastboot && fastboot format:ext4 metadata"
fi

if [ "$SKIP_SYSTEM" != "1" ] && [ -f "$SYSTEM_IMG" ]; then
    bash "$REPO_ROOT/scripts/verify_system_img.sh" "$SYSTEM_IMG"
    info "Flashing system_a..."
    fastboot flash system_a "$SYSTEM_IMG"
    ok "system_a flashed"
fi

if [ -n "$SET_ACTIVE_SLOT" ]; then
    fastboot set_active "$SET_ACTIVE_SLOT"
fi

echo ""
read -r -p "Reboot now? [Y/n]: " ans
[ "${ans:-Y}" = "n" ] || [ "${ans:-Y}" = "N" ] || fastboot reboot


ok "Done. If still bootloop on slot B, run: bash scripts/restore_stock_f8.sh"
