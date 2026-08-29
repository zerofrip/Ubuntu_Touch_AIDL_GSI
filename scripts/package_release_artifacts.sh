#!/bin/bash
# =============================================================================
# scripts/package_release_artifacts.sh — Name release artifacts for vendor branch
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

OUT_DIR="$REPO_ROOT/builder/out"
SYSTEM_IMG="$OUT_DIR/system.img"
RELEASE_SYSTEM_IMG="${RELEASE_SYSTEM_IMG:-${VENDOR_ANDROID_VERSION}_system.img}"
RELEASE_SYSTEM_PATH="$OUT_DIR/$RELEASE_SYSTEM_IMG"
USERDATA_IMG="$OUT_DIR/userdata.img"
VBMETA_IMG="$OUT_DIR/vbmeta-disabled.img"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[Release]${NC}  $1"; }
success() { echo -e "${GREEN}[Release]${NC}  $1"; }
error()   { echo -e "${RED}[Release]${NC}  $1"; }

if [ ! -f "$SYSTEM_IMG" ]; then
    error "system.img not found: $SYSTEM_IMG"
    exit 1
fi
if [ ! -f "$USERDATA_IMG" ]; then
    error "userdata.img not found: $USERDATA_IMG"
    exit 1
fi
if [ ! -f "$VBMETA_IMG" ]; then
    error "vbmeta-disabled.img not found: $VBMETA_IMG"
    exit 1
fi

info "Packaging release artifacts for ${VENDOR_ANDROID_VERSION:-unknown}"

cp -f "$SYSTEM_IMG" "$RELEASE_SYSTEM_PATH"
ln -sfn "$RELEASE_SYSTEM_IMG" "$OUT_DIR/system.img"

success "System image: $RELEASE_SYSTEM_PATH ($(du -h "$RELEASE_SYSTEM_PATH" | cut -f1))"
success "Userdata image: $USERDATA_IMG ($(du -h "$USERDATA_IMG" | cut -f1))"
success "Vbmeta image: $VBMETA_IMG ($(du -h "$VBMETA_IMG" | cut -f1))"

bash "$REPO_ROOT/scripts/verify_system_img.sh" "$RELEASE_SYSTEM_PATH"

