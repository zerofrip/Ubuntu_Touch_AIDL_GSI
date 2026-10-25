#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IN_SO="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.patched.so"
OUT_SO="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.inproc.so"

if [ ! -f "$IN_SO" ]; then
    echo "ERROR: $IN_SO not found." >&2
    echo "  This is an F8 (MT6897)-specific binary — it must already exist as a PQ-v1-patched .so." >&2
    echo "  Extract stock .so from a connected F8 first:" >&2
    echo "    adb shell su 0 cp /vendor/lib64/hw/hwcomposer.mtk_common.so /data/local/tmp/" >&2
    echo "    adb pull /data/local/tmp/hwcomposer.mtk_common.so \\" >&2
    echo "        builder/out/hwc-patches/hwcomposer.mtk_common.stock.so" >&2
    echo "  Then apply the PQ-v1 patch step to produce patched.so before running this script." >&2
    exit 1
fi

python3 "$REPO/scripts/patch_hwc_inproc.py"

if [ ! -s "$OUT_SO" ]; then
    echo "ERROR: patch_hwc_inproc.py ran but $OUT_SO is missing or empty." >&2
    exit 1
fi

if [ -n "${1:-}" ]; then
    install -D -m 0644 "$OUT_SO" "$1/usr/lib/ubuntu-gsi/halium-compat/hwc_inproc.so"
fi
