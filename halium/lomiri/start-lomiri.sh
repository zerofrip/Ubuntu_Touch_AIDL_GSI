#!/bin/bash
# =============================================================================
# /usr/lib/ubuntu-gsi/halium/start-lomiri.sh
# =============================================================================
# Run *inside the Ubuntu chroot* as the body of `lomiri.service`.
# Sets up the libhybris environment that lets glibc-built Mir reach the
# Bionic-built vendor EGL/GLES/Vulkan/HWC blobs that Android already loaded.
#
# Reference: https://docs.halium.org/en/latest/porting/12.html#libhybris
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Vendor / system search paths (provided by the launcher's bind-mounts)
# -----------------------------------------------------------------------------
ANDROID_ROOT=/system_real
VENDOR_ROOT=/vendor

# Architecture-specific path under vendor/system.
case "$(uname -m)" in
    aarch64)  ANDROID_ARCH=lib64 ;;
    armv7l)   ANDROID_ARCH=lib   ;;
    *)        echo "Unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# -----------------------------------------------------------------------------
# Linker / loader: libhybris ships its own dynamic linker; point it at the
# Android library cone.
# -----------------------------------------------------------------------------
export LD_LIBRARY_PATH="/usr/lib/aarch64-linux-gnu/libhybris${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

export ANDROID_ROOT
export ANDROID_DATA=/data/ubuntu-gsi/android-data
export ANDROID_RUNTIME_ROOT="${ANDROID_ROOT}/apex/com.android.runtime"
export ANDROID_TZDATA_ROOT="${ANDROID_ROOT}/apex/com.android.tzdata"
export ANDROID_I18N_ROOT="${ANDROID_ROOT}/apex/com.android.i18n"
export ANDROID_ART_ROOT="${ANDROID_ROOT}/apex/com.android.art"
export EGL_PLATFORM=hwcomposer
export QT_QPA_PLATFORM=mirserver
export GRID_UNIT_PX=18
export QTWEBENGINE_DISABLE_SANDBOX=1

# Android linker namespace
export HYBRIS_LD_LIBRARY_PATH="${VENDOR_ROOT}/${ANDROID_ARCH}:${VENDOR_ROOT}/${ANDROID_ARCH}/hw:${ANDROID_ROOT}/${ANDROID_ARCH}:${ANDROID_ROOT}/${ANDROID_ARCH}/hw"

mkdir -p "$ANDROID_DATA" /run/user/32011

# -----------------------------------------------------------------------------
# Vendor properties — Lomiri/Mir read getprop indirectly via libhybris.
# Apply the compat-engine snapshot so PHH-style toggles are in effect.
# -----------------------------------------------------------------------------
if [ -x /usr/lib/ubuntu-gsi/compat/compat-engine.sh ]; then
    /usr/lib/ubuntu-gsi/compat/compat-engine.sh linux-mode || true
fi

# -----------------------------------------------------------------------------
# Mir/Lomiri launch
#
# The exact binary depends on the packaged Lomiri version. Try the modern
# `lomiri` entry point first, then fall back to legacy `unity8`.
# -----------------------------------------------------------------------------
LOMIRI_BIN=""
for candidate in /usr/bin/lomiri /usr/bin/unity8 /usr/bin/lomiri-shell; do
    if [ -x "$candidate" ]; then
        LOMIRI_BIN="$candidate"
        break
    fi
done

if [ -z "$LOMIRI_BIN" ]; then
    echo "Lomiri binary not found inside the chroot — install lomiri-shell." >&2
    exit 2
fi

# Make sure the user session bus is available.
mkdir -p /run/user/32011
chown 32011:32011 /run/user/32011 2>/dev/null || true

exec sudo -E -u ubuntu \
    XDG_RUNTIME_DIR=/run/user/32011 \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/32011/bus" \
    "$LOMIRI_BIN" --mode=full-shell
