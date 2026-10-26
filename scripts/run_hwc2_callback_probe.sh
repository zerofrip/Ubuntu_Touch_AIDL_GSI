#!/usr/bin/env bash
# Phase 3: HWC2 stub callback-only probe with inproc-patched vendor HWC.
# Prefer Android-side run (NDK probe + vendor LD path); avoids Ubuntu-chroot
# linker for the probe binary itself.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMPAT="$REPO/builder/out/halium13-compat"
INPROC="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.inproc.so"
PATCHED="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.patched.so"
PREP="$REPO/scripts/device_prep_lomiri_gpu.sh"
HOST_LOG="$REPO/builder/out/hwc2_callback_probe.host.log"

if [ ! -x "$COMPAT/hwc2_present_probe" ]; then
  echo "Building stubs..."
  bash "$REPO/scripts/build_hwc2_stubs.sh"
fi
if [ ! -f "$INPROC" ]; then
  echo "Building inproc HWC..."
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
if [ -f "$PATCHED" ]; then
  adb push "$PATCHED" /data/local/tmp/hwc_patched.so >/dev/null
fi
# Vendor HWC needs common-V4-ndk (lives in VNDK apex).
adb shell su 0 cp -f /apex/com.android.vndk.v34/lib64/android.hardware.graphics.common-V4-ndk.so \
  /data/local/tmp/halium13-compat/android.hardware.graphics.common-V4-ndk.so

adb push "$PREP" /data/local/tmp/device_prep_lomiri_gpu.sh >/dev/null
adb shell su 0 chmod 755 /data/local/tmp/device_prep_lomiri_gpu.sh
adb shell su 0 /data/local/tmp/device_prep_lomiri_gpu.sh | tee "$HOST_LOG"

adb shell su 0 logcat -c >/dev/null || true

# Push probe runner (adb sh -c mangles multiline exports).
PROBE_SH=/data/local/tmp/hwc2_callback_probe_run.sh
adb shell su 0 sh -c "cat > $PROBE_SH <<'EOF'
#!/system/bin/sh
cp -f /apex/com.android.vndk.v34/lib64/android.hardware.graphics.common-V4-ndk.so \\
  /data/local/tmp/halium13-compat/android.hardware.graphics.common-V4-ndk.so 2>/dev/null
export LD_LIBRARY_PATH=/data/local/tmp/halium13-compat:/vendor/lib64:/vendor/lib64/hw
export HWC2_STUB_HAL_PRESENT=1
export HWC2_STUB_HAL_CALLBACK=1
export HWC2_STUB_HAL_STEP=open,callback
/data/local/tmp/halium13-compat/hwc2_present_probe callback
echo probe_exit=\$?
EOF
chmod 755 $PROBE_SH"

echo "=== running callback probe ===" | tee -a "$HOST_LOG"
adb shell su 0 "$PROBE_SH" 2>&1 | tee -a "$HOST_LOG"

echo "=== logcat hwc2_stub / hwc2_probe / hwcomposer ===" | tee -a "$HOST_LOG"
adb shell su 0 logcat -d -s hwc2_stub:V hwc2_probe:V hwcomposer:V 2>/dev/null | tee -a "$HOST_LOG" | tail -80

echo "=== grep key markers ===" | tee -a "$HOST_LOG"
adb shell su 0 logcat -d 2>/dev/null | grep -iE \
  'registerCallback|post-register create|hal_hotplug|hal_present_ready|createLayer|not connected|HAL hotplug|callback probe|getFunction create' \
  | tee -a "$HOST_LOG" | tail -40 || true

echo "done; full log: $HOST_LOG"
