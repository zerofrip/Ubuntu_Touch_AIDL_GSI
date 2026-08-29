#!/system/bin/sh
# =============================================================================
# hal-gpu-bringup.sh — Device-agnostic GPU/HWC prep (lazy, low power)
# =============================================================================
# Modes:
#   chmod_only   — DRM/fb permissions only (boot-safe, cheap)
#   lomiri_prep  — reclaim DRM from SurfaceFlinger/composer; optional HWC patch
#
# Invoked from start-lomiri.sh (lomiri_prep) or optionally from the router
# (chmod_only). No SoC name hardcoding. Failures are non-fatal.
# =============================================================================

set -u
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:${PATH:-}"

LOG_TAG="hal-gpu-bringup"
MODE="${1:-lomiri_prep}"
STATUS_DIR="${HAL_STATUS_DIR:-/run/ubuntu-gsi/hal-status}"
ONCE_FLAG="${HAL_GPU_PREP_ONCE:-$STATUS_DIR/gpu_lomiri_prep.done}"
COMPAT_DIR="${HYBRIS_COMPAT_DIR:-}"

log() { echo "[$LOG_TAG] $*" >&2; }

pick_status_dir() {
    if mkdir -p "$STATUS_DIR" 2>/dev/null; then
        return 0
    fi
    for d in /data/uhl_overlay/hal-status /tmp/ubuntu-gsi-hal-status; do
        if mkdir -p "$d" 2>/dev/null; then
            STATUS_DIR="$d"
            return 0
        fi
    done
}

pick_status_dir
ONCE_FLAG="${HAL_GPU_PREP_ONCE:-$STATUS_DIR/gpu_lomiri_prep.done}"

write_status() {
    _prep="$1"
    _detail="${2:-}"
    {
        echo "path=hybris"
        echo "status=bridged"
        echo "prep=$_prep"
        echo "detail=$_detail"
        echo "updated=$(date -Iseconds 2>/dev/null || date)"
    } >"$STATUS_DIR/display_gpu" 2>/dev/null || true
}

resolve_compat_dir() {
    if [ -n "$COMPAT_DIR" ] && [ -d "$COMPAT_DIR" ]; then
        return 0
    fi
    for d in \
        /usr/lib/ubuntu-gsi/halium-compat \
        /mnt/halium/merged/usr/lib/ubuntu-gsi/halium-compat \
        /data/uhl_overlay/halium-compat \
        /data/local/tmp/halium13-compat \
        /data/local/tmp; do
        if [ -d "$d" ]; then
            COMPAT_DIR="$d"
            return 0
        fi
    done
    COMPAT_DIR="/data/local/tmp"
}

chmod_drm() {
    for dri in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$dri" ] || continue
        chmod 0666 "$dri" 2>/dev/null || true
    done
    for fb in /dev/graphics/fb* /dev/fb*; do
        [ -e "$fb" ] || continue
        chmod 0666 "$fb" 2>/dev/null || true
    done
}

drm_is_busy() {
    _busy=0
    for c in /dev/dri/card*; do
        [ -e "$c" ] || continue
        if command -v fuser >/dev/null 2>&1; then
            if fuser "$c" >/dev/null 2>&1; then
                _busy=1
                break
            fi
        else
            # Without fuser, assume busy if surfaceflinger exists
            pidof surfaceflinger >/dev/null 2>&1 && _busy=1
            break
        fi
    done
    [ "$_busy" = "1" ]
}

stop_android_display_stack() {
    stop surfaceflinger 2>/dev/null || true

    # Stop running init services whose names look like display/composer/PQ.
    if command -v getprop >/dev/null 2>&1 && command -v stop >/dev/null 2>&1; then
        getprop 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                \[init.svc.*\]:\ \[running\])
                    svc=$(printf '%s' "$line" | sed -n 's/^\[init\.svc\.\([^]]*\)\]:.*/\1/p')
                    case "$svc" in
                        surfaceflinger|*composer*|*pq_aidl*|*pq@*)
                            stop "$svc" 2>/dev/null || true
                            ;;
                    esac
                    ;;
            esac
        done
    fi

    # One /proc pass for leftover composer / SF / PQ processes (version-agnostic).
    for cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        _c=$(tr '\0' ' ' <"$cmdline" 2>/dev/null || true)
        case "$_c" in
            *surfaceflinger*|*graphics.composer*|*hwcomposer*|*hardware.pq*)
                _pid=${cmdline#/proc/}
                _pid=${_pid%/cmdline}
                kill -9 "$_pid" 2>/dev/null || true
                ;;
        esac
    done
}

