#!/usr/bin/env bash
# =============================================================================
# probe_aidl_hals.sh — Host wrapper for Phase-2 binder/AIDL discovery
# =============================================================================
# Pushes and runs hal-aidl-probe.sh inside the Ubuntu chroot (or Android root
# if chroot unavailable). Collects /run/ubuntu-gsi/hal-status/aidl_* .
#
# Usage:
#   bash scripts/probe_aidl_hals.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO/rootfs/overlay/usr/lib/ubuntu-gsi/hal-aidl-probe.sh"
OUT_DIR="${OUT_DIR:-$REPO/builder/out/hal-inventory}"
CHROOT="${CHROOT:-/mnt/halium/merged}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$OUT_DIR"
# Prefer inventory-derived list when present (avoids OEM `service list` hangs).
if [ -f "$OUT_DIR/service_list_from_inventory.txt" ]; then
  cp -f "$OUT_DIR/service_list_from_inventory.txt" "$OUT_DIR/service_list_${STAMP}.txt"
else
  timeout 15 adb shell "service list" >"$OUT_DIR/service_list_${STAMP}.txt" 2>/dev/null || true
fi
adb push "$OUT_DIR/service_list_${STAMP}.txt" /data/local/tmp/service_list.txt >/dev/null
adb push "$SRC" /data/local/tmp/hal-aidl-probe.sh >/dev/null
adb shell "su 0 chmod 755 /data/local/tmp/hal-aidl-probe.sh" >/dev/null

REPORT="$OUT_DIR/aidl_probe_${STAMP}.txt"
{
  echo "=== aidl probe $STAMP ==="
  adb shell "su 0 sh -c '
    mkdir -p /data/uhl_overlay/hal-status
    export HAL_STATUS_DIR=/data/uhl_overlay/hal-status
    export SERVICE_LIST_FILE=/data/local/tmp/service_list.txt
    sh /data/local/tmp/hal-aidl-probe.sh
    echo --- status dir=\$HAL_STATUS_DIR ---
    for f in /data/uhl_overlay/hal-status/aidl_*; do
      [ -f \"\$f\" ] || continue
      echo \"## \$(basename \$f)\"
      cat \"\$f\"
      echo
    done
  '"
} | tee "$REPORT"

cp -f "$REPORT" "$OUT_DIR/aidl_probe_latest.txt"
echo "Saved $REPORT"
