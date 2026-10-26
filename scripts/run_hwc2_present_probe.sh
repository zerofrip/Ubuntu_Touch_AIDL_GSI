#!/usr/bin/env bash
# Present-path probe with inproc HWC (Patch-D soft-fail). Verifies setClientTarget / present.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMPAT="$REPO/builder/out/halium13-compat"
INPROC="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.inproc.so"
PATCHED="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.patched.so"
PREP="$REPO/scripts/device_prep_lomiri_gpu.sh"
HOST_LOG="$REPO/builder/out/hwc2_present_probe.host.log"

if [ ! -x "$COMPAT/hwc2_present_probe" ]; then
  bash "$REPO/scripts/build_hwc2_stubs.sh"
fi
if [ ! -f "$INPROC" ]; then
  python3 "$REPO/scripts/patch_hwc_inproc.py"
fi

adb shell su 0 touch /data/local/tmp/lomiri_mode_inproc
adb shell su 0 touch /data/local/tmp/lomiri_hal_present
adb shell su 0 rm -f /data/local/tmp/lomiri_mode_aidl 2>/dev/null || true

adb shell su 0 mkdir -p /data/local/tmp/halium13-compat
for f in libhwc2_compat_layer.so libui_compat_layer.so hwc2_present_probe; do
  [ -f "$COMPAT/$f" ] || continue
  adb push "$COMPAT/$f" /data/local/tmp/halium13-compat/"$f" >/dev/null
done
adb shell su 0 chmod 755 /data/local/tmp/halium13-compat/hwc2_present_probe

adb push "$INPROC" /data/local/tmp/hwc_inproc.so >/dev/null
[ -f "$PATCHED" ] && adb push "$PATCHED" /data/local/tmp/hwc_patched.so >/dev/null || true
adb shell su 0 cp -f /apex/com.android.vndk.v34/lib64/android.hardware.graphics.common-V4-ndk.so \
  /data/local/tmp/halium13-compat/android.hardware.graphics.common-V4-ndk.so

adb push "$PREP" /data/local/tmp/device_prep_lomiri_gpu.sh >/dev/null
adb shell su 0 chmod 755 /data/local/tmp/device_prep_lomiri_gpu.sh
adb shell su 0 /data/local/tmp/device_prep_lomiri_gpu.sh | tee "$HOST_LOG"

adb shell su 0 logcat -c >/dev/null || true

PROBE_SH=/data/local/tmp/hwc2_present_probe_run.sh
adb shell su 0 sh -c "cat > $PROBE_SH <<'EOF'
#!/system/bin/sh
cp -f /apex/com.android.vndk.v34/lib64/android.hardware.graphics.common-V4-ndk.so \\
  /data/local/tmp/halium13-compat/android.hardware.graphics.common-V4-ndk.so 2>/dev/null
export LD_LIBRARY_PATH=/data/local/tmp/halium13-compat:/vendor/lib64:/vendor/lib64/hw
export HWC2_STUB_HAL_PRESENT=1
export HWC2_STUB_HAL_CALLBACK=1
# full present path (default steps include setClientTarget + present)
/data/local/tmp/halium13-compat/hwc2_present_probe present
echo probe_exit=\$?
EOF
chmod 755 $PROBE_SH"

echo "=== running present probe ===" | tee -a "$HOST_LOG"
adb shell su 0 "$PROBE_SH" 2>&1 | tee -a "$HOST_LOG"

echo "=== logcat markers ===" | tee -a "$HOST_LOG"
adb shell su 0 logcat -d 2>/dev/null | grep -iE \
  'setClientTarget|presentDisplay|SEGV|checkProperty|failed to check|hal_present|hal_hotplug|Present|error=-22|softfail|client target|Attribute:|HAL cfg|drm_snapshot|setActiveConfig|HAL validate|HAL accept|getChanged|setCompositionType|AtomicCommit|createFb|no_client_target|PresentVali|SET/bypass|does not receive client|onPlugIn|initInternal|not enabled|dispatcher|Failed to create|display session|OverlayEngine' \
  | tee -a "$HOST_LOG" | tail -120 || true

echo "done; full log: $HOST_LOG"

