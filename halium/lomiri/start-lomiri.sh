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

# Prefer Ubuntu binaries over Android PATH entries bind-mounted into the chroot.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

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

# /system symlink expected by some libhybris probes
if [ ! -e /system ]; then
    ln -sfn "$ANDROID_ROOT" /system 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# GPU detection + libhybris / Mir environment (from graphics_hal.sh)
# -----------------------------------------------------------------------------
GPU_MODE=""

detect_gpu_mode() {
    if [ -n "${UBUNTU_GSI_GPU_MODE:-}" ]; then
        GPU_MODE="$UBUNTU_GSI_GPU_MODE"
        echo "GPU mode: $GPU_MODE (override)" >&2
        return 0
    fi
    # Mali/MTK also ship vulkan*.so; Halium Mir needs hybris+hwcomposer first.
    if ls "${VENDOR_ROOT}/${ANDROID_ARCH}/egl/libGLES_"*.so >/dev/null 2>&1 || \
       ls "${VENDOR_ROOT}/${ANDROID_ARCH}/libEGL_"*.so >/dev/null 2>&1 || \
       ls "${VENDOR_ROOT}/${ANDROID_ARCH}/mt"*"/libGLES_"*.so >/dev/null 2>&1 || \
       ls "${VENDOR_ROOT}/${ANDROID_ARCH}/hw/hwcomposer."*.so >/dev/null 2>&1; then
        GPU_MODE="egl_hybris"
    elif ls "${VENDOR_ROOT}/${ANDROID_ARCH}/hw/vulkan."*.so >/dev/null 2>&1; then
        GPU_MODE="vulkan_zink"
    else
        GPU_MODE="llvmpipe"
    fi
    echo "GPU mode: $GPU_MODE" >&2
}

apply_gpu_env() {
    case "$GPU_MODE" in
        vulkan_zink)
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            unset MIR_SERVER_GRAPHICS_PLATFORM || true
            ;;
        egl_hybris)
            # Package ships eglplatform_hwcomposer.so (no eglplatform_hybris.so).
            export EGL_PLATFORM="${EGL_PLATFORM:-hwcomposer}"
            export HYBRIS_EGLPLATFORM="${HYBRIS_EGLPLATFORM:-$EGL_PLATFORM}"
            # Bypass Android META-EGL loader; pick first vendor libGLES_*.so
            # (no SoC/vendor name hardcoding — mali is preferred when present).
            if [ -z "${LIBEGL:-}" ]; then
                _gles=""
                if [ -f "${VENDOR_ROOT}/${ANDROID_ARCH}/egl/libGLES_mali.so" ]; then
                    _gles="${VENDOR_ROOT}/${ANDROID_ARCH}/egl/libGLES_mali.so"
                elif ls "${VENDOR_ROOT}/${ANDROID_ARCH}/egl/libGLES_"*.so >/dev/null 2>&1; then
                    _gles=$(ls "${VENDOR_ROOT}/${ANDROID_ARCH}/egl/libGLES_"*.so | head -1)
                else
                    for _d in "${VENDOR_ROOT}/${ANDROID_ARCH}"/*; do
                        [ -d "$_d" ] || continue
                        if ls "$_d"/libGLES_*.so >/dev/null 2>&1; then
                            _gles=$(ls "$_d"/libGLES_*.so | head -1)
                            break
                        fi
                    done
                fi
                if [ -n "$_gles" ]; then
                    export LIBEGL=$(basename "$_gles")
                    export LIBGLESV2=$(basename "$_gles")
                fi
            fi
            # Mir turns MIR_SERVER_FOO into --foo. GRAPHICS_PLATFORM is not a
            # valid option ("unrecognised option" right after ScreensModel).
            unset MIR_SERVER_GRAPHICS_PLATFORM || true
            export LOMIRI_FORCE_FALLBACK_GLES=0
            ;;
        llvmpipe|*)
            export LIBGL_ALWAYS_SOFTWARE=1
            export GALLIUM_DRIVER=llvmpipe
            unset MIR_SERVER_GRAPHICS_PLATFORM || true
            export EGL_PLATFORM=wayland
            ;;
    esac
}

symlink_vendor_gpu_libs() {
    local vdir lib basename
    # Device-agnostic: egl/hw plus any vendor arch subdir (SoC blobs).
    for vdir in \
        "${VENDOR_ROOT}/${ANDROID_ARCH}/egl" \
        "${VENDOR_ROOT}/${ANDROID_ARCH}/hw" \
        "${VENDOR_ROOT}/${ANDROID_ARCH}" \
        "${VENDOR_ROOT}/${ANDROID_ARCH}"/*; do
        [ -d "$vdir" ] || continue
        case "$vdir" in
            */egl|*/hw|"${VENDOR_ROOT}/${ANDROID_ARCH}") ;;
            *)
                # Only SoC subdirs that look like GPU/HAL carriers
                ls "$vdir"/libGLES*.so "$vdir"/hwcomposer.*.so "$vdir"/gralloc.*.so \
                    >/dev/null 2>&1 || continue
                ;;
        esac
        for lib in "$vdir"/libGLES*.so "$vdir"/libEGL*.so "$vdir"/libGLESv*.so \
                   "$vdir"/vulkan.*.so "$vdir"/gralloc.*.so "$vdir"/hwcomposer.*.so \
                   "$vdir"/libgralloc*.so "$vdir"/libhardware*.so; do
            [ -f "$lib" ] || continue
            basename=$(basename "$lib")
            if [ ! -e "/usr/lib/aarch64-linux-gnu/$basename" ]; then
                ln -sf "$lib" "/usr/lib/aarch64-linux-gnu/$basename" 2>/dev/null || true
            fi
        done
    done
}

