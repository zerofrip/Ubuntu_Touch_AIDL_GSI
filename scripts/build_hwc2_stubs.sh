#!/usr/bin/env bash
# Rebuild binder-free HWC2/UI stubs for Lomiri android2 bring-up.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/builder/cache/hwc2-stub"
OUT="$REPO/builder/out/halium13-compat"
INC="$REPO/builder/cache/libhybris-tls/ah/usr/include/android-30"
NDK="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/28.2.13676358}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android34-clang"
mkdir -p "$OUT"

HWC_CFLAGS=(-shared -fPIC -O2 -I"$INC" -llog -ldl)

"$CC" "${HWC_CFLAGS[@]}" -o "$OUT/libhwc2_compat_layer.so" "$SRC/hwc2_compat_stub.c" \
  -Wl,-soname,libhwc2_compat_layer.so
cp "$OUT/libhwc2_compat_layer.so" "$OUT/libhwc2_compat_layer.stub.so"

"$CC" -shared -fPIC -O2 -o "$OUT/libui_compat_layer.so" "$SRC/ui_compat_stub.c" \
  -lnativewindow -llog -ldl -Wl,-soname,libui_compat_layer.so
cp "$OUT/libui_compat_layer.so" "$OUT/libui_compat_layer.stub.so"

"$CC" -fPIC -O2 -I"$INC" -o "$OUT/hwc2_present_probe" "$SRC/hwc2_present_probe.c" \
  -lnativewindow -llog -ldl

"$CC" -O2 -Wall -o "$OUT/drm_prop_dump" "$SRC/drm_prop_dump.c"

echo "built: $OUT/libhwc2_compat_layer.so $OUT/libui_compat_layer.so $OUT/hwc2_present_probe $OUT/drm_prop_dump"

