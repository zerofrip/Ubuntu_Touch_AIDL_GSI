#!/bin/bash
# =============================================================================
# scripts/build_custom_phh.sh — Build/prepare PHH GSI from local source tree
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

TREBLE_EXP_PATH="${TREBLE_EXP_PATH:-$REPO_ROOT/../treble_experimentations}"
PHH_CUSTOM_TARGET="${PHH_CUSTOM_TARGET:-android-15.0}"
PHH_CUSTOM_VARIANT="${PHH_CUSTOM_VARIANT:-td-arm64-ab-vanilla}"
PHH_CUSTOM_SKIP_BUILD="${PHH_CUSTOM_SKIP_BUILD:-0}"
PHH_CUSTOM_OUTPUT="${PHH_CUSTOM_OUTPUT:-}"

OUT_DIR="$REPO_ROOT/builder/cache/custom-phh"
OUT_IMG="$OUT_DIR/system-custom.img"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[PHH Custom]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[PHH Custom]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[PHH Custom]${NC} $1"; }

mkdir -p "$OUT_DIR"

if [ -n "$PHH_CUSTOM_OUTPUT" ]; then
    ASSET_PATH="$PHH_CUSTOM_OUTPUT"
elif [ "$PHH_CUSTOM_SKIP_BUILD" = "1" ]; then
    ASSET_PATH="$(ls -1t "$TREBLE_EXP_PATH"/release/*/system-"$PHH_CUSTOM_VARIANT".img.xz 2>/dev/null | head -n 1 || true)"
else
    if [ ! -d "$TREBLE_EXP_PATH" ]; then
        error "TREBLE_EXP_PATH does not exist: $TREBLE_EXP_PATH"
        exit 1
    fi
    if [ ! -f "$TREBLE_EXP_PATH/build.sh" ]; then
        error "build.sh not found in TREBLE_EXP_PATH: $TREBLE_EXP_PATH"
        exit 1
    fi

    info "Building PHH source image from local tree"
    info "  source  : $TREBLE_EXP_PATH"
    info "  target  : $PHH_CUSTOM_TARGET"
    info "  variant : $PHH_CUSTOM_VARIANT"
    (cd "$TREBLE_EXP_PATH" && bash build.sh "$PHH_CUSTOM_TARGET")

    ASSET_PATH="$(ls -1t "$TREBLE_EXP_PATH"/release/*/system-"$PHH_CUSTOM_VARIANT".img.xz 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${ASSET_PATH:-}" ] || [ ! -f "$ASSET_PATH" ]; then
    error "Unable to locate built PHH asset for variant: $PHH_CUSTOM_VARIANT"
    error "Expected path pattern: $TREBLE_EXP_PATH/release/*/system-$PHH_CUSTOM_VARIANT.img.xz"
    exit 1
fi

info "Preparing PHH image from asset: $ASSET_PATH"
xz --decompress --keep --force --stdout "$ASSET_PATH" > "$OUT_IMG"

HEAD=$(head -c 4 "$OUT_IMG" | od -An -c | tr -d ' \n')
case "$HEAD" in
    "\x3a\xff\x26\xed"|*"\x3a\xff"*)
        info "Sparse image detected — converting to raw with simg2img"
        if ! command -v simg2img >/dev/null 2>&1; then
            error "simg2img not installed. Install android-sdk-libsparse-utils."
            exit 1
        fi
        simg2img "$OUT_IMG" "$OUT_IMG.raw"
        mv "$OUT_IMG.raw" "$OUT_IMG"
        ;;
esac

success "Custom PHH image ready: $OUT_IMG"
echo "$OUT_IMG"
