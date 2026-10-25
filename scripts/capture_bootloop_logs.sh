#!/bin/bash
# =============================================================================
# scripts/capture_bootloop_logs.sh — Capture logs during Android bootloop
# =============================================================================
# Polls adb during reboot cycles and saves logcat/dmesg/getprop/pstore.
# Also validates local flash artifacts before/after capture.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="${RUN_ID:-bootloop-capture}"

OUT_BASE="${1:-$REPO_ROOT/builder/logs/bootloop_$(date +%Y%m%d_%H%M%S)}"
MAX_ROUNDS="${MAX_ROUNDS:-30}"
WAIT_SEC="${WAIT_SEC:-120}"
CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
SYSTEM_IMG="${SYSTEM_IMG:-$REPO_ROOT/builder/out/${RELEASE_SYSTEM_IMG:-system.img}}"

mkdir -p "$OUT_BASE"


inspect_system_img() {
    python3 - "$1" <<'PY'
import struct, sys, json, os
p = sys.argv[1]
if not os.path.isfile(p):
    print(json.dumps({"exists": False, "path": p}))
    sys.exit(0)
size = os.path.getsize(p)
with open(p, "rb") as f:
    head = f.read(4096)
    f.seek(0x400)
    sb = f.read(64)
ext4_magic = len(sb) >= 0x3A and sb[0x38:0x3A] == b"\x53\xef"
valid = ext4_magic and size >= 536870912
print(json.dumps({
    "path": p,
    "sizeBytes": size,
    "ext4MagicAt0x438": ext4_magic,
    "head16Hex": head[:16].hex(),
    "validForFlash": valid,
    "note": "head16Hex all-zero is normal for ext4; inspect ext4MagicAt0x438 instead",
}))
PY
}

adb_capture_once() {
    local round="$1"
    local tag
    tag="$(date +%Y%m%d_%H%M%S)_r${round}"
    local dir="$OUT_BASE/round_${round}_${tag}"
    mkdir -p "$dir"

    adb devices -l > "$dir/adb_devices.txt" 2>&1 || true
    adb get-state > "$dir/adb_state.txt" 2>&1 || true
    adb shell getprop > "$dir/getprop.txt" 2>&1 || true
    adb shell dmesg > "$dir/dmesg.txt" 2>&1 || true
    adb logcat -d -b all -v threadtime > "$dir/logcat_all.txt" 2>&1 || true
    adb logcat -d -b crash -v threadtime > "$dir/logcat_crash.txt" 2>&1 || true
    adb logcat -d -b kernel -v threadtime > "$dir/logcat_kernel.txt" 2>&1 || true

    for p in /proc/last_kmsg /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/console-ramoops \
             /sys/fs/pstore/pmsg-ramoops-0 /cache/recovery/last_log; do
        adb shell "cat $p 2>/dev/null" > "$dir$(basename "$p").txt" 2>/dev/null || true
    done


    echo "Saved round $round -> $dir"
}

echo "=== Bootloop log capture ==="
echo "Output: $OUT_BASE"
echo "Waiting up to ${WAIT_SEC}s per round, max ${MAX_ROUNDS} rounds"
echo ""

img_json=$(inspect_system_img "$SYSTEM_IMG")
echo "Local system image: $img_json"
echo ""


round=0
while [ "$round" -lt "$MAX_ROUNDS" ]; do
    round=$((round + 1))
    echo "[round $round/$MAX_ROUNDS] waiting for adb device (timeout ${WAIT_SEC}s)..."
    if timeout "$WAIT_SEC" adb wait-for-device 2>"$OUT_BASE/wait_${round}.err"; then
        sleep 2
        adb root >/dev/null 2>&1 || true
        sleep 1
        adb_capture_once "$round"
    else
        echo "[round $round] no adb device within ${WAIT_SEC}s"
    fi
done


echo ""
echo "Done. Logs in: $OUT_BASE"
echo "Analyze with: bash scripts/diagnose_boot_failure.sh \"\" \"$SYSTEM_IMG\" \"\" \"\" \"$OUT_BASE/round_*/logcat_all.txt\""