build_hybris_ld_path() {
    local base="" d extra
    # Prefer egl/hw; then discover SoC subdirs under vendor arch (no hardcoded chip).
    for d in \
        "${VENDOR_ROOT}/${ANDROID_ARCH}/egl" \
        "${VENDOR_ROOT}/${ANDROID_ARCH}/hw" \
        "${ANDROID_ROOT}/${ANDROID_ARCH}/hw" \
        "${ANDROID_ROOT}/${ANDROID_ARCH}"; do
        [ -d "$d" ] || continue
        if [ -z "$base" ]; then
            base="$d"
        else
            base="${base}:${d}"
        fi
    done
    # Any immediate subdirectory of vendor/lib64 that holds GLES/HWC (e.g. mt6897, qcom).
    if [ -d "${VENDOR_ROOT}/${ANDROID_ARCH}" ]; then
        for d in "${VENDOR_ROOT}/${ANDROID_ARCH}"/*; do
            [ -d "$d" ] || continue
            case "$(basename "$d")" in egl|hw) continue ;; esac
            ls "$d"/libGLES*.so "$d"/libEGL*.so "$d"/hwcomposer.*.so "$d"/gralloc.*.so \
                >/dev/null 2>&1 || continue
            base="${base}:${d}"
        done
    fi
    for extra in \
        /apex/com.android.vndk.v34/lib64 \
        /apex/com.android.vndk.v33/lib64 \
        /apex/com.android.vndk.v32/lib64 \
        /apex/com.android.vndk.v31/lib64; do
        [ -d "$extra" ] || continue
        base="${base}:${extra}"
    done
    if [ -n "${HYBRIS_LD_EXTRA:-}" ]; then
        base="${base}:${HYBRIS_LD_EXTRA}"
    fi
    echo "$base"
}

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
export QT_QPA_PLATFORM=mirserver
# Avoid logind/VT wait (was delaying Mir input open by ~60s on this Android host).
export MIR_SERVER_CONSOLE_PROVIDER="${MIR_SERVER_CONSOLE_PROVIDER:-none}"
# Solid glyph raster — distance-field atlas path was blank on this GPU stack.
export QSG_DISTANCEFIELD_TEXT=0
# GRID_UNIT_PX: set below from DRM resolution (or env override).
export QTWEBENGINE_DISABLE_SANDBOX=1

# -----------------------------------------------------------------------------
# Display mode (baked into rootfs as /etc/ubuntu-gsi/display-mode)
# lower-layer: disable Mir android2 + default to llvmpipe (DRM/GBM not GO yet)
# Runtime override (highest priority): UBUNTU_GSI_DISPLAY_MODE or
# /data/local/tmp/ubuntu-gsi-display-mode — use "hwc" to restore GUI without reflash.
# -----------------------------------------------------------------------------
DISPLAY_MODE="hwc"
if [ -n "${UBUNTU_GSI_DISPLAY_MODE:-}" ]; then
    DISPLAY_MODE=$(printf '%s' "$UBUNTU_GSI_DISPLAY_MODE" | tr -d " \t\r\n")
elif [ -f /data/local/tmp/ubuntu-gsi-display-mode ]; then
    DISPLAY_MODE=$(tr -d " \t\r\n" </data/local/tmp/ubuntu-gsi-display-mode)
else
    for _dm in /etc/ubuntu-gsi/display-mode \
               /system_real/etc/ubuntu-gsi/display-mode \
               /system/etc/ubuntu-gsi/display-mode; do
        if [ -f "$_dm" ]; then
            DISPLAY_MODE=$(tr -d " \t\r\n" <"$_dm")
            break
        fi
    done
fi
_a2=/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android2.so.15
if [ "$DISPLAY_MODE" = "lower-layer" ]; then
    mkdir -p /data/local/tmp 2>/dev/null || true
    touch /data/local/tmp/lomiri_disable_android2 2>/dev/null || true
    mkdir -p /data/uhl_overlay 2>/dev/null || true
    touch /data/uhl_overlay/lomiri_disable_android2 2>/dev/null || true
    if [ -z "${UBUNTU_GSI_GPU_MODE:-}" ]; then
        export UBUNTU_GSI_GPU_MODE=llvmpipe
    fi
    # Disable Mir android2 even if device_prep already ran
    if [ -e "$_a2" ]; then
        echo not_a_shared_object > /data/local/tmp/android2_disabled.so 2>/dev/null || true
        umount "$_a2" 2>/dev/null || true
        mount --bind /data/local/tmp/android2_disabled.so "$_a2" 2>/dev/null \
            && echo "android2_disabled=yes (start-lomiri)" >&2 \
            || echo "android2_disable_bind_failed" >&2
    fi
else
    # HWC production path: undo lower-layer stubs so android2 can load
    rm -f /data/local/tmp/lomiri_disable_android2 /data/uhl_overlay/lomiri_disable_android2 2>/dev/null || true
    umount "$_a2" 2>/dev/null || true
    if [ "${UBUNTU_GSI_GPU_MODE:-}" = "llvmpipe" ] && [ ! -f /data/local/tmp/ubuntu-gsi-force-llvmpipe ]; then
        unset UBUNTU_GSI_GPU_MODE || true
    fi
    echo "android2_enabled=yes (display-mode=$DISPLAY_MODE)" >&2
fi
echo "DISPLAY_MODE=$DISPLAY_MODE" >&2

detect_gpu_mode
apply_gpu_env
symlink_vendor_gpu_libs
# Writable aliases for RO vendor SONAME mismatches (e.g. libpq_cust.so).
ALIAS_DIR="${HYBRIS_ALIAS_DIR:-/tmp/hybris-alias}"
mkdir -p "$ALIAS_DIR"
if [ ! -e "$ALIAS_DIR/libpq_cust.so" ]; then
  # Device-agnostic SONAME fix: any vendor arch tree with libpq_cust_base.so
  _pq_found=""
  for cand in \
      "${VENDOR_ROOT}/${ANDROID_ARCH}"/*/libpq_cust_base.so \
      "${VENDOR_ROOT}/${ANDROID_ARCH}/libpq_cust_base.so"; do
    if [ -f "$cand" ]; then
      _pq_found="$cand"
      break
    fi
  done
  if [ -n "$_pq_found" ]; then
    ln -sfn "$_pq_found" "$ALIAS_DIR/libpq_cust.so"
  fi
fi
# Halium android-side Mir HWC2/UI compat (loaded via hybris android_dlopen).
# Only alias known compat shims — linking every *.so under COMPAT_SRC into
# HYBRIS_LD_LIBRARY_PATH shadows real /system libui/libnativewindow and aborts
# Lomiri (missing GraphicBufferMapper::sLock / linker Load CHECK).
COMPAT_SRC=""
for _cd in \
    "${HYBRIS_COMPAT_DIR:-}" \
    /usr/lib/ubuntu-gsi/halium-compat \
    /data/uhl_overlay/halium-compat \
    /data/local/tmp/halium13-compat \
    /data/local/tmp; do
    [ -n "$_cd" ] || continue
    if [ -d "$_cd" ]; then
        COMPAT_SRC="$_cd"
        break
    fi
done
[ -n "$COMPAT_SRC" ] || COMPAT_SRC=/data/local/tmp
for compat_name in libui_compat_layer.so libhwc2_compat_layer.so; do
  if [ -f "$COMPAT_SRC/$compat_name" ]; then
    ln -sfn "$COMPAT_SRC/$compat_name" "$ALIAS_DIR/$compat_name"
  fi
done
# libui_lock_shim intentionally omitted: it exports GraphicBufferMapper::lock/unlock
# without sLock and can break libnativewindow resolution.
# Guarantee real Android libui for libnativewindow (GraphicBufferMapper::sLock).
for ui in /system_real/lib64/libui.so /system/lib64/libui.so; do
  if [ -f "$ui" ]; then
    ln -sfn "$ui" "$ALIAS_DIR/libui.so"
    break
  fi
done
export HYBRIS_LD_LIBRARY_PATH="${ALIAS_DIR}:$(build_hybris_ld_path)"
# Do not prepend ALIAS_DIR to LD_LIBRARY_PATH — that breaks Ubuntu-side
# resolution of Android libui/libnativewindow (GraphicBufferMapper symbols).

# Prefer Mesa/hybris EGL platform name Mir understands.
# "hwcomposer" is valid for libhybris eglplatform; keep it for egl_hybris.
# Zig/non-Debian libhybris-common defaults to /usr/lib/libhybris/linker;
# UBports packages install under the multiarch path.
export HYBRIS_LINKER_DIR="${HYBRIS_LINKER_DIR:-/usr/lib/aarch64-linux-gnu/libhybris/linker}"

if [ "${LIBHYBRIS_DEBUG:-0}" = "1" ]; then
    export LIBHYBRIS_DEBUG=1
fi

mkdir -p "$ANDROID_DATA" /run/user/32011

# -----------------------------------------------------------------------------
# Vendor properties — Lomiri/Mir read getprop indirectly via libhybris.
# Apply the compat-engine snapshot so PHH-style toggles are in effect.
# -----------------------------------------------------------------------------
if [ -x /usr/lib/ubuntu-gsi/compat/compat-engine.sh ]; then
    /usr/lib/ubuntu-gsi/compat/compat-engine.sh linux-mode || true
fi

# HAL: enumerate → capability router (kernel-first, one-shot AIDL probe)
# Prefer overlay path; fall back to /data/uhl_overlay (writable on overlay whiteouts).
_hal_router=""
for _cand in \
    /usr/lib/ubuntu-gsi/hal-capability-router.sh \
    /data/uhl_overlay/ubuntu-gsi-bin/hal-capability-router.sh \
    /data/local/tmp/hal-capability-router.sh; do
    if [ -x "$_cand" ]; then
        _hal_router="$_cand"
        break
    fi
done
if [ -n "$_hal_router" ]; then
    "$_hal_router" || true
else
    # Legacy fallback if router not installed yet
    if [ -x /usr/lib/ubuntu-gsi/wifi-bringup.sh ]; then
        /usr/lib/ubuntu-gsi/wifi-bringup.sh || true
    fi
    if [ -x /usr/lib/ubuntu-gsi/hal-kernel-bringup.sh ]; then
        /usr/lib/ubuntu-gsi/hal-kernel-bringup.sh || true
    fi
    if [ -x /usr/lib/ubuntu-gsi/hal-aidl-probe.sh ]; then
        /usr/lib/ubuntu-gsi/hal-aidl-probe.sh || true
    fi
fi

# Lazy GPU prep: reclaim DRM from Android SF/composer only when Lomiri needs it.
_hal_gpu=""
for _cand in \
    /usr/lib/ubuntu-gsi/hal-gpu-bringup.sh \
    /data/uhl_overlay/ubuntu-gsi-bin/hal-gpu-bringup.sh \
    /data/local/tmp/hal-gpu-bringup.sh; do
    if [ -x "$_cand" ]; then
        _hal_gpu="$_cand"
        break
    fi
done
if [ -n "$_hal_gpu" ]; then
    HYBRIS_COMPAT_DIR="${COMPAT_SRC:-}" "$_hal_gpu" lomiri_prep || true
    echo "[start-lomiri] hal_gpu_prep=done script=$_hal_gpu" >&2
else
    echo "[start-lomiri] hal_gpu_prep=missing" >&2
fi
unset _hal_router _hal_gpu _cand


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

log_sl() {
    if [ -x /system_real/bin/log ]; then
        /system_real/bin/log -t start-lomiri "$*" 2>/dev/null || true
    fi
    echo "[start-lomiri] $*" >&2
}

# Lomiri UITK scale: short side ≈ 60 gu. No QT_SCALE_FACTOR.
setup_grid_unit_px() {
    if [ -n "${GRID_UNIT_PX:-}" ]; then
        export GRID_UNIT_PX
        log_sl "display_scale GRID_UNIT_PX=$GRID_UNIT_PX (env override)"
        return 0
    fi
    local width height mode short=0 grid=18 detected=0
    local target_gu=60
    for connector in /sys/class/drm/card*-*/modes; do
        [ -f "$connector" ] || continue
        # Skip writeback/virtual sinks (can report huge unused modes).
        case "$connector" in
            *Writeback*|*Virtual*) continue ;;
        esac
        mode=$(head -1 "$connector" 2>/dev/null) || continue
        [ -n "$mode" ] || continue
        width=$(printf '%s' "$mode" | cut -d'x' -f1)
        height=$(printf '%s' "$mode" | cut -d'x' -f2 | tr -cd '0-9')
        case "$width" in (*[!0-9]*|'') continue ;; esac
        case "$height" in (*[!0-9]*|'') continue ;; esac
        short=$width
        if [ "$height" -lt "$width" ]; then
            short=$height
        fi
        detected=1
        # round(short / target_gu)
        grid=$(( (short + target_gu / 2) / target_gu ))
        if [ "$grid" -lt 8 ]; then
            grid=8
        elif [ "$grid" -gt 48 ]; then
            grid=48
        fi
        break
    done
    if [ "$detected" -eq 0 ]; then
        grid=18
        short=0
    fi
    export GRID_UNIT_PX=$grid
    log_sl "display_scale short=${short} target_gu=${target_gu} GRID_UNIT_PX=$GRID_UNIT_PX"
}
setup_grid_unit_px
# Morph/WebEngine DPR ≈ GRID_UNIT_PX / 8 (UITK default is 8 px/gu).
if [ -z "${QTWEBKIT_DPR:-}" ] && [ -n "${GRID_UNIT_PX:-}" ]; then
    QTWEBKIT_DPR=$(awk -v g="$GRID_UNIT_PX" 'BEGIN { printf "%.1f", g / 8 }')
    export QTWEBKIT_DPR
