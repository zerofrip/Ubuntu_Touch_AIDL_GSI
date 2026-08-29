#!/bin/bash
# =============================================================================
# scripts/capture_fastboot_diag.sh — Bootloop diagnostics without adb shell
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="${RUN_ID:-fastboot-diag}"

OUT_DIR="${1:-$REPO_ROOT/builder/logs/fastboot_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT_DIR"


if ! command -v fastboot >/dev/null 2>&1; then
    echo "fastboot not found" >&2
    exit 1
fi

if ! fastboot devices 2>/dev/null | grep -q .; then
    echo "No fastboot device. Boot to bootloader (Vol+ at power-on)." >&2
    exit 1
fi

getvar() {
    fastboot getvar "$1" 2>&1 | awk -F': ' -v k="$1" '$0 ~ k":" {sub(/^.*: /,""); gsub(/\r/,""); print; exit}'
}

VARS=(
    current-slot slot-count slot-successful:a slot-successful:b
    slot-unbootable:a slot-unbootable:b slot-retry-count:a slot-retry-count:b
    unlocked secure is-userspace
    partition-type:userdata partition-size:userdata
    partition-type:metadata partition-size:metadata
    partition-type:system_a partition-size:system_a
)

{
    echo "# fastboot diagnostics $(date -Iseconds)"
    for v in "${VARS[@]}"; do
        echo "$v=$(getvar "$v")"
    done
} | tee "$OUT_DIR/getvars.txt"

# shellcheck disable=SC2034
userdata_fs=$(getvar "partition-type:userdata")
userdata_img_fs="unknown"
if [ -f "$REPO_ROOT/builder/out/userdata.img" ]; then
    # shellcheck disable=SC2034
    userdata_img_fs=$(file -b "$REPO_ROOT/builder/out/userdata.img" | head -1)
fi


echo ""
echo "Diagnostics: $OUT_DIR/getvars.txt"
slot_a_ok=$(grep '^slot-successful:a=' "$OUT_DIR/getvars.txt" | cut -d= -f2- || true)
slot_b_ok=$(grep '^slot-successful:b=' "$OUT_DIR/getvars.txt" | cut -d= -f2- || true)
current_slot=$(grep '^current-slot=' "$OUT_DIR/getvars.txt" | cut -d= -f2- || true)


if [ "$slot_a_ok" = "no" ] && [ "$slot_b_ok" = "yes" ] && [ "$current_slot" = "a" ]; then
    echo ""
    echo "NOTE: slot B marked successful (likely stock), slot A failing (GSI)."
    echo "Test stock boot: fastboot set_active b && fastboot reboot"
    echo "Fix GSI slot A:   VBMETA_MODE=hybrid bash scripts/recover_f8_gsi_boot.sh"
fi
