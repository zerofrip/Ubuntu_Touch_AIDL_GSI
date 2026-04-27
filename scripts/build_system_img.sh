#!/bin/bash
# =============================================================================
# scripts/build_system_img.sh — Halium-style system.img builder
# =============================================================================
# Replaces the legacy `gsi-pack.sh`. Produces a flashable `system.img` by:
#   1. Loop-mounting the cached PHH Treble GSI as a read-only base.
#   2. Copying the contents into a writeable staging directory.
#   3. Overlaying our additions:
#        - /system/etc/init/ubuntu-gsi.rc           (init service)
#        - /system/bin/ubuntu-gsi-launcher          (chroot driver)
#        - /system/bin/ubuntu-gsi-stop-android-ui   (SF stopper)
#        - /system/usr/lib/ubuntu-gsi/compat/       (PHH/Treble-style quirks)
#        - /system/usr/share/ubuntu-gsi/rootfs.erofs (the Ubuntu chroot)
#        - /system/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh
#   4. Re-packing the staging directory as ext4 with the `system` label.
#
# Output: builder/out/system.img
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

CACHE_DIR="$REPO_ROOT/builder/cache"
PHH_IMG="$CACHE_DIR/phh-gsi.img"
EROFS_IMG="$REPO_ROOT/builder/out/linux_rootfs.erofs"
HALIUM_DIR="$REPO_ROOT/halium"

OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="$OUT_DIR/system.img"
STAGING="$OUT_DIR/system_staging"
PHH_MNT="$OUT_DIR/.phh-mount"

SYSTEM_IMG_SIZE_MB="${SYSTEM_IMG_SIZE_MB:-0}"

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }

cleanup() {
    if mountpoint -q "$PHH_MNT" 2>/dev/null; then
        umount "$PHH_MNT" || true
    fi
    rmdir "$PHH_MNT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (loop-mount + chown + mkfs require it)."
    error "  sudo bash $0"
    exit 1
fi

if [ ! -f "$PHH_IMG" ]; then
    error "PHH GSI base not found at $PHH_IMG"
    error "  Run: bash scripts/fetch_phh_gsi.sh"
    exit 1
fi

if [ ! -f "$EROFS_IMG" ]; then
    error "Ubuntu rootfs erofs not found at $EROFS_IMG"
    error "  Run: bash scripts/build_rootfs_erofs.sh"
    exit 1
fi

for cmd in mkfs.ext4 e2fsck mount tune2fs; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "$cmd not found — install e2fsprogs"
        exit 1
    }
done

# ---------------------------------------------------------------------------
# Stage 1: extract PHH base
# ---------------------------------------------------------------------------
info "Staging PHH GSI base into $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$PHH_MNT"

mount -o ro,loop "$PHH_IMG" "$PHH_MNT"
cp -a "$PHH_MNT/." "$STAGING/"
umount "$PHH_MNT"
rmdir "$PHH_MNT"

# Some PHH GSIs are mounted at /system/ inside the loop; others put files at
# the root. Detect and normalise.
if [ -d "$STAGING/system" ] && [ -f "$STAGING/system/build.prop" ]; then
    info "PHH base uses /system subtree — flattening"
    mv "$STAGING/system" "$STAGING/.flat"
    rm -rf "${STAGING:?}"/* 2>/dev/null || true
    mv "$STAGING/.flat"/* "$STAGING/"
    rmdir "$STAGING/.flat"
fi

success "PHH base extracted ($(du -sh "$STAGING" | cut -f1))"

# ---------------------------------------------------------------------------
# Stage 2: overlay halium additions
# ---------------------------------------------------------------------------
info "Overlaying Halium scaffolding"

# init.rc
mkdir -p "$STAGING/etc/init"
install -m 0644 "$HALIUM_DIR/etc/init/ubuntu-gsi.rc" "$STAGING/etc/init/ubuntu-gsi.rc"

# Launcher binaries
mkdir -p "$STAGING/bin"
install -m 0755 "$HALIUM_DIR/bin/ubuntu-gsi-launcher"        "$STAGING/bin/ubuntu-gsi-launcher"
install -m 0755 "$HALIUM_DIR/bin/ubuntu-gsi-stop-android-ui" "$STAGING/bin/ubuntu-gsi-stop-android-ui"

# Compat layer (mirrored to /system/usr/lib/ubuntu-gsi/compat)
mkdir -p "$STAGING/usr/lib/ubuntu-gsi/compat"
cp -a "$HALIUM_DIR/compat/." "$STAGING/usr/lib/ubuntu-gsi/compat/"
find "$STAGING/usr/lib/ubuntu-gsi/compat" -type f -name '*.sh' -exec chmod 0755 {} \;

# Linux rootfs erofs
mkdir -p "$STAGING/usr/share/ubuntu-gsi"
cp -a "$EROFS_IMG" "$STAGING/usr/share/ubuntu-gsi/rootfs.erofs"

# Lomiri launch helper (also linked from the Linux rootfs)
mkdir -p "$STAGING/usr/share/ubuntu-gsi/halium-lomiri"
install -m 0755 "$HALIUM_DIR/lomiri/start-lomiri.sh" \
    "$STAGING/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh"
install -m 0644 "$HALIUM_DIR/lomiri/README.md" \
    "$STAGING/usr/share/ubuntu-gsi/halium-lomiri/README.md"

success "Halium scaffolding overlaid"

# ---------------------------------------------------------------------------
# Stage 3: pack ext4
# ---------------------------------------------------------------------------
if [ "$SYSTEM_IMG_SIZE_MB" -eq 0 ]; then
    SRC_MB=$(du -sm "$STAGING" | cut -f1)
    SYSTEM_IMG_SIZE_MB=$(( SRC_MB + 256 ))
    [ "$SYSTEM_IMG_SIZE_MB" -lt 2048 ] && SYSTEM_IMG_SIZE_MB=2048
    info "Auto system.img size: ${SYSTEM_IMG_SIZE_MB}MB (content ${SRC_MB}MB + 256MB headroom, min 2048MB)"
fi

rm -f "$OUT_IMG"
info "Allocating ${SYSTEM_IMG_SIZE_MB}MB ext4 at $OUT_IMG"
truncate -s "${SYSTEM_IMG_SIZE_MB}M" "$OUT_IMG"

info "Formatting ext4 with content from $STAGING"
mkfs.ext4 -L system -O ^metadata_csum -d "$STAGING" "$OUT_IMG"

# Optional: convert to sparse for smaller flash. We leave raw — `fastboot`
# accepts both formats on modern bootloaders.

# Cleanup staging
rm -rf "$STAGING"

OUT_HUMAN=$(du -h "$OUT_IMG" | cut -f1)
success "system.img ready: $OUT_IMG ($OUT_HUMAN)"
echo ""
echo -e "  ${BOLD}Flash with:${NC}"
echo -e "    fastboot flash system $OUT_IMG"
echo -e "    fastboot --disable-verity --disable-verification flash vbmeta builder/out/vbmeta-disabled.img"
echo -e "    fastboot reboot"