fi
log_sl "display_scale QTWEBKIT_DPR=${QTWEBKIT_DPR:-unset}"

log_sl "DISPLAY_MODE=${DISPLAY_MODE:-} GPU_MODE=${GPU_MODE:-} EGL_PLATFORM=${EGL_PLATFORM:-} LIBEGL=${LIBEGL:-} MIR_SERVER_GRAPHICS_PLATFORM=${MIR_SERVER_GRAPHICS_PLATFORM:-unset} bin=$LOMIRI_BIN"
log_sl "HYBRIS_LD_LIBRARY_PATH=$HYBRIS_LD_LIBRARY_PATH"
log_sl "ui_compat=$(readlink -f "$ALIAS_DIR/libui_compat_layer.so" 2>/dev/null || echo missing)"
# Lazy in-process HAL present (soft hotplug unchanged). Default off for regression safety.
if [ "${HWC2_STUB_HAL_PRESENT:-0}" = "1" ] || [ -f /data/local/tmp/lomiri_hal_present ]; then
    export HWC2_STUB_HAL_PRESENT=1
    export HWC2_STUB_HAL_CALLBACK=1
    export HWC2_STUB_BL_MAX=1
    # Avoid vendor setPowerMode → MTK disp notifier → Novatek FD touch storm.
    export HWC2_STUB_SKIP_VENDOR_POWER=1
    log_sl "HWC2_STUB_HAL_PRESENT=1 HWC2_STUB_HAL_CALLBACK=1 HWC2_STUB_BL_MAX=1 HWC2_STUB_SKIP_VENDOR_POWER=1"
