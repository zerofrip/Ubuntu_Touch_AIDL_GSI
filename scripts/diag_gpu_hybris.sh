#!/bin/bash
# =============================================================================
# scripts/diag_gpu_hybris.sh — F8 GPU / libhybris inventory (adb, read-only)
# =============================================================================
# Collect vendor/apex library paths and optional chroot hybris tests.
# Usage:
#   bash scripts/diag_gpu_hybris.sh              # device inventory only
#   bash scripts/diag_gpu_hybris.sh --chroot     # also run test_egl/test_hwcomposer
#   bash scripts/diag_gpu_hybris.sh --debug      # LIBHYBRIS_DEBUG=1 for tests
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROOT="${CHROOT:-/mnt/halium/merged}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/builder/out/gpu-diag}"
MODE="${1:-inventory}"
DEBUG="${LIBHYBRIS_DEBUG:-0}"

su0() { adb shell "su 0 $*" ; }

mkdir -p "$OUT_DIR"
STAMP="$(date -Iseconds | tr ':' '-')"
REPORT="$OUT_DIR/f8_gpu_diag_${STAMP}.txt"

{
    echo "=== F8 GPU / libhybris diagnostic ==="
    echo "timestamp: $(date -Iseconds)"
    echo "repo: $REPO_ROOT"
    echo ""

    echo "=== adb devices ==="
    adb devices
    echo ""

    echo "=== Props ==="
    for p in sys.boot_completed persist.ubuntu_gsi.enable persist.ubuntu_gsi.failed \
             init.svc.ubuntu-gsi-launcher init.svc.surfaceflinger ro.hardware ro.board.platform; do
        echo -n "$p="; adb shell getprop "$p" 2>/dev/null | tr -d '\r'
    done
    echo ""

    echo "=== Vendor GPU libraries ==="
    su0 "ls -la /vendor/lib64/egl 2>&1" || true
    su0 "ls -la /vendor/lib64/hw 2>&1" || true
    su0 "ls -la /vendor/lib64/hwcomposer* 2>&1" || true
    su0 "ls /vendor/lib64/hw/vulkan.*.so 2>&1" || true
    su0 "ls /vendor/lib64/mt* 2>&1" || true
    su0 "find /vendor/lib64 -maxdepth 2 -name 'libGLES*.so' -o -name 'libEGL*.so' 2>&1" | head -40 || true
    echo ""

    echo "=== Bionic / apex (libc.so resolution) ==="
    su0 "ls -la /apex/com.android.runtime/lib64/bionic/libc.so 2>&1" || true
    su0 "ls -la /system/lib64/libc.so 2>&1" || true
    su0 "ls -la /system_real/lib64/libc.so 2>&1" || true
    su0 "ls /system_real/lib64/vndk-* 2>&1" || true
    su0 "ls /apex/com.android.art/lib64 2>&1" | head -20 || true
    echo ""

    echo "=== Chroot rootfs hybris packages ==="
    su0 "ls -la $CHROOT/usr/lib/aarch64-linux-gnu/libsync.so* 2>&1" || true
    su0 "ls -la $CHROOT/usr/lib/aarch64-linux-gnu/libgralloc.so* 2>&1" || true
    su0 "ls $CHROOT/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android*.so* 2>&1" || true
    su0 "ls $CHROOT/usr/lib/aarch64-linux-gnu/libhybris/test_* 2>&1" || true
    echo ""

    echo "=== Suggested HYBRIS_LD_LIBRARY_PATH extras (heuristic) ==="
    su0 "sh -c '
        for d in \
            /apex/com.android.runtime/lib64/bionic \
            /apex/com.android.art/lib64 \
            /system_real/lib64/vndk-* \
            /vendor/lib64/mt6897 \
            /vendor/lib64/mt*; do
            [ -d \"\$d\" ] && echo \"  \$d\"
        done
    '" || true
    echo ""

    echo "=== mounts (halium/overlay) ==="
    su0 "mount 2>&1" | grep -E 'halium|erofs|overlay|vendor|system_real' || true
    echo ""

    echo "=== launcher / Mir logcat (last 80) ==="
    su0 "logcat -d -s ubuntu-gsi-launcher Mir 2>&1" | tail -80 || true
} | tee "$REPORT"

if [ "$MODE" = "--chroot" ] || [ "$MODE" = "--debug" ]; then
    if [ "$MODE" = "--debug" ]; then
        DEBUG=1
    fi
    {
        echo ""
        echo "=== chroot hybris tests (LIBHYBRIS_DEBUG=$DEBUG) ==="
        for test in test_egl test_hwcomposer; do
            echo "--- $test ---"
            su0 "chroot $CHROOT sh -c 'export LIBHYBRIS_DEBUG=$DEBUG; \
                export HYBRIS_LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib64/hw:/system_real/lib64:/system_real/lib64/hw:/apex/com.android.runtime/lib64/bionic; \
                /usr/lib/aarch64-linux-gnu/libhybris/$test' 2>&1" || true
            echo "exit=$?"
        done
    } | tee -a "$REPORT"
fi

echo ""
echo "Report saved: $REPORT"
