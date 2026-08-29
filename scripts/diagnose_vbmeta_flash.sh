#!/bin/bash
# =============================================================================
# scripts/diagnose_vbmeta_flash.sh — Inspect vbmeta images + fastboot flash behavior
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STOCK_VBMETA="${1:-/home/zero/F8_V2.0_20260313/F8_V2.0_20260313/vbmeta.img}"
BUILT_VBMETA="${2:-$REPO_ROOT/builder/out/vbmeta-disabled.img}"

inspect_vbmeta() {
    local path="$1"
    python3 - "$path" <<'PY'
import struct, sys, json
p=sys.argv[1]
try:
    d=open(p,'rb').read()
except OSError as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)
magic=d[:4].decode('latin1','replace') if len(d)>=4 else ''
flags=struct.unpack('>I', d[120:124])[0] if len(d)>=124 else None
print(json.dumps({"path": p, "size": len(d), "magic": magic, "flags": flags, "validAvb0": magic=="AVB0"}))
PY
}

run_flash_probe() {
    local part="$1"
    local img="$2"
    local flags="$3"
    # shellcheck disable=SC2086
    local out
    out=$(fastboot $flags flash "$part" "$img" 2>&1 || true)
    printf '%s' "$out" | tail -3
    if echo "$out" | grep -q "Failed to find AVB_MAGIC"; then
        echo "AVB_MAGIC_FAIL"
    elif echo "$out" | grep -q "Writing.*OKAY"; then
        echo "WRITE_OKAY"
    elif echo "$out" | grep -q "No such file or directory"; then
        echo "REMOTE_ENOENT"
    else
        echo "OTHER"
    fi
}

echo "=== vbmeta flash diagnosis ==="
echo "fastboot: $(fastboot --version 2>&1 | head -1)"
echo "stock:    $STOCK_VBMETA"
echo "built:    $BUILT_VBMETA"
echo ""

stock_json=$(inspect_vbmeta "$STOCK_VBMETA")
built_json=$(inspect_vbmeta "$BUILT_VBMETA")
echo "Image inspection:"
echo "  stock: $stock_json"
echo "  built: $built_json"
echo ""

userspace=$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/is-userspace/{print $2; exit}')
echo "fastboot mode: is-userspace=${userspace:-unknown}"
echo ""

if [ -f "$STOCK_VBMETA" ]; then
    echo "Stock vbmeta flash probes (writes to device):"
    r1=$(run_flash_probe vbmeta_a "$STOCK_VBMETA" "--disable-verity --disable-verification")
    r2=$(run_flash_probe vbmeta_a "$STOCK_VBMETA" "")
    echo "  with --disable-verity: $r1"
    echo "  plain flash:           $r2"
    echo ""
fi

if [ -f "$BUILT_VBMETA" ]; then
    echo "Built vbmeta flash probes (writes to device):"
    r3=$(run_flash_probe vbmeta_a "$BUILT_VBMETA" "--disable-verity --disable-verification")
    r4=$(run_flash_probe vbmeta_a "$BUILT_VBMETA" "")
    echo "  with --disable-verity: $r3"
    echo "  plain flash:           $r4"
fi