fi

# Mir input-evdev enumerates via udev. Android has no /run/udev — seed a minimal
# database so touchscreens/keys are opened (otherwise lomiri has zero /dev/input fds).
ensure_mir_input_udev() {
    mkdir -p /run/udev/data /run/udev/tags/seat /run/udev/tags/uaccess || true
    chmod a+rw /dev/input/event* 2>/dev/null || true
    # Start udevd BEFORE seeding so libinput's first probe does not wait ~60s.
    if ! pidof systemd-udevd >/dev/null 2>&1 && ! pidof udevd >/dev/null 2>&1; then
        if command -v /lib/systemd/systemd-udevd >/dev/null 2>&1; then
            /lib/systemd/systemd-udevd --daemon 2>/data/local/tmp/udevd.log || true
        elif command -v udevd >/dev/null 2>&1; then
            udevd --daemon 2>/data/local/tmp/udevd.log || true
        fi
        sleep 0.3
    fi
    # Clear stuck MT slots (driver often leaves ABS_MT_SLOT=max → libevdev "double tracking ID").
    if [ -e /dev/input/event3 ]; then
        for slot in 0 1 2 3 4 5 6 7 8 9; do
            sendevent /dev/input/event3 3 47 "$slot" 2>/dev/null || true
            sendevent /dev/input/event3 3 57 4294967295 2>/dev/null || true
        done
        sendevent /dev/input/event3 1 330 0 2>/dev/null || true
        sendevent /dev/input/event3 0 0 0 2>/dev/null || true
    fi
    now_us=$(($(date +%s) * 1000000))
    for node in /dev/input/event*; do
        [ -e "$node" ] || continue
        base=$(basename "$node")
        minor=
        if [ -e "/sys/class/input/$base/dev" ]; then
            minor=$(cut -d: -f2 "/sys/class/input/$base/dev")
        else
            n=${base#event}
            minor=$((64 + n))
        fi
        name=$(cat "/sys/class/input/$base/device/name" 2>/dev/null || echo "$base")
        sys_path=$(readlink -f "/sys/class/input/$base" 2>/dev/null || true)
        devpath=${sys_path#/sys}
        li_group=
        if [ -n "$sys_path" ] && [ -x /usr/lib/udev/libinput-device-group ]; then
            # helper prints "LIBINPUT_DEVICE_GROUP=..."; strip key for E: line
            li_group=$(/usr/lib/udev/libinput-device-group "$sys_path" 2>/dev/null | sed 's/^LIBINPUT_DEVICE_GROUP=//' || true)
        fi
        f="/run/udev/data/c13:${minor}"
        {
            # Full libudev db shape (I:/G:/TAGS) — Mir/libinput need seat + touchscreen.
            echo "I:$now_us"
            echo "N: input/$base"
            echo "E:DEVNAME=/dev/input/$base"
            echo "E:DEVPATH=$devpath"
            echo "E:MAJOR=13"
            echo "E:MINOR=$minor"
            echo "E:SUBSYSTEM=input"
            echo "E:ID_INPUT=1"
            echo "E:ID_SEAT=seat0"
            echo "E:ID_FOR_SEAT=input-event-$base"
            echo "E:TAGS=:seat:uaccess:"
            echo "E:CURRENT_TAGS=:seat:uaccess:"
            echo "G:seat"
            echo "G:uaccess"
            case "$name" in
                *Touch*|*touch*|*NVT*|*Goodix*|*gt9*|*fts*)
                    # Needed so libinput_path_add_device accepts the node. Mir 1.8 then
                    # sets mapping_mode_to_output with output_id=0; we bind a patched
                    # input-evdev.so that makes is_output_active() always true.
                    echo "E:ID_INPUT_TOUCHSCREEN=1"
                    echo "E:ID_INPUT_WIDTH_MM=70"
                    echo "E:ID_INPUT_HEIGHT_MM=112"
                    ;;
                *)
                    echo "E:ID_INPUT_KEY=1"
                    ;;
            esac
            if [ -n "$li_group" ]; then
                echo "E:LIBINPUT_DEVICE_GROUP=$li_group"
            fi
        } >"$f"
        ln -sfn "../../data/c13:${minor}" "/run/udev/tags/seat/c13:${minor}" 2>/dev/null || true
        ln -sfn "../../data/c13:${minor}" "/run/udev/tags/uaccess/c13:${minor}" 2>/dev/null || true
    done
    # Keep GSI touchscreen tags; Mir output mapping fixed via patched input-evdev.so.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload 2>/dev/null || true
        udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true
        udevadm settle --timeout=3 2>/dev/null || true
    fi
    # Restore rules if previously disabled for experiments
    if [ -f /etc/udev/rules.d/70-ubuntu-gsi-input.rules.off ] && [ ! -f /etc/udev/rules.d/70-ubuntu-gsi-input.rules ]; then
        mv /etc/udev/rules.d/70-ubuntu-gsi-input.rules.off /etc/udev/rules.d/70-ubuntu-gsi-input.rules 2>/dev/null || true
    fi
    _n=$(ls /run/udev/data/c13:* 2>/dev/null | wc -l || true)
    log_sl "udev input seed entries=${_n:-0}"
}
ensure_mir_input_udev

# System bus required for AccountsService / Mir logind probes (session bus alone is not enough).
ensure_system_dbus() {
    mkdir -p /run/dbus /var/run/dbus 2>/dev/null || true
    if [ ! -S /run/dbus/system_bus_socket ]; then
        if command -v dbus-daemon >/dev/null 2>&1; then
            dbus-daemon --system --fork --nopidfile --nosyslog 2>/data/local/tmp/dbus-sys.err || true
        fi
    fi
    if [ -S /run/dbus/system_bus_socket ]; then
        log_sl "system_dbus=up"
    else
        log_sl "system_dbus=missing"
    fi
}
ensure_system_dbus