apply_optional_hwc_patch() {
    resolve_compat_dir
    BIND_SRC=
    for cand in \
        "$COMPAT_DIR/hwc_inproc.so" \
        "$COMPAT_DIR/hwc_patched.so" \
        /data/local/tmp/hwc_inproc.so \
        /data/local/tmp/hwc_patched.so; do
        if [ -f "$cand" ]; then
            BIND_SRC="$cand"
            break
        fi
    done
    [ -n "$BIND_SRC" ] || {
        log "hwc_patch=skipped (no inproc/patched blob)"
        return 0
    }

    TARGET=
    for t in /vendor/lib64/hw/hwcomposer.*.so /vendor/lib/hw/hwcomposer.*.so; do
        [ -f "$t" ] || continue
        # Prefer *.mtk_common / primary hwcomposer if present, else first match
        case "$(basename "$t")" in
            hwcomposer.default.so) TARGET="$t"; break ;;
        esac
        [ -z "$TARGET" ] && TARGET="$t"
    done
    # Prefer mtk_common when present without hardcoding as sole target
    for t in /vendor/lib64/hw/hwcomposer.*.so /vendor/lib/hw/hwcomposer.*.so; do
        [ -f "$t" ] || continue
        case "$(basename "$t")" in
            *mtk_common*) TARGET="$t"; break ;;
        esac
    done
    [ -n "$TARGET" ] || {
        log "hwc_patch=skipped (no hwcomposer.*.so)"
        return 0
    }

    i=0
    while [ "$i" -lt 6 ]; do
        umount "$TARGET" 2>/dev/null || break
        i=$((i + 1))
    done
    if mount -o bind "$BIND_SRC" "$TARGET" 2>/dev/null; then
        log "hwc_patch_bound=yes src=$(basename "$BIND_SRC") target=$(basename "$TARGET")"
    elif cp -f "$BIND_SRC" "$TARGET" 2>/dev/null; then
        log "hwc_patch_copied=yes src=$(basename "$BIND_SRC") target=$(basename "$TARGET")"
    else
        log "hwc_patch=failed target=$TARGET"
        return 1
    fi
    return 0
}

configure_android2() {
    A2=/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android2.so.15
    [ -e "$A2" ] || A2=/mnt/halium/merged/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android2.so.15
    [ -e "$A2" ] || return 0

    OVERRIDE_MODE=
    [ -f /data/local/tmp/ubuntu-gsi-display-mode ] && \
        OVERRIDE_MODE=$(tr -d ' \t\r\n' </data/local/tmp/ubuntu-gsi-display-mode)
    DISPLAY_MODE_FILE=/system/etc/ubuntu-gsi/display-mode
    [ -f /etc/ubuntu-gsi/display-mode ] && DISPLAY_MODE_FILE=/etc/ubuntu-gsi/display-mode
    EFFECTIVE_MODE=hwc
    if [ -n "${UBUNTU_GSI_DISPLAY_MODE:-}" ]; then
        EFFECTIVE_MODE=$(printf '%s' "$UBUNTU_GSI_DISPLAY_MODE" | tr -d ' \t\r\n')
    elif [ -n "$OVERRIDE_MODE" ]; then
        EFFECTIVE_MODE=$OVERRIDE_MODE
    elif [ -f "$DISPLAY_MODE_FILE" ]; then
        EFFECTIVE_MODE=$(tr -d ' \t\r\n' <"$DISPLAY_MODE_FILE")
    fi

    if [ "$EFFECTIVE_MODE" = "lower-layer" ]; then
        mkdir -p /data/local/tmp 2>/dev/null || true
        echo not_a_shared_object >/data/local/tmp/android2_disabled.so 2>/dev/null || true
        umount "$A2" 2>/dev/null || true
        mount -o bind /data/local/tmp/android2_disabled.so "$A2" 2>/dev/null \
            && log "android2_disabled=yes" \
            || log "android2_disable_failed"
    else
        umount "$A2" 2>/dev/null || true
        rm -f /data/local/tmp/lomiri_disable_android2 /data/uhl_overlay/lomiri_disable_android2 2>/dev/null || true
        log "android2_enabled=yes mode=$EFFECTIVE_MODE"
    fi
}

# --- modes ---
case "$MODE" in
    chmod_only)
        chmod_drm
        write_status skipped "chmod_only"
        log "mode=chmod_only done"
        exit 0
        ;;
    lomiri_prep) ;;
    *)
        log "unknown mode=$MODE (use chmod_only|lomiri_prep)"
        MODE=lomiri_prep
        ;;
esac

# lomiri_prep: once per boot unless forced
if [ "${HAL_GPU_FORCE:-0}" != "1" ] && [ -f "$ONCE_FLAG" ]; then
    if ! drm_is_busy; then
        write_status skipped "already_prepared drm_free"
        log "mode=lomiri_prep skip (once flag, drm free)"
        exit 0
    fi
    log "once flag set but drm busy — re-running prep"
fi

setenforce 0 2>/dev/null || true
chmod_drm
configure_android2

_prep="done"
_detail="lomiri_prep"

if drm_is_busy || pidof surfaceflinger >/dev/null 2>&1; then
    stop_android_display_stack
    sleep 1
    stop_android_display_stack
    sleep 1
    _detail="${_detail} sf_reclaim"
else
    log "drm already free — skip composer/sf stop"
    _detail="${_detail} drm_already_free"
fi

if apply_optional_hwc_patch; then
    :
else
    _prep="partial"
    _detail="${_detail} hwc_patch_failed"
fi

chmod_drm
mkdir -p "$(dirname "$ONCE_FLAG")" 2>/dev/null || true
: >"$ONCE_FLAG" 2>/dev/null || true

_sf=$(pidof surfaceflinger 2>/dev/null || echo none)
_drm_busy=no
drm_is_busy && _drm_busy=yes
write_status "$_prep" "${_detail} sf=${_sf} drm_busy=${_drm_busy}"
log "mode=lomiri_prep prep=$_prep sf=$_sf drm_busy=$_drm_busy"
exit 0

