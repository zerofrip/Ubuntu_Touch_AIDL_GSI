#!/bin/bash
# Apply MTK HWC binary patches for Lomiri (skip PQ binder/XML; stub PqDeviceDrm).
# Run on device as root before start-lomiri. Requires adb push of patched .so first.
set -euo pipefail
PATCHED="${1:-/data/local/tmp/hwc_patched.so}"
TARGET=/vendor/lib64/hw/hwcomposer.mtk_common.so
umount "$TARGET" 2>/dev/null || true
mount --bind "$PATCHED" "$TARGET"
# Free DRM for in-process HWC
stop surfaceflinger 2>/dev/null || true
stop vendor.hwcomposer-3-2 2>/dev/null || true
stop vender.mediatek.hardware.pq_aidl-default 2>/dev/null || true
kill -9 $(pidof surfaceflinger android.hardware.graphics.composer@3.2-service vendor.mediatek.hardware.pq_aidl-service lomiri) 2>/dev/null || true
echo "HWC patch mounted: $PATCHED -> $TARGET"