# Apps (System Settings, External Storage, …) talk to system-bus daemons that
# systemd would normally start. Without PID1 systemd, launch them directly.
ensure_system_bus_services() {
    if [ ! -S /run/dbus/system_bus_socket ]; then
        log_sl "system_bus_services=skip (no system dbus)"
        return 0
    fi
    if ! pidof upowerd >/dev/null 2>&1; then
        if [ -x /usr/libexec/upowerd ]; then
            /usr/libexec/upowerd >/data/local/tmp/upowerd.log 2>&1 &
        elif [ -x /usr/lib/upower/upowerd ]; then
            /usr/lib/upower/upowerd >/data/local/tmp/upowerd.log 2>&1 &
        fi
    fi
    if ! pidof udisksd >/dev/null 2>&1; then
        if [ -x /usr/lib/udisks2/udisksd ]; then
            /usr/lib/udisks2/udisksd >/data/local/tmp/udisksd.log 2>&1 &
        fi
    fi
    sleep 0.3
    log_sl "system_bus_services upowerd=$(pidof upowerd || echo none) udisksd=$(pidof udisksd || echo none)"
}
ensure_system_bus_services

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
mkdir -p "$XDG_RUNTIME_DIR"
# Wayland compositors reject clients when the runtime dir is world-writable.
chmod 700 "$XDG_RUNTIME_DIR"
# Stale sockets from prior crashed Mir confuse clients.
rm -f "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/wayland-*.lock 2>/dev/null || true
umask 0077
log_sl "xdg_runtime_dir=$XDG_RUNTIME_DIR mode=$(stat -c %a "$XDG_RUNTIME_DIR" 2>/dev/null)"

# Chromium/QtWebEngine/Firefox need POSIX shm; Halium chroot often lacks it.
if [ ! -d /dev/shm ]; then
    mkdir -p /dev/shm
fi
if ! mountpoint -q /dev/shm 2>/dev/null; then
    mount -t tmpfs -o mode=1777,nosuid,nodev,size=256m shm /dev/shm 2>/dev/null \
        || log_sl "dev_shm_mount_failed"
fi
chmod 1777 /dev/shm 2>/dev/null || true
log_sl "dev_shm=$(stat -c %a /dev/shm 2>/dev/null) mount=$(mountpoint -q /dev/shm && echo yes || echo no)"

# Firefox re-exec drops --desktop_file_hint; qtmir SessionAuthorizer then
# rejects Wayland. Keep ELF as firefox.real/firefox.elf; optional PATH shim.
# MUST NOT abort start-lomiri (set -e): a broken firefox path previously left
# the panel black with backlight off because Lomiri never exec'd.
ensure_firefox_mir_hint_shim() {
    local ff=/usr/lib/firefox/firefox
    local ff_bin=/usr/lib/firefox/firefox.bin
    local ff_real=/usr/lib/firefox/firefox.real
    local ff_elf=/usr/lib/firefox/firefox.elf
    local elf=""
    is_elf() {
        [ -f "$1" ] && [ ! -d "$1" ] && \
            [ "$(wc -c <"$1" 2>/dev/null || echo 0)" -gt 10000 ] && \
            head -c 4 "$1" 2>/dev/null | od -An -tx1 | grep -q "7f 45 4c 46"
    }
    # Overlay sometimes leaves a directory where the binary should be.
    if [ -d "$ff" ]; then
        log_sl "firefox_mir_hint_shim=firefox_is_dir removing"
        rm -rf "$ff" 2>/dev/null || {
            log_sl "firefox_mir_hint_shim=dir_remove_failed"
            return 0
        }
    fi
    for c in "$ff_real" "$ff_elf" "$ff_bin" "$ff"; do
        if is_elf "$c"; then
            elf=$c
            break
        fi
    done
    if [ -z "$elf" ]; then
        log_sl "firefox_mir_hint_shim=missing_elf"
        return 0
    fi
    if ! is_elf "$ff_elf"; then
        cp -f "$elf" "$ff_elf" 2>/dev/null || true
        chmod 755 "$ff_elf" 2>/dev/null || true
    fi
    if [ -d "$ff_real" ]; then
        rm -rf "$ff_real" 2>/dev/null || true
    fi
    if ! is_elf "$ff_real"; then
        cp -f "$ff_elf" "$ff_real" 2>/dev/null || cp -f "$elf" "$ff_real" 2>/dev/null || true
        chmod 755 "$ff_real" 2>/dev/null || true
    fi
    if [ -d "$ff_bin" ]; then
        rm -rf "$ff_bin" 2>/dev/null || true
    fi
    if ! is_elf "$ff_bin"; then
        cp -f "$ff_real" "$ff_bin" 2>/dev/null || true
        chmod 755 "$ff_bin" 2>/dev/null || true
    fi
    if [ -f "$ff" ] && head -c 2 "$ff" 2>/dev/null | grep -q '#!' && is_elf "$ff_real"; then
        log_sl "firefox_mir_hint_shim=already elf=$(wc -c <"$ff_real" 2>/dev/null || echo 0)"
        return 0
    fi
    # If $ff is still the only ELF and copies failed, do not clobber it.
    if is_elf "$ff" && ! is_elf "$ff_real"; then
        log_sl "firefox_mir_hint_shim=skip_clobber_sole_elf"
        return 0
    fi
    if ! printf '%s\n' '#!/bin/sh' \
        'HINT=--desktop_file_hint=/usr/share/applications/firefox.desktop' \
        'for a in "$@"; do' \
        '  case "$a" in --desktop_file_hint=*) HINT=; break;; esac' \
        'done' \
        'ELF=/usr/lib/firefox/firefox.real' \
        '[ -x "$ELF" ] || ELF=/usr/lib/firefox/firefox.elf' \
        '[ -x "$ELF" ] || ELF=/usr/lib/firefox/firefox.bin' \
        'if [ -n "$HINT" ]; then' \
        '  exec "$ELF" "$HINT" "$@"' \
        'else' \
        '  exec "$ELF" "$@"' \
        'fi' >"$ff" 2>/dev/null; then
        log_sl "firefox_mir_hint_shim=write_failed"
        return 0
    fi
    chmod 755 "$ff" 2>/dev/null || true
    log_sl "firefox_mir_hint_shim=installed elf=$(wc -c <"$ff_real" 2>/dev/null || echo 0)"
    return 0
}
ensure_firefox_mir_hint_shim || true

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ ! -S "${XDG_RUNTIME_DIR}/bus" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        eval "$(dbus-launch --sh-syntax)"
        log_sl "dbus-launch $DBUS_SESSION_BUS_ADDRESS"
    elif command -v dbus-daemon >/dev/null 2>&1; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile \
            || log_sl "dbus-daemon failed"
        log_sl "dbus-daemon $DBUS_SESSION_BUS_ADDRESS"
    else
        log_sl "no dbus-launch/dbus-daemon in chroot"
    fi
fi

