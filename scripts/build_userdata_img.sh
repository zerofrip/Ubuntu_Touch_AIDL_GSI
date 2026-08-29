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
USERDATA_FS="${USERDATA_FS:-f2fs}"
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

# User-added packages seed (from packages.userdata.list)
USER_PKG_LIST="$REPO_ROOT/rootfs/packages.userdata.list"
USER_PKG_ROOT="$STAGING_DIR/ubuntu-gsi/user-packages"
mkdir -p "$USER_PKG_ROOT/clicks" "$USER_PKG_ROOT/debs"
cat > "$USER_PKG_ROOT/README" <<'EOF'
User-added packages for Ubuntu Touch GSI.
Place .click files in clicks/ and optional .deb files in debs/.
Edit rootfs/packages.userdata.list and re-run build_userdata_img.sh,
or use scripts/provision_userdata_packages.sh after flash (--system-only safe).
EOF
if [ -f "$USER_PKG_LIST" ]; then
    cp "$USER_PKG_LIST" "$USER_PKG_ROOT/packages.userdata.list"
    CLICK_CACHE="${GSI_CLICK_CACHE:-$REPO_ROOT/builder/cache/openstore-clicks}"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")"
        [ -z "$line" ] && continue
        case "$line" in
            click:*)
                id="${line#click:}"
                src="$CLICK_CACHE/${id}_arm64.click"
                if [ -f "$src" ]; then
                    cp -a "$src" "$USER_PKG_ROOT/clicks/"
                    info "Staged user click: $id"
                else
                    info "WARN: click $id not in cache (run fetch_openstore_clicks.sh / provision)"
                fi
                ;;
            deb:*)
                pkg="${line#deb:}"
                info "Note: deb:$pkg — use provision_userdata_packages.sh to download+push"
                ;;
        esac
    done < "$USER_PKG_LIST"
fi

success "Staged: rootfs.erofs + backup + hash + uhl_overlay + user-packages"

# ---------------------------------------------------------------------------
# Build the userdata image (F8 and most modern devices use f2fs, not ext4)
# ---------------------------------------------------------------------------
rm -f "$USERDATA_IMG"

if [ "$USERDATA_FS" = "f2fs" ]; then
    if ! command -v mkfs.f2fs >/dev/null 2>&1; then
        error "mkfs.f2fs not found — install: sudo apt install f2fs-tools"
        exit 1
    fi
    if ! command -v sload.f2fs >/dev/null 2>&1; then
        error "sload.f2fs not found — install: sudo apt install f2fs-tools"
        exit 1
    fi
    info "Creating f2fs userdata image (${USERDATA_SIZE_MB}MB) via sload.f2fs (no root)..."
    truncate -s "${USERDATA_SIZE_MB}M" "$USERDATA_IMG"
    mkfs.f2fs -f -l userdata -a 0 "$USERDATA_IMG" >/dev/null
    sload.f2fs -f "$STAGING_DIR" -t / "$USERDATA_IMG" >/dev/null
    info "NOTE: Do not flash this small image over a multi-100GB userdata partition."
    info "      Prefer ROOTFS_SEED_IN_SYSTEM=1, or: fastboot format:f2fs userdata + adb provision."
else
    info "Creating ext4 userdata image (${USERDATA_SIZE_MB}MB)..."
    dd if=/dev/zero of="$USERDATA_IMG" bs=1M count="$USERDATA_SIZE_MB" status=progress 2>&1
    mkfs.ext4 -L userdata -O ^metadata_csum "$USERDATA_IMG" -d "$STAGING_DIR"
fi

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


