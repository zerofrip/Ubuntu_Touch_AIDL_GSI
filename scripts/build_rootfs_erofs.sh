#!/bin/bash
# =============================================================================
# scripts/build_rootfs_erofs.sh — Pack the Ubuntu chroot rootfs as erofs
# =============================================================================
# Replaces the previous SquashFS step. EROFS is mandatory because:
#   • Many vendor kernels ship `CONFIG_EROFS_FS=y` but lack squashfs.
#     (Confirmed on Nothing Phone (1) `lahaina`/Android 15 stock kernel.)
#   • EROFS supports compression that's competitive with squashfs-xz.
#   • The Android `vendor` partition is already EROFS, so we know the kernel
#     module path is loaded.
#
# Output: builder/out/linux_rootfs.erofs
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

ROOTFS_DIR="${ROOTFS_DIR:-$REPO_ROOT/builder/out/ubuntu-rootfs}"
OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="${EROFS_OUT:-$OUT_DIR/linux_rootfs.erofs}"
EROFS_COMP="${EROFS_COMP:-lz4hc,9}"

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[erofs]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[erofs]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[erofs]${NC} $1"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if ! command -v mkfs.erofs >/dev/null 2>&1; then
    error "mkfs.erofs not found."
    error "  Install: sudo apt install erofs-utils"
    exit 1
fi

if [ ! -d "$ROOTFS_DIR" ] || [ -z "$(ls -A "$ROOTFS_DIR" 2>/dev/null)" ]; then
    error "Rootfs directory missing/empty: $ROOTFS_DIR"
    error "  Run scripts/build_rootfs.sh first."
    exit 1
fi

# 0700 dirs (ssl/private, polkit, /root) are unreadable as a normal user.
# mkfs.erofs then fails with permission denied (Error 13).
if [ "$(id -u)" -ne 0 ]; then
    info "Rootfs has root-only directories — re-running via sudo"
    exec sudo -E bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Pack
# ---------------------------------------------------------------------------
if [ -e "$OUT_IMG" ] && [ ! -w "$OUT_IMG" ]; then
    error "Cannot overwrite $OUT_IMG (owned by $(stat -c '%U:%G' "$OUT_IMG" 2>/dev/null || echo unknown))"
    error "  Fix: sudo chown \"\$USER:\$USER\" \"$OUT_IMG\""
    error "   or: sudo rm -f \"$OUT_IMG\""
    exit 1
fi
rm -f "$OUT_IMG"
ROOTFS_BYTES=$(du -sb "$ROOTFS_DIR" 2>/dev/null | cut -f1 || true)
ROOTFS_BYTES="${ROOTFS_BYTES:-1}"
ROOTFS_MB=$(( ROOTFS_BYTES / 1024 / 1024 ))

info "Packing rootfs ($ROOTFS_MB MB → $OUT_IMG)"
info "  compression : $EROFS_COMP"

mkfs.erofs -z "$EROFS_COMP" -d 2 -T 1740000000 "$OUT_IMG" "$ROOTFS_DIR"

if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_USER}:${SUDO_USER}" "$OUT_IMG" 2>/dev/null || true
fi

OUT_BYTES=$(du -sb "$OUT_IMG" | cut -f1)
OUT_MB=$(( OUT_BYTES / 1024 / 1024 ))
RATIO=$(( OUT_BYTES * 100 / ROOTFS_BYTES ))

success "linux_rootfs.erofs built: $OUT_IMG ($OUT_MB MB, $RATIO% of source)"