# Ayatana indicators pick Lomiri backends via XDG_CURRENT_DESKTOP (e.g. keyboard
# uses libayatana-keyboard-lomiri instead of X11 — without this it aborts).
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-Lomiri}"
export DESKTOP_SESSION="${DESKTOP_SESSION:-lomiri}"

# lomiri-app-launch needs org.freedesktop.systemd1 on the session bus.
# Real systemd --user refuses when PID1 is Android init — provide a spawn stub.
ensure_ual_systemd_stub() {
    # Prefer runtime override, then rootfs-bundled stub.
    local stub_src=""
    if [ -f /data/local/tmp/ual_systemd_stub.py ]; then
        stub_src="/data/local/tmp/ual_systemd_stub.py"
    elif [ -f /usr/lib/ubuntu-gsi/ual_systemd_stub.py ]; then
        stub_src="/usr/lib/ubuntu-gsi/ual_systemd_stub.py"
    else
        log_sl "ual_systemd_stub missing (tmp and /usr/lib/ubuntu-gsi)"
        return 0
    fi
    local stub="/tmp/ual_systemd_stub.py"
    cp -f "$stub_src" "$stub" 2>/dev/null || stub="$stub_src"
    chmod 755 "$stub" 2>/dev/null || true
    # Qt LibGL → EGL_OPENGL_BIT rewrite shim for Wayland apps (Mali is ES-only).
    if [ -f /data/local/tmp/libegl_es2_force.so ]; then
        cp -f /data/local/tmp/libegl_es2_force.so /tmp/libegl_es2_force.so 2>/dev/null || true
        chmod 755 /tmp/libegl_es2_force.so 2>/dev/null || true
    fi
    if [ -f /data/local/tmp/libfirefox_execve_hint.so ]; then
        cp -f /data/local/tmp/libfirefox_execve_hint.so /tmp/libfirefox_execve_hint.so 2>/dev/null || true
        chmod 755 /tmp/libfirefox_execve_hint.so 2>/dev/null || true
    elif [ -f /usr/lib/ubuntu-gsi/libfirefox_execve_hint.so ]; then
        cp -f /usr/lib/ubuntu-gsi/libfirefox_execve_hint.so /tmp/libfirefox_execve_hint.so 2>/dev/null || true
        chmod 755 /tmp/libfirefox_execve_hint.so 2>/dev/null || true
    fi
    # Rejected: libff_shm_xrgb.so caused Firefox SIGSEGV + Lomiri crash loops.
    rm -f /tmp/libff_shm_xrgb.so 2>/dev/null || true
    # Drop any prior stub
    kill $(pidof -x ual_systemd_stub.py) 2>/dev/null || true
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
    /usr/bin/python3 "$stub" >/data/local/tmp/ual_systemd_stub.log 2>&1 &
    _stub_pid=$!
    # Brief settle only — dbus-send NameHasOwner can hang on a wedged session bus.
    sleep 0.5
    if kill -0 "$_stub_pid" 2>/dev/null; then
        _stub_gup="missing"
        if [ -r "/proc/$_stub_pid/environ" ]; then
            _stub_gup=$(tr '\0' '\n' <"/proc/$_stub_pid/environ" 2>/dev/null | sed -n 's/^GRID_UNIT_PX=//p' | head -1)
            _stub_gup=${_stub_gup:-missing}
        fi
        log_sl "ual_systemd_stub=up pid=$_stub_pid src=$stub_src GRID_UNIT_PX=${_stub_gup} expect=${GRID_UNIT_PX:-}"
    else
        log_sl "ual_systemd_stub=failed (see /data/local/tmp/ual_systemd_stub.log)"
        cat /data/local/tmp/ual_systemd_stub.log 2>/dev/null | tail -20 >&2 || true
    fi
}
ensure_ual_systemd_stub

# Lomiri panel indicators need session-bus services. Stock path uses
# systemd --user (ayatana-indicators.target); we have no user systemd here,
# so spawn the same ExecStart binaries as the user units (like maliit).
ensure_indicators() {
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
    export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-Lomiri}"
    export DESKTOP_SESSION="${DESKTOP_SESSION:-lomiri}"
    if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
        export HOME=/root
    fi

    # Sound / power backends (best-effort; skip if already running)
    if command -v pulseaudio >/dev/null 2>&1; then
        if ! pgrep -x pulseaudio >/dev/null 2>&1; then
            pulseaudio --start --exit-idle-time=-1 2>/dev/null \
                || pulseaudio -D --exit-idle-time=-1 2>/dev/null \
                || true
            log_sl "indicator_deps pulseaudio=$(pgrep -x pulseaudio >/dev/null 2>&1 && echo up || echo missing)"
        fi
    fi
    if ! pgrep -x upowerd >/dev/null 2>&1; then
        if [ -x /usr/libexec/upowerd ]; then
            /usr/libexec/upowerd >/data/local/tmp/upowerd.log 2>&1 &
            log_sl "indicator_deps upowerd=spawned pid=$!"
        elif command -v upowerd >/dev/null 2>&1; then
            upowerd >/data/local/tmp/upowerd.log 2>&1 &
            log_sl "indicator_deps upowerd=spawned pid=$!"
        fi
    fi

    # WiFi secret-agent needs org.freedesktop.secrets (gnome-keyring).
    # Without it: "Error calling StartServiceByName … Timeout" and connect hangs.
    if [ -x /usr/bin/gnome-keyring-daemon ] && ! pgrep -f gnome-keyring-daemon >/dev/null 2>&1; then
        mkdir -p /root/.local/share/keyrings /root/.cache 2>/dev/null || true
        mkdir -m 0700 -p "${XDG_RUNTIME_DIR:-/run/user/0}/keyring" 2>/dev/null || true
        # --login is incompatible with --start; secrets component only.
        /usr/bin/gnome-keyring-daemon --start --foreground \
            --components=secrets >/data/local/tmp/gnome-keyring.log 2>&1 &
        log_sl "indicator_deps gnome-keyring=spawned pid=$!"
        sleep 1
    fi
    # Rewrite secrets activation to avoid systemd --user dependency.
    mkdir -p /usr/share/dbus-1/services
    cat >/usr/share/dbus-1/services/org.freedesktop.secrets.service <<'SECRETS'
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=/usr/bin/gnome-keyring-daemon --start --foreground --components=secrets
SECRETS

    # URLDispatcher stock unit uses SystemdService= → ChildExited under Android PID1.
    _urld=/usr/lib/aarch64-linux-gnu/lomiri-url-dispatcher/lomiri-url-dispatcher
    cat >/usr/share/dbus-1/services/com.lomiri.URLDispatcher.service <<'URLD'
