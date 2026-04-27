#!/bin/bash
# =============================================================================
# scripts/fetch_phh_gsi.sh — Download/locate the PHH Treble GSI base
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

PHH_GSI_VERSION="${PHH_GSI_VERSION:-v412.r}"
PHH_GSI_VARIANT="${PHH_GSI_VARIANT:-arm64-aonly-vanilla}"
PHH_GSI_URL="${PHH_GSI_URL:-https://github.com/phhusson/treble_experimentations/releases/download/${PHH_GSI_VERSION}/system-${PHH_GSI_VARIANT}.img.xz}"

CACHE_DIR="$REPO_ROOT/builder/cache"
PHH_IMG="$CACHE_DIR/phh-gsi.img"
PHH_DOWNLOAD="$CACHE_DIR/phh-gsi.img.download"

mkdir -p "$CACHE_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[PHH Fetcher]${NC} $1"; }

download_file() {
    local url="$1" out="$2"
    rm -f "$out"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url"
    else
        curl -fL -o "$out" "$url"
    fi
}

create_ci_stub_base() {
    local img="$1"
    local tmp
    tmp=$(mktemp -d)

    info "Creating CI stub PHH base image at $img"
    mkdir -p "$tmp/etc/init" "$tmp/bin" "$tmp/usr/lib" "$tmp/usr/share" "$tmp/system"
    cat > "$tmp/build.prop" <<EOP
ro.build.id=CI-STUB
ro.build.version.release=14
ro.treble.enabled=true
ro.product.cpu.abilist=arm64-v8a
EOP

    truncate -s 512M "$img"
    mkfs.ext4 -L system -O ^metadata_csum -d "$tmp" "$img" >/dev/null
    rm -rf "$tmp"

    success "CI stub PHH base generated: $img"
}

if [ -f "$PHH_IMG" ]; then
    SIZE=$(du -h "$PHH_IMG" | cut -f1)
    success "Cached PHH GSI present: $PHH_IMG ($SIZE) — skipping download"
    exit 0
fi

if [ -n "${PHH_GSI_LOCAL:-}" ] && [ -f "$PHH_GSI_LOCAL" ]; then
    info "Using locally provided PHH GSI: $PHH_GSI_LOCAL"
    cp -f "$PHH_GSI_LOCAL" "$PHH_IMG"
    success "Cached at $PHH_IMG"
    exit 0
fi

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    error "Neither wget nor curl is installed."
    exit 1
fi

info "Downloading PHH GSI:"
info "  version  : $PHH_GSI_VERSION"
info "  variant  : $PHH_GSI_VARIANT"
info "  url      : $PHH_GSI_URL"

if ! download_file "$PHH_GSI_URL" "$PHH_DOWNLOAD"; then
    warn "PHH download failed (URL may be stale or rate-limited)."
    if [ "${CI:-}" = "true" ]; then
        create_ci_stub_base "$PHH_IMG"
        exit 0
    fi
    error "Unable to download PHH GSI. Set PHH_GSI_URL or PHH_GSI_LOCAL in config.env."
    exit 1
fi

if [ ! -s "$PHH_DOWNLOAD" ]; then
    warn "Downloaded file is empty."
    rm -f "$PHH_DOWNLOAD"
    if [ "${CI:-}" = "true" ]; then
        create_ci_stub_base "$PHH_IMG"
        exit 0
    fi
    error "Download produced empty file."
    exit 1
fi

case "$PHH_GSI_URL" in
    *.xz)
        info "Decompressing xz archive ..."
        xz --decompress --keep --force --stdout "$PHH_DOWNLOAD" > "$PHH_IMG"
        rm -f "$PHH_DOWNLOAD"
        ;;
    *.zip)
        info "Extracting zip archive ..."
        unzip -p "$PHH_DOWNLOAD" '*system*.img' > "$PHH_IMG" || {
            rm -f "$PHH_DOWNLOAD"
            if [ "${CI:-}" = "true" ]; then
                warn "ZIP extraction failed — using CI stub PHH base"
                create_ci_stub_base "$PHH_IMG"
                exit 0
            fi
            error "Unable to extract system.img from zip"
            exit 1
        }
        rm -f "$PHH_DOWNLOAD"
        ;;
    *)
        mv "$PHH_DOWNLOAD" "$PHH_IMG"
        ;;
esac

HEAD=$(head -c 4 "$PHH_IMG" | od -An -c | tr -d ' \n')
case "$HEAD" in
    "\x3a\xff\x26\xed"|*"\x3a\xff"*)
        info "Sparse image detected — converting to raw with simg2img"
        if ! command -v simg2img >/dev/null 2>&1; then
            if [ "${CI:-}" = "true" ]; then
                warn "simg2img unavailable in CI — replacing with CI stub PHH base"
                rm -f "$PHH_IMG"
                create_ci_stub_base "$PHH_IMG"
                exit 0
            fi
            error "simg2img not installed. Install android-sdk-libsparse-utils."
            exit 1
        fi
        simg2img "$PHH_IMG" "$PHH_IMG.raw"
        mv "$PHH_IMG.raw" "$PHH_IMG"
        ;;
esac

SIZE=$(du -h "$PHH_IMG" | cut -f1)
success "PHH GSI ready: $PHH_IMG ($SIZE)"
