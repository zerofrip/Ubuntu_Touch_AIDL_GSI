#!/bin/bash
# =============================================================================
# scripts/build_vbmeta_stock_patched.sh — Patch stock F8 vbmeta flags (keep chain)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ROM_DIR="${1:-/home/zero/F8_V2.0_20260313/F8_V2.0_20260313}"
OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="$OUT_DIR/vbmeta-stock-patched.img"
VBMETA_FLAGS="${VBMETA_FLAGS:-3}"


STOCK_VBMETA="$ROM_DIR/vbmeta.img"
[ -f "$STOCK_VBMETA" ] || { echo "Missing $STOCK_VBMETA" >&2; exit 1; }
mkdir -p "$OUT_DIR"

meta_json=$(python3 - "$STOCK_VBMETA" "$OUT_IMG" "$VBMETA_FLAGS" <<'PY'
import json, struct, shutil, sys
src, dst, flags = sys.argv[1], sys.argv[2], int(sys.argv[3])
shutil.copyfile(src, dst)
with open(dst, "r+b") as f:
    data = bytearray(f.read())
    assert data[:4] == b"AVB0"
    old = struct.unpack(">I", data[120:124])[0]
    new = old | flags
    struct.pack_into(">I", data, 120, new)
    f.seek(0)
    f.write(data)
    f.truncate(len(data))
print(json.dumps({"oldFlags": old, "newFlags": new, "path": dst}))
PY
)


new_flags=$(python3 -c "import json,sys; print(json.load(sys.stdin)['newFlags'])" <<<"$meta_json")
echo "Stock-patched vbmeta: $OUT_IMG (flags=$new_flags, chain preserved)"