[D-BUS Service]
Name=com.lomiri.URLDispatcher
Exec=/usr/lib/aarch64-linux-gnu/lomiri-url-dispatcher/lomiri-url-dispatcher
AssumedAppArmorLabel=unconfined
URLD
    if [ -x "$_urld" ] && ! pgrep -f lomiri-url-dispatcher >/dev/null 2>&1; then
        "$_urld" >/data/local/tmp/url-dispatcher.log 2>&1 &
        log_sl "indicator_deps url_dispatcher=spawned pid=$!"
    fi

    # connectivity1: stock Exec=/bin/false + SystemdService= — rewrite for dbus activation
    mkdir -p /usr/share/dbus-1/services
    cat >/usr/share/dbus-1/services/com.lomiri.connectivity1.service <<'DBUS'
[D-BUS Service]
Name=com.lomiri.connectivity1
Exec=/usr/libexec/lomiri-indicator-network/lomiri-indicator-network-service
DBUS

    _spawn_ind() {
        # $1=log_tag $2=pgrep_pattern $3=binary [args...]
        local tag="$1" pat="$2" bin="$3"
        shift 3 || true
        if [ ! -x "$bin" ]; then
            log_sl "indicator_${tag}=missing_binary"
            return 0
        fi
        if pgrep -f "$pat" >/dev/null 2>&1; then
            log_sl "indicator_${tag}=already_running"
            return 0
        fi
        "$bin" "$@" >/data/local/tmp/indicator-${tag}.log 2>&1 &
        log_sl "indicator_${tag}=spawned pid=$!"
    }

    # rotation-lock is provided by ayatana-indicator-display
    _spawn_ind display \
        ayatana-indicator-display-service \
        /usr/libexec/ayatana-indicator-display/ayatana-indicator-display-service
    _spawn_ind keyboard \
        ayatana-indicator-keyboard-service \
        /usr/libexec/ayatana-indicator-keyboard/ayatana-indicator-keyboard-service
    _spawn_ind datetime \
        ayatana-indicator-datetime-service \
        /usr/libexec/ayatana-indicator-datetime/ayatana-indicator-datetime-service
    _spawn_ind power \
        ayatana-indicator-power-service \
        /usr/libexec/ayatana-indicator-power/ayatana-indicator-power-service
    _spawn_ind sound \
        ayatana-indicator-sound-service \
        /usr/libexec/ayatana-indicator-sound/ayatana-indicator-sound-service
    _spawn_ind session \
        ayatana-indicator-session-service \
        /usr/libexec/ayatana-indicator-session/ayatana-indicator-session-service
    _spawn_ind transfer \
        'indicator-transfer/indicator-transfer-service' \
        /usr/lib/aarch64-linux-gnu/indicator-transfer/indicator-transfer-service
    _spawn_ind network \
        lomiri-indicator-network-service \
        /usr/libexec/lomiri-indicator-network/lomiri-indicator-network-service
    _spawn_ind network_agent \
        lomiri-indicator-network-secret-agent \
        /usr/libexec/lomiri-indicator-network/lomiri-indicator-network-secret-agent

    unset -f _spawn_ind

    # Light WiFi reclaim only (full wifi-bringup already ran in router).
    # Android init may restart wificond — stop it without another 0/1/S cycle.
    setprop ctl.stop wificond 2>/dev/null || true
    stop wificond 2>/dev/null || true
    killall -9 wificond 2>/dev/null || true
    if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
        if [ -x /usr/lib/ubuntu-gsi/wifi-bringup.sh ]; then
            /usr/lib/ubuntu-gsi/wifi-bringup.sh >/data/local/tmp/wifi-bringup-reassert.log 2>&1 || true
        elif [ -x /data/uhl_overlay/ubuntu-gsi-bin/wifi-bringup.sh ]; then
            /data/uhl_overlay/ubuntu-gsi-bin/wifi-bringup.sh >/data/local/tmp/wifi-bringup-reassert.log 2>&1 || true
        fi
        log_sl "wifi_reassert_full=$(tail -1 /data/local/tmp/wifi-bringup-reassert.log 2>/dev/null | tr -d '\r')"
    else
        log_sl "wifi_reassert_light wpa=up wificond=$(getprop init.svc.wificond 2>/dev/null)"
    fi
}
ensure_indicators || true

# Keep Android policy routing from blocking Ubuntu apps (netd may re-add
# "from all unreachable"). Re-apply periodically while Lomiri is up.
ensure_halium_app_net_watch() {
    _net=""
    for _cand in \
        /usr/lib/ubuntu-gsi/halium-app-net.sh \
        /data/uhl_overlay/ubuntu-gsi-bin/halium-app-net.sh; do
        if [ -x "$_cand" ]; then
            _net="$_cand"
            break
        fi
    done
    [ -n "$_net" ] || return 0
    # One immediate fix, then watchdog.
    "$_net" >/data/local/tmp/halium-app-net.log 2>&1 || true
    if [ -f /data/local/tmp/halium-app-net-watch.pid ]; then
        _old=$(cat /data/local/tmp/halium-app-net-watch.pid 2>/dev/null || true)
        if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
            log_sl "halium_app_net_watch=already_running pid=$_old"
            return 0
        fi
    fi
    (
        while true; do
            "$_net" >/dev/null 2>&1 || true
            sleep 12
        done
    ) >/data/local/tmp/halium-app-net-watch.log 2>&1 &
    echo $! >/data/local/tmp/halium-app-net-watch.pid
    log_sl "halium_app_net_watch=started pid=$! script=$_net"
}
ensure_halium_app_net_watch || true

