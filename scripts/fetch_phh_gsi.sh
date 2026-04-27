#!/bin/bash
# =============================================================================
# scripts/fetch_phh_gsi.sh — Download/locate the PHH Treble GSI base
# =============================================================================
# The Halium-style architecture requires a working Android Treble GSI as the
# base of /system. We use phhusson's "Generic System Image" because:
#   • It boots on virtually every Treble device with a single fastboot flash.
#   • Sources are public on GitHub.
#   • Build IDs are well-tracked and reproducible.
#
# This script either:
#   1. Reuses an existing image at "$BUILD_DIR/cache/phh-gsi.img"
#   2. Or downloads "$PHH_GSI_URL" (defined in config.env) into that path.
#
# It then publishes the image at "$BUILD_DIR/cache/phh-gsi.img" so that
# scripts/build_system_img.sh can pick it up.
#
# Usage:
#   bash scripts/fetch_phh_gsi.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# HIDL variant defaults to Android 11 GSI (PHH v412 era).
# AIDL variant is expected to override these in config.env to Android 14+.
PHH_GSI_VERSION="${PHH_GSI_VERSION:-v412.r}"
PHH_GSI_VARIANT="${PHH_GSI_VARIANT:-arm64-aonly-vanilla}"
PHH_GSI_URL="${PHH_GSI_URL:-https://github.com/phhusson/treble_experimentations/releases/download/${PHH_GSI_VERSION}/system-${PHH_GSI_VARIANT}.img.xz}"

CACHE_DIR="$REPO_ROOT/builder/cache"
PHH_IMG="$CACHE_DIR/phh-gsi.img"
PHH_DOWNLOAD="$CACHE_DIR/phh-gsi.img.xz"

mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }

# ---------------------------------------------------------------------------
# Cached image short-circuit
# ---------------------------------------------------------------------------
if [ -f "$PHH_IMG" ]; then
    SIZE=$(du -h "$PHH_IMG" | cut -f1)
    success "Cached PHH GSI present: $PHH_IMG ($SIZE) — skipping download"
    exit 0
fi

# ---------------------------------------------------------------------------
# Manual override
# ---------------------------------------------------------------------------
if [ -n "${PHH_GSI_LOCAL:-}" ] && [ -f "$PHH_GSI_LOCAL" ]; then
    info "Using locally provided PHH GSI: $PHH_GSI_LOCAL"
    cp -f "$PHH_GSI_LOCAL" "$PHH_IMG"
    success "Cached at $PHH_IMG"
    exit 0
fi

# ---------------------------------------------------------------------------
# Download path
# ---------------------------------------------------------------------------
info "Downloading PHH GSI:"
info "  version  : $PHH_GSI_VERSION"
info "  variant  : $PHH_GSI_VARIANT"
info "  url      : $PHH_GSI_URL"
info "  target   : $PHH_DOWNLOAD"

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    error "Neither wget nor curl is installed."
    error "  Install one: sudo apt install wget"
    exit 1
fi

if command -v wget >/dev/null 2>&1; then
    wget -O "$PHH_DOWNLOAD" "$PHH_GSI_URL"
else
    curl -L -o "$PHH_DOWNLOAD" "$PHH_GSI_URL"
fi

if [ ! -s "$PHH_DOWNLOAD" ]; then
    error "Download failed or produced an empty file."
    rm -f "$PHH_DOWNLOAD"
    exit 1
fi

# Decompress if needed
if [[ "$PHH_GSI_URL" == *.xz ]]; then
    info "Decompressing xz archive ..."
    xz --decompress --keep --force --stdout "$PHH_DOWNLOAD" > "$PHH_IMG"
    rm -f "$PHH_DOWNLOAD"
elif [[ "$PHH_GSI_URL" == *.zip ]]; then
    info "Extracting zip archive ..."
    unzip -p "$PHH_DOWNLOAD" '*system*.img' > "$PHH_IMG" || \
        { error "Unable to extract system.img from zip"; exit 1; }
    rm -f "$PHH_DOWNLOAD"
else
    mv "$PHH_DOWNLOAD" "$PHH_IMG"
fi

# Sanity check: is this an Android sparse / ext4 image?
HEAD=$(head -c 4 "$PHH_IMG" | od -An -c | tr -d ' \n')
case "$HEAD" in
    "\x3a\xff\x26\xed"|*"\x3a\xff"*)
        info "Sparse image detected — converting to raw with simg2img"
        if ! command -v simg2img >/dev/null 2>&1; then
            error "simg2img not installed. Install android-sdk-libsparse-utils."
            exit 1
        fi
        simg2img "$PHH_IMG" "$PHH_IMG.raw"
        mv "$PHH_IMG.raw" "$PHH_IMG"
        ;;
esac

SIZE=$(du -h "$PHH_IMG" | cut -f1)
success "PHH GSI ready: $PHH_IMG ($SIZE)"
