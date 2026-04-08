#!/bin/bash
# =============================================================================
# scripts/build_userdata_img.sh — Userdata Image Builder
# =============================================================================
# Creates a flashable userdata.img (ext4) containing the linux_rootfs.squashfs
# and pre-initialized overlay directories.
#
# This replaces the broken "adb push" workflow:
#   BEFORE:  fastboot flash system → adb push squashfs (BROKEN: no adbd)
#   AFTER:   fastboot flash system → fastboot flash userdata (works always)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/builder/out"

# Source configuration
CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=../config.env
    source "$CONFIG_FILE"
fi

USERDATA_SIZE_MB="${USERDATA_IMG_SIZE_MB:-0}"
SQUASHFS_FILE="$BUILD_DIR/linux_rootfs.squashfs"
USERDATA_IMG="$BUILD_DIR/userdata.img"
STAGING_DIR="$BUILD_DIR/userdata_staging"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[Userdata Builder]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[Userdata Builder]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[Userdata Builder]${NC} $1"; }

# ---------------------------------------------------------------------------
# Validate input
# ---------------------------------------------------------------------------
if [ ! -f "$SQUASHFS_FILE" ]; then
    error "FATAL: linux_rootfs.squashfs not found at: $SQUASHFS_FILE"
    error "Run the build first: ./build.sh"
    exit 1
fi

SQUASHFS_SIZE_MB=$(du -m "$SQUASHFS_FILE" | cut -f1)

# Auto-compute minimal size when USERDATA_SIZE_MB=0
if [ "${USERDATA_SIZE_MB}" -eq 0 ]; then
    USERDATA_SIZE_MB=$(( SQUASHFS_SIZE_MB + 64 ))
    info "Auto userdata size: ${USERDATA_SIZE_MB}MB (squashfs ${SQUASHFS_SIZE_MB}MB + 64MB headroom)"
fi

if [ "$USERDATA_SIZE_MB" -le "$SQUASHFS_SIZE_MB" ]; then
    error "FATAL: Userdata image size (${USERDATA_SIZE_MB}MB) must be larger than squashfs (${SQUASHFS_SIZE_MB}MB)"
    error "Increase USERDATA_IMG_SIZE_MB in config.env"
    exit 1
fi

info "Building userdata.img (${USERDATA_SIZE_MB}MB) with squashfs (${SQUASHFS_SIZE_MB}MB)"

# ---------------------------------------------------------------------------
# Stage the userdata contents
# ---------------------------------------------------------------------------
info "Staging userdata contents..."

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Place the squashfs where mount.sh expects it: /data/linux_rootfs.squashfs
# mount.sh line 71: if [ -f "/data/linux_rootfs.squashfs" ]
cp "$SQUASHFS_FILE" "$STAGING_DIR/linux_rootfs.squashfs"

# Pre-create the overlay directory structure that mount.sh needs
# mount.sh lines 18-19: UPPER="/data/uhl_overlay/upper", WORK="/data/uhl_overlay/work"
mkdir -p "$STAGING_DIR/uhl_overlay/upper"
mkdir -p "$STAGING_DIR/uhl_overlay/work"

success "Staged: linux_rootfs.squashfs + uhl_overlay directories"

# ---------------------------------------------------------------------------
# Build the ext4 image
# ---------------------------------------------------------------------------
info "Creating ext4 image (${USERDATA_SIZE_MB}MB)..."

rm -f "$USERDATA_IMG"

# Create zero-filled image
dd if=/dev/zero of="$USERDATA_IMG" bs=1M count="$USERDATA_SIZE_MB" status=progress 2>&1

# Format as ext4 and populate with staging contents
# -L userdata: partition label matching Android convention
# -d: populate from directory
mkfs.ext4 -L userdata -O ^metadata_csum "$USERDATA_IMG" -d "$STAGING_DIR"

# ---------------------------------------------------------------------------
# Cleanup staging
# ---------------------------------------------------------------------------
rm -rf "$STAGING_DIR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
FINAL_SIZE=$(du -h "$USERDATA_IMG" | cut -f1)
success "userdata.img built successfully: $USERDATA_IMG ($FINAL_SIZE)"
echo ""
echo -e "  ${BOLD}Flash with:${NC}"
echo -e "    fastboot flash userdata $USERDATA_IMG"