# Soft keyboard (lomiri-keyboard via maliit). No systemd --user here, so start
# it ourselves as a Wayland client of Lomiri (not a second mirserver).
# UT ships only libmaliitphabletplatforminputcontextplugin.so — not "maliit".
ensure_maliit_osk() {
    export QT_IM_MODULE=maliitphablet
    export GTK_IM_MODULE=Maliit
    if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
        export HOME=/root
    fi
    # Maliit subview id is "en" (lomiri-keyboard plugins/en). Stock xdg conf
    # only enables en_us/en_gb → '"en" is not enabled' and no usable layout.
    mkdir -p /root/.config/maliit.org /.config/maliit.org /etc/xdg/maliit.org
    cat > /root/.config/maliit.org/server.conf <<'MCFG'
[maliit]
onscreen\active=liblomiri-keyboard-plugin.so:en
onscreen\enabled=liblomiri-keyboard-plugin.so:en
pluginsettings\liblomiri-keyboard-plugin.so\current_style=lomiri
pluginsettings\liblomiri-keyboard-plugin.so\word_engine_enabled=false
MCFG
    cp -f /root/.config/maliit.org/server.conf /.config/maliit.org/server.conf 2>/dev/null || true
    cp -f /root/.config/maliit.org/server.conf /etc/xdg/maliit.org/server.conf 2>/dev/null || true
    if pidof maliit-server >/dev/null 2>&1; then
        log_sl "maliit_osk=already_running"
        return 0
    fi
    if [ ! -x /usr/bin/maliit-server ]; then
        log_sl "maliit_osk=missing_binary"
        return 0
    fi
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gsettings >/dev/null 2>&1; then
        gsettings set com.lomiri.keyboard.maliit enabled-languages "['en','emoji']" 2>/dev/null || true
        gsettings set com.lomiri.keyboard.maliit active-language 'en' 2>/dev/null || true
        gsettings set com.lomiri.keyboard.maliit stay-hidden false 2>/dev/null || true
        gsettings set com.lomiri.keyboard.maliit plugin-paths "['/usr/lib/lomiri-keyboard/plugins/']" 2>/dev/null || true
    fi
    cat > /tmp/start_maliit_osk.sh <<'MEOF'
#!/bin/bash
# Wait until Lomiri owns the Wayland socket, then start maliit as a client.
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
    export HOME=/root
fi
for _ in $(seq 1 60); do
    if [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ] && pidof lomiri >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
export QT_IM_MODULE=maliitphablet
export GTK_IM_MODULE=Maliit
export QT_QPA_PLATFORM=wayland
export QML_BAD_GUI_RENDER_LOOP=1
export HFD_USE_PRIVILEGED_INTERFACE=1
# Wayland client GPU (NOT hwcomposer — that yields EGL_BAD_CONFIG / no OSK surface).
export EGL_PLATFORM=wayland
export HYBRIS_EGLPLATFORM=wayland
export QT_OPENGL=es2
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_libhybris.json
# Do not inherit Mir server inject; use client hybris GLES preload like UAL apps.
unset LD_PRELOAD
unset MIR_SERVER_CONSOLE_PROVIDER
_preload=""
[ -f /tmp/libegl_es2_force.so ] && _preload="/tmp/libegl_es2_force.so"
[ -f /usr/lib/aarch64-linux-gnu/libGLESv2_libhybris.so.2 ] && \
  _preload="${_preload:+$_preload:}/usr/lib/aarch64-linux-gnu/libGLESv2_libhybris.so.2"
[ -n "$_preload" ] && export LD_PRELOAD="$_preload"
# qtmir keeps mir_window_type_inputmethod ONLY when the process is
# genuinely /usr/bin/maliit-server (checks exe/argv). Never rewrite argv0.
# SessionAuthorizer accepts DESKTOP_FILE_HINT from the environment.
_desk=/tmp/maliit-keyboard.desktop
cat > "$_desk" <<'DESK'
[Desktop Entry]
Name=Maliit Keyboard
Exec=/usr/bin/maliit-server
Type=Application
X-Lomiri-Touch=true
DESK
export DESKTOP_FILE_HINT="$_desk"
exec /usr/bin/maliit-server -allow-anonymous
MEOF
    chmod 755 /tmp/start_maliit_osk.sh
    /tmp/start_maliit_osk.sh >/data/local/tmp/maliit.log 2>&1 &
    log_sl "maliit_osk=spawned pid=$! QT_IM_MODULE=$QT_IM_MODULE"
}
ensure_maliit_osk || true

# Do not sudo -u ubuntu: /run/user/32011/bus is never started, so lomiri
# exits cleanly (no tombstone). Root + session bus is the first-boot path.
# This Lomiri build rejects --mode=full-shell ("unrecognised option").
log_sl "exec $LOMIRI_BIN as uid=$(id -u) (no --mode)"
# Warm vendor/hybris EGL so Mir's early config probe sees WINDOW+ES2 configs.
for _wu in \
    /usr/lib/ubuntu-gsi/halium-compat/egl_warmup \
    /data/uhl_overlay/halium-compat/egl_warmup \
    /data/local/tmp/egl_warmup \
    /tmp/egl_warmup; do
    if [ -x "$_wu" ]; then
        cp -f "$_wu" /tmp/egl_warmup 2>/dev/null || true
        break
    fi
done
if [ -x /tmp/egl_warmup ]; then
    # Keep LD_PRELOAD unset during warmup/heal — it breaks Android toybox (sendevent).
    /tmp/egl_warmup >/tmp/egl_warmup.log 2>&1 || true
    log_sl "egl_warmup done ($(wc -c </tmp/egl_warmup.log 2>/dev/null || echo 0)b)"
fi

# NEVER unbind/bind NVT here — rebind can leave SPI reading zeros
# ("chip is not identified", probe -22) until a full reboot.
_fd=$(dmesg 2>/dev/null | grep -c 'Recover for fw reset' || true)
_ev3=missing
[ -e /dev/input/event3 ] && _ev3=present
log_sl "nvt_snapshot fd=${_fd:-0} event3=$_ev3 (no rebind)"

# Ensure android_wlegl global is advertised when Mir binds Wayland EGL.
# Never export LD_PRELOAD into this shell: Android toybox helpers (log/sendevent)
# cannot load Linux-only .so deps and will abort before exec.
if [ -f /data/local/tmp/libwlegl_inject.so ]; then
    cp -f /data/local/tmp/libwlegl_inject.so /tmp/libwlegl_inject.so 2>/dev/null || true
    chmod 755 /tmp/libwlegl_inject.so 2>/dev/null || true
fi
# Optional OSK InputMethod force (must be glibc-compatible with rootfs).
if [ -f /data/local/tmp/libmaliit_im_force.so ]; then
    cp -f /data/local/tmp/libmaliit_im_force.so /tmp/libmaliit_im_force.so 2>/dev/null || true
    chmod 755 /tmp/libmaliit_im_force.so 2>/dev/null || true
fi
_lomiri_preload=""
# Only preload maliit_im_force if it resolves against rootfs libc (else lomiri aborts).
if [ -f /tmp/libmaliit_im_force.so ] && \
   /usr/bin/ldd /tmp/libmaliit_im_force.so >/tmp/maliit_im_force.ldd 2>&1 && \
   ! grep -q "not found" /tmp/maliit_im_force.ldd && \
   ! grep -q "version .* not found" /tmp/maliit_im_force.ldd; then
    _lomiri_preload="/tmp/libmaliit_im_force.so"
    log_sl "maliit_im_force=enabled"
else
    log_sl "maliit_im_force=skipped (incompatible with rootfs libc)"
fi
[ -f /tmp/libwlegl_inject.so ] && \
    _lomiri_preload="${_lomiri_preload:+$_lomiri_preload:}/tmp/libwlegl_inject.so"
if [ -n "${LD_PRELOAD:-}" ]; then
    _lomiri_preload="${_lomiri_preload:+$_lomiri_preload:}$LD_PRELOAD"
fi
log_sl "exec $LOMIRI_BIN preload=${_lomiri_preload:-none}"
if [ -n "$_lomiri_preload" ]; then
    exec env LD_PRELOAD="$_lomiri_preload" "$LOMIRI_BIN"
fi
exec "$LOMIRI_BIN"

