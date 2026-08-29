#!/bin/bash
# Run inside chroot with hybris env (called via adb).
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export ANDROID_ROOT=/system_real
export HYBRIS_LINKER_DIR=/usr/lib/aarch64-linux-gnu/libhybris/linker
export HYBRIS_LD_LIBRARY_PATH=/tmp/hybris-alias:/vendor/lib64/egl:/vendor/lib64/hw:/vendor/lib64/mt6897:/system_real/lib64/hw:/system_real/lib64
export EGL_PLATFORM=hwcomposer
export LIBEGL=libGLES_mali.so
export LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/libhybris:${LD_LIBRARY_PATH:-}

cp -f /data/local/tmp/egl_warmup /tmp/egl_warmup 2>/dev/null || true
chmod 755 /tmp/egl_warmup 2>/dev/null || true
echo "=== egl_warmup ==="
/tmp/egl_warmup >/tmp/egl_warmup.out 2>&1 || true
cat /tmp/egl_warmup.out 2>/dev/null || true
cat /tmp/egl_warmup.log 2>/dev/null || true

echo "=== test_egl ==="
if [ -x /usr/lib/aarch64-linux-gnu/libhybris/test_egl ]; then
  /usr/lib/aarch64-linux-gnu/libhybris/test_egl >/tmp/test_egl.out 2>&1 || true
  cat /tmp/test_egl.out 2>/dev/null | head -80
fi

echo "=== lomiri host egl lines ==="
# filled by host
