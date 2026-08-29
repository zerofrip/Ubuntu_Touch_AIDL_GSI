#!/bin/bash
# =============================================================================
# scripts/build_vbmeta_disabled.sh — Generate a vbmeta image with verity off
# =============================================================================
# AVB flags (avbtool): bit0=HASHTREE_DISABLED(1), bit1=VERIFICATION_DISABLED(2).
# Use flags=3 so init skips dm-verity on dynamic-partition devices (MTK F8).
# Flash with plain `fastboot flash vbmeta_*` — do NOT use --disable-verity on
# fastboot 34+; that flag path fails AVB parsing on standalone vbmeta images.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="$OUT_DIR/vbmeta-disabled.img"
VBMETA_PADDING="${VBMETA_PADDING:-8192}"
VBMETA_FLAGS="${VBMETA_FLAGS:-3}"
mkdir -p "$OUT_DIR"


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[vbmeta]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[vbmeta]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[vbmeta]${NC} $1"; }

resolve_avbtool() {
    local candidate
    for candidate in \
        "${AVBTOOL:-}" \
        "$REPO_ROOT/third_party/external_avb/avbtool.v1.2.py" \
        "$REPO_ROOT/../Android_boot_image_editor/aosp/avb/avbtool.v1.2.py"; do
        [ -n "$candidate" ] && [ -f "$candidate" ] && { echo "$candidate"; return 0; }
    done
    if command -v avbtool >/dev/null 2>&1; then
        echo "avbtool"
        return 0
    fi
    return 1
}

verify_vbmeta_image() {
    python3 - "$1" <<'PY'
import struct, sys
p=sys.argv[1]
d=open(p,'rb').read()
assert d[:4]==b'AVB0', 'missing AVB0 magic'
flags=struct.unpack('>I', d[120:124])[0]
assert flags & 1, f'flags missing HASHTREE_DISABLED (bit0): {flags}'
print(flags)
PY
}

run_avbtool() {
    local tool="$1"
    info "Generating disabled-vbmeta with avbtool (flags=${VBMETA_FLAGS}, padding ${VBMETA_PADDING})"
    if [ "$tool" = "avbtool" ]; then
        avbtool make_vbmeta_image --flags "$VBMETA_FLAGS" --padding_size "$VBMETA_PADDING" --output "$OUT_IMG"
    else
        python3 "$tool" make_vbmeta_image --flags "$VBMETA_FLAGS" --padding_size "$VBMETA_PADDING" --output "$OUT_IMG"
    fi
}

write_handcrafted_vbmeta() {
    info "avbtool unavailable — emitting hand-crafted disabled vbmeta header"
    python3 - "$OUT_IMG" "$VBMETA_PADDING" "$VBMETA_FLAGS" <<'PYEOF'
import struct, sys
out, padding, flags = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
release = f'Ubuntu GSI vbmeta-disabled (flags={flags})\0'.encode()
release = release + b'\0' * (48 - len(release))
# AvbVBMetaImageHeader (libavb): ... rollback_index(Q), flags(I),
# rollback_index_location(I), release_string[48], reserved[80] == 256 bytes.
header = struct.pack(
    '>4sLLQQLQQQQQQQQQQQII48s80s',
    b'AVB0', 1, 0,
    0, 0,
    0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0,
    flags, 0,
    release,
    b'\0' * 80,
)
assert len(header) == 256
with open(out, 'wb') as f:
    f.write(header)
    f.write(b'\0' * (padding - 256))
PYEOF
}

if tool=$(resolve_avbtool); then
    run_avbtool "$tool"
else
    write_handcrafted_vbmeta
fi

flags_val=$(verify_vbmeta_image "$OUT_IMG")
SIZE=$(du -h "$OUT_IMG" | cut -f1)


success "vbmeta-disabled.img ready: $OUT_IMG ($SIZE, flags=$flags_val)"
echo ""
echo -e "${BOLD}Flash WITHOUT --disable-verity flags:${NC}"
echo -e "  fastboot flash vbmeta_a $OUT_IMG"
echo -e "  fastboot flash vbmeta_system_a $OUT_IMG  # MTK chained vbmeta"
echo -e "  fastboot flash vbmeta_vendor_a $OUT_IMG"
echo -e "${YELLOW}MTK tip:${NC} if still bootlooping, also run: fastboot erase metadata"
