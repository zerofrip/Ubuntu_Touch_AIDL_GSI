#!/bin/bash
# =============================================================================
# scripts/build_vbmeta_disabled.sh — Generate a vbmeta image with verity off
# =============================================================================
# The custom system.img we ship has a digest that does not match the OEM's
# vbmeta_system entry. With dm-verity in `enforcing` mode, the kernel would
# reject our system at mount time. We can't change kernel settings (per the
# project's no-boot.img/no-kernel-changes constraint), so we flash a vbmeta
# image whose `flags` field has bit 1 (`HASHTREE_DISABLED`, value 2) set.
#
# Bootloaders honour that flag and instruct the kernel cmdline-builder to
# emit `androidboot.veritymode=disabled`. dm-verity is then bypassed for
# system, system_ext and product.
#
# This image is flashed via:
#
#   fastboot --disable-verity --disable-verification \
#            flash vbmeta builder/out/vbmeta-disabled.img
#
# Build dependency: avbtool (from `android-sdk-platform-tools-common` or
# AOSP's `external/avb`).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="$OUT_DIR/vbmeta-disabled.img"
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[vbmeta]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[vbmeta]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[vbmeta]${NC} $1"; }

# ---------------------------------------------------------------------------
# Strategy 1: avbtool (preferred)
# ---------------------------------------------------------------------------
if command -v avbtool >/dev/null 2>&1; then
    info "Generating disabled-vbmeta with avbtool"
    avbtool make_vbmeta_image \
        --flags 2 \
        --padding_size 4096 \
        --output "$OUT_IMG"
    SIZE=$(du -h "$OUT_IMG" | cut -f1)
    success "vbmeta-disabled.img ready: $OUT_IMG ($SIZE)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Strategy 2: bundled avbtool from AOSP submodule (third_party/external_avb)
# ---------------------------------------------------------------------------
LOCAL_AVB="$REPO_ROOT/third_party/external_avb/avbtool"
if [ -x "$LOCAL_AVB" ]; then
    info "Generating disabled-vbmeta with bundled avbtool"
    "$LOCAL_AVB" make_vbmeta_image \
        --flags 2 \
        --padding_size 4096 \
        --output "$OUT_IMG"
    SIZE=$(du -h "$OUT_IMG" | cut -f1)
    success "vbmeta-disabled.img ready: $OUT_IMG ($SIZE)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Strategy 3: Hand-crafted minimal vbmeta header (last-resort)
# ---------------------------------------------------------------------------
# A vbmeta image is { 256-byte header || authentication block || aux block }.
# We emit a header with magic "AVB0", required_libavb_version_major=1,
# required_libavb_version_minor=0, hash_algorithm=NONE, flags=2, and zero
# auth/aux sizes. Bootloaders accept this when they're told
# `--disable-verification` on the fastboot side.
info "avbtool unavailable — emitting hand-crafted disabled vbmeta header"

python3 - "$OUT_IMG" <<'PYEOF'
import struct, sys
out = sys.argv[1]
HEADER_SIZE = 256
PADDING    = 4096

magic              = b'AVB0'
req_major          = 1
req_minor          = 0
auth_block_size    = 0
aux_block_size     = 0
algorithm_type     = 0   # NONE
hash_offset        = 0
hash_size          = 0
signature_offset   = 0
signature_size     = 0
public_key_offset  = 0
public_key_size    = 0
public_key_metadata_offset = 0
public_key_metadata_size   = 0
descriptors_offset = 0
descriptors_size   = 0
rollback_index     = 0
flags              = 2   # HASHTREE_DISABLED
release_string     = b'avbtool 1.2.0 (disabled stub)\0' + b'\0' * (47 - len(b'avbtool 1.2.0 (disabled stub)\0'))

# Big-endian, matches the AOSP `AvbVBMetaImageHeader` struct.
header = struct.pack(
    '>4sLLQQLQQQQQQQQQL',
    magic,
    req_major,
    req_minor,
    auth_block_size,
    aux_block_size,
    algorithm_type,
    hash_offset,
    hash_size,
    signature_offset,
    signature_size,
    public_key_offset,
    public_key_size,
    public_key_metadata_offset,
    public_key_metadata_size,
    descriptors_offset,
    descriptors_size,
)
# `rollback_index` (8) + `flags` (4) + reserved (4)  + release_string (47)
header += struct.pack('>QLL47s', rollback_index, flags, 0, release_string)
# Pad to HEADER_SIZE
header += b'\0' * (HEADER_SIZE - len(header))

with open(out, 'wb') as f:
    f.write(header)
    f.write(b'\0' * (PADDING - HEADER_SIZE))
PYEOF

SIZE=$(du -h "$OUT_IMG" | cut -f1)
success "vbmeta-disabled.img (stub) ready: $OUT_IMG ($SIZE)"
echo ""
echo -e "${BOLD}NOTE:${NC} this stub satisfies the on-device verifier when"
echo -e "      \`fastboot --disable-verity --disable-verification\` is used."
echo -e "      For production you should install \`avbtool\` and re-run."
