#!/bin/bash
# =============================================================================
# scripts/build_userdata_img.sh — Userdata Image Builder (ERoFS seed)
# =============================================================================
# Creates a flashable userdata.img (ext4) containing:
#   - /data/ubuntu-gsi/rootfs.erofs
#   - /data/ubuntu-gsi/rootfs.erofs.bak
#   - /data/ubuntu-gsi/rootfs.erofs.sha256
#   - /data/uhl_overlay/{upper,work}
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
ROOTFS_EROFS="$BUILD_DIR/linux_rootfs.erofs"
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
if [ ! -f "$ROOTFS_EROFS" ]; then
    error "FATAL: linux_rootfs.erofs not found at: $ROOTFS_EROFS"
    error "Run the build first: ./build.sh"
    exit 1
fi

ROOTFS_SIZE_MB=$(du -m "$ROOTFS_EROFS" | cut -f1)

# Auto-compute minimal size when USERDATA_SIZE_MB=0
if [ "${USERDATA_SIZE_MB}" -eq 0 ]; then
    USERDATA_SIZE_MB=$(( ROOTFS_SIZE_MB * 2 + 96 ))
    info "Auto userdata size: ${USERDATA_SIZE_MB}MB (rootfs ${ROOTFS_SIZE_MB}MB x2 + 96MB headroom)"
fi

if [ "$USERDATA_SIZE_MB" -le "$((ROOTFS_SIZE_MB * 2))" ]; then
    error "FATAL: Userdata image size (${USERDATA_SIZE_MB}MB) must be larger than rootfs x2 (${ROOTFS_SIZE_MB}MB * 2)"
    error "Increase USERDATA_IMG_SIZE_MB in config.env"
    exit 1
fi

info "Building userdata.img (${USERDATA_SIZE_MB}MB) with rootfs.erofs (${ROOTFS_SIZE_MB}MB)"

# ---------------------------------------------------------------------------
# Stage the userdata contents
# ---------------------------------------------------------------------------
info "Staging userdata contents..."

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Place runtime rootfs + backup under /data/ubuntu-gsi
mkdir -p "$STAGING_DIR/ubuntu-gsi"
cp "$ROOTFS_EROFS" "$STAGING_DIR/ubuntu-gsi/rootfs.erofs"
cp "$ROOTFS_EROFS" "$STAGING_DIR/ubuntu-gsi/rootfs.erofs.bak"
if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$STAGING_DIR/ubuntu-gsi"
        sha256sum rootfs.erofs > rootfs.erofs.sha256
    )
fi

# Pre-create overlay directory structure
mkdir -p "$STAGING_DIR/uhl_overlay/upper"
mkdir -p "$STAGING_DIR/uhl_overlay/work"

success "Staged: rootfs.erofs + backup + hash + uhl_overlay directories"

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
