#!/system/bin/sh
# Shared NVT/Mir touch prep for auto-start (ubuntu-gsi-launcher) and manual debug
# (run_chroot_lomiri.sh). Runs on the Android side before Lomiri exec.
#
# Usage:
#   ubuntu-gsi-touch-prep.sh pre_pivot <OVERLAY_MERGED>
#   ubuntu-gsi-touch-prep.sh gpu_prep
#   ubuntu-gsi-touch-prep.sh auto_finish   # auto-start (no finger gate)
#   ubuntu-gsi-touch-prep.sh gate_touch    # manual diagnosis (finger required)
#
# Exit: 0 ok, 2 storm, 3 dead touch, 4 mt stuck, 5 suspended, 1 usage/missing
set -eu

# Prefer userdata hotfix (persists across reboot without re-flashing system.img).
_uhl_prep=/data/local/tmp/ubuntu-gsi-touch-prep.sh
if [ -f "$_uhl_prep" ] && [ "$0" != "$_uhl_prep" ]; then
    exec "$_uhl_prep" "$@"
fi
unset _uhl_prep

bind_heal_hotfix() {
    _h=/data/local/tmp/heal_nvt_touch.sh
    _dst=/system/usr/share/ubuntu-gsi/heal_nvt_touch.sh
    if [ -f "$_h" ] && [ -f "$_dst" ]; then
        mount --bind "$_h" "$_dst" 2>/dev/null || true
    fi
}
bind_heal_hotfix

LOG_TAG="ubuntu-gsi-touch-prep"
FAIL_LOG=/data/local/tmp/touch-prep-fail.log
HEAL_LOG=/data/local/tmp/heal-nvt-touch-prep.log
# Opt-in debug trace log (formerly debug-63ebe6.log). Set UBUNTU_GSI_DEBUG_TRACE=1 to enable.
UBUNTU_GSI_DEBUG_TRACE_LOG=${UBUNTU_GSI_DEBUG_TRACE_LOG:-/data/local/tmp/ubuntu-gsi-debug-trace.log}

log() {
    /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null || true
    echo "[$LOG_TAG] $*" >&2
    echo "[$LOG_TAG] $*" >>"$FAIL_LOG" 2>/dev/null || true
}

fail_touch() {
    _rc=$1
    _msg=$2
    log "FAIL rc=$_rc: $_msg"
    setprop persist.ubuntu_gsi.failed 1 2>/dev/null || true
    exit "$_rc"
}

export_hwc2_stub_env() {
    touch /data/local/tmp/lomiri_hal_present 2>/dev/null || true
    export HWC2_STUB_HAL_PRESENT=1
    export HWC2_STUB_HAL_CALLBACK=1
    export HWC2_STUB_BL_MAX=1
    export HWC2_STUB_SKIP_VENDOR_POWER=1
    log "HWC2_STUB exported (SKIP_VENDOR_POWER=1)"
}

nvt_irq_delta_1s() {
    _i1=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    sleep 1
    _i2=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    case "$_i1" in (''|*[!0-9]*) _i1=0 ;; esac
    case "$_i2" in (''|*[!0-9]*) _i2=0 ;; esac
    printf '%s' "$((_i2 - _i1))"
}

nvt_checksum_count() {
    _n=$(dmesg 2>/dev/null | grep -c 'nvt_ts_point_data_checksum' 2>/dev/null || true)
    case "$_n" in (''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

nvt_storm_active() {
    _cs=$(nvt_checksum_count)
    _delta=$(nvt_irq_delta_1s)
    # Match heal_nvt_touch.sh: storm = high IRQ *and* checksum spam, or extreme checksum alone.
    if [ "$_cs" -gt 50 ] 2>/dev/null && [ "$_delta" -gt 30 ] 2>/dev/null; then
        return 0
    fi
    if [ "$_cs" -gt 500 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

find_heal() {
    for _p in \
        /data/local/tmp/heal_nvt_touch.sh \
        /system/usr/share/ubuntu-gsi/heal_nvt_touch.sh; do
        if [ -x "$_p" ]; then
            printf '%s' "$_p"
            return 0
        fi
    done
    return 1
}

run_heal() {
    _heal=$(find_heal) || {
        log "heal script missing — skipping NVT checks"
        return 0
    }
    : >"$HEAL_LOG"
    "$_heal" >>"$HEAL_LOG" 2>&1
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        log "heal ok $(tail -1 "$HEAL_LOG" 2>/dev/null)"
        return 0
    fi
    log "heal failed rc=$_rc"
    cat "$HEAL_LOG" >>"$FAIL_LOG" 2>/dev/null || true
    return "$_rc"
}

apply_file_patch() {
    _src=$1
    _dst=$2
    _label=$3
    [ -f "$_src" ] || return 0
    [ -f "$_dst" ] || {
        log "$_label dst missing $_dst"
        return 0
    }
    cp -f "$_src" "$_dst" 2>/dev/null \
        || /system/bin/mount --bind "$_src" "$_dst" 2>/dev/null \
        || mount --bind "$_src" "$_dst" 2>/dev/null \
        || true
    log "$_label applied src=$_src"
}

apply_mir_patches() {
    _merged=$1
    _q_dst="$_merged/usr/lib/aarch64-linux-gnu/libhybris/linker/q.so"
    _c_dst="$_merged/usr/lib/aarch64-linux-gnu/libhybris-common.so.1.0.0"
    _q_src=""
    _c_src=""
    for _d in /system/usr/share/ubuntu-gsi/libhybris-tls \
        /data/uhl_overlay/halium-compat /data/local/tmp; do
        [ -z "$_q_src" ] && [ -f "$_d/q-tls.so" ] && _q_src="$_d/q-tls.so"
        [ -z "$_q_src" ] && [ -f "$_d/q.so" ] && [ "$(basename "$_d")" = "libhybris-tls" ] && _q_src="$_d/q.so"
        [ -z "$_c_src" ] && [ -f "$_d/libhybris-common-tls.so" ] && _c_src="$_d/libhybris-common-tls.so"
        [ -z "$_c_src" ] && [ -f "$_d/libhybris-common.so.1.0.0" ] \
            && [ "$(basename "$_d")" = "libhybris-tls" ] && _c_src="$_d/libhybris-common.so.1.0.0"
    done
    if [ -n "$_q_src" ] && [ -n "$_c_src" ]; then
        apply_file_patch "$_q_src" "$_q_dst" "hybris_tls"
        apply_file_patch "$_c_src" "$_c_dst" "hybris_common"
    else
        log "hybris TLS missing — Lomiri may abort on TLSDESC"
    fi

    _a2_dst="$_merged/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android2.so.15"
    _a2_src=""
    for _d in /system/usr/share/ubuntu-gsi/mir-patches \
        /data/uhl_overlay/halium-compat /data/local/tmp; do
        [ -f "$_d/graphics-android2.so.15" ] && _a2_src="$_d/graphics-android2.so.15" && break
    done
    apply_file_patch "$_a2_src" "$_a2_dst" "mir_android2"

    _ev_dst="$_merged/usr/lib/aarch64-linux-gnu/mir/server-platform/input-evdev.so.7"
    _ev_src=""
    for _d in /system/usr/share/ubuntu-gsi/mir-patches \
        /data/uhl_overlay/halium-compat /data/local/tmp; do
        [ -f "$_d/input-evdev.so.7" ] && _ev_src="$_d/input-evdev.so.7" && break
    done
    apply_file_patch "$_ev_src" "$_ev_dst" "mir_input_evdev"

    _tk_dst="$_merged/usr/lib/aarch64-linux-gnu/libLomiriToolkit.so.5.5.0"
    _tk_src=""
    for _d in /data/uhl_overlay/halium-compat /data/local/tmp \
        "$_merged/usr/lib/ubuntu-gsi/halium-compat"; do
        [ -f "$_d/libLomiriToolkit.so.5.5.0" ] && _tk_src="$_d/libLomiriToolkit.so.5.5.0" && break
    done
    apply_file_patch "$_tk_src" "$_tk_dst" "lomiri_toolkit"
}

apply_hwc_patch() {
    _merged=$1
    _src=""
    for _d in /data/uhl_overlay/halium-compat /data/local/tmp \
        /system/usr/lib/ubuntu-gsi/halium-compat; do
        [ -f "$_d/hwc_patched.so" ] && _src="$_d/hwc_patched.so" && break
        [ -f "$_d/hwc_inproc.so" ] && _src="$_d/hwc_inproc.so" && break
    done
    _tgt=""
    for _t in "$_merged"/vendor/lib64/hw/hwcomposer.*.so; do
        [ -f "$_t" ] || continue
        case "$(basename "$_t")" in *mtk_common*) _tgt="$_t"; break ;; esac
        [ -z "$_tgt" ] && _tgt="$_t"
    done
    if [ -n "$_src" ] && [ -n "$_tgt" ]; then
        /system/bin/mount --bind "$_src" "$_tgt" 2>/dev/null \
            || mount --bind "$_src" "$_tgt" 2>/dev/null || true
        log "hwc patch applied src=$_src tgt=$_tgt"
    fi
}

cmd_pre_pivot() {
    _merged=$1
    [ -d "$_merged" ] || fail_touch 1 "merged tree missing: $_merged"
    : >"$FAIL_LOG"
    rm -f /data/local/tmp/touch-prep-gate-ok 2>/dev/null || true
    log "pre_pivot merged=$_merged"
    export_hwc2_stub_env
    touch /data/local/tmp/lomiri_hal_present 2>/dev/null || true
    apply_mir_patches "$_merged"
    apply_hwc_patch "$_merged"
    log "pre_pivot=ok"
}

cmd_gpu_prep() {
    export HAL_GPU_FORCE=1
    export_hwc2_stub_env
    bind_heal_hotfix
    _hal_gpu=""
    for _cand in \
        /data/uhl_overlay/ubuntu-gsi-bin/hal-gpu-bringup.sh \
        /data/local/tmp/hal-gpu-bringup.sh \
        /system/usr/share/ubuntu-gsi/hal-gpu-bringup.sh; do
        if [ -x "$_cand" ]; then
            _hal_gpu="$_cand"
            break
        fi
    done
    if [ -z "$_hal_gpu" ]; then
        log "gpu_prep=missing (continuing)"
        return 0
    fi
    HYBRIS_COMPAT_DIR="${COMPAT_SRC:-}" /bin/sh "$_hal_gpu" lomiri_prep || true
    log "gpu_prep=done script=$_hal_gpu"
}

nvt_resume_count() {
    _n=$(dmesg 2>/dev/null | grep -cE \
        'nvt_ts_resume 2623: end|nvt_ts_resume 2591: Touch is already resume' 2>/dev/null || true)
    case "$_n" in (''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

nvt_suspend_count() {
    _n=$(dmesg 2>/dev/null | grep -c 'nvt_ts_suspend 2521: start' 2>/dev/null || true)
    case "$_n" in (''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

nvt_wake_display() {
    _svc=/system/bin/svc
    [ -x "$_svc" ] || _svc=svc
    _input=/system/bin/input
    [ -x "$_input" ] || _input=input
    $_svc power stayon true 2>/dev/null || true
    # Wake only — NEVER keyevent 26 (POWER): it toggles display and leaves
    # NVT/panel in a state where the next HWC setPower races into FD SPI storm.
    $_input keyevent 224 2>/dev/null || true
}

wait_nvt_resume() {
    _max=${NVT_RESUME_WAIT_SEC:-120}
    _base=$(nvt_resume_count)
    _sus=$(nvt_suspend_count)

    if nvt_storm_active; then
        log "nvt_storm=active before resume wait"
        return 1
    fi

    nvt_wake_display
    # Post-gpu: if resume count already exceeds suspend and no storm, panel is up.
    if [ "$_base" -gt "$_sus" ] 2>/dev/null; then
        sleep 2
        if ! nvt_storm_active; then
            log "nvt_resume=stable base=$_base sus=$_sus (no storm)"
            return 0
        fi
        log "nvt_storm=detected despite res>sus"
        return 1
    fi

    _i=0
    while [ "$_i" -lt "$_max" ]; do
        _now=$(nvt_resume_count)
        if [ "$_now" -gt "$_base" ] 2>/dev/null; then
            log "nvt_resume=seen wait_s=$_i base=$_base now=$_now"
            return 0
        fi
        if dmesg 2>/dev/null | tail -30 | grep -q \
            'nvt_irq_enable 181: enable=1, desc->depth=0'; then
            log "nvt_irq=enabled wait_s=$_i"
            return 0
        fi
        if nvt_storm_active; then
            log "nvt_storm=started during resume wait wait_s=$_i"
            return 1
        fi
        sleep 1
        _i=$((_i + 1))
    done
    log "nvt_resume=timeout after ${_max}s (base=$_base now=$(nvt_resume_count))"
    return 1
}

start_nvt_keepalive() {
    _keepalive=/data/local/tmp/ubuntu-gsi-nvt-keepalive.sh
    [ -x "$_keepalive" ] || _keepalive=/system/usr/share/ubuntu-gsi/ubuntu-gsi-nvt-keepalive.sh
    if [ -x "$_keepalive" ]; then
        if pgrep -f ubuntu-gsi-nvt-keepalive >/dev/null 2>&1; then
            log "nvt_keepalive=already_running"
            unset _keepalive
            return 0
        fi
        /system/bin/sh "$_keepalive" >>/data/local/tmp/nvt-keepalive.log 2>&1 &
        log "nvt_keepalive=started pid=$!"
        # #region agent log
        if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
            _ts=$(date +%s%3N 2>/dev/null || date +%s)
            printf '%s\n' \
                "{\"sessionId\":\"63ebe6\",\"hypothesisId\":\"H3\",\"location\":\"touch-prep:keepalive\",\"message\":\"started\",\"data\":{\"pid\":$!},\"timestamp\":$_ts}" \
                >>"$UBUNTU_GSI_DEBUG_TRACE_LOG" 2>/dev/null || true
        fi
        # #endregion
    fi
    unset _keepalive
}

# #region agent log
# Cold-boot HWC present immediately after suspend storms (H40 rejected for
# short/45s settle). Two-phase open/callback→present under test as H43/H44.
# Disabled by default until logs prove calm; set NVT_HWC_PREWARM=1 to enable.
nvt_hwc_prewarm() {
    [ "${NVT_HWC_PREWARM:-0}" = "1" ] || {
        log "nvt_prewarm=skipped (NVT_HWC_PREWARM!=1)"
        return 0
    }
    _dbg="$UBUNTU_GSI_DEBUG_TRACE_LOG"
    _probe=/data/local/tmp/halium13-compat/hwc2_present_probe
    _compat=/data/local/tmp/halium13-compat
    _inproc=""
    for _d in /data/uhl_overlay/halium-compat /data/local/tmp \
        /system/usr/lib/ubuntu-gsi/halium-compat; do
        [ -f "$_d/hwc_inproc.so" ] && _inproc="$_d/hwc_inproc.so" && break
    done
    _hwc=/vendor/lib64/hw/hwcomposer.mtk_common.so
    _sample_irq() {
        _a=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
        sleep 1
        _b=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
        case "$_a" in (''|*[!0-9]*) _a=0 ;; esac
        case "$_b" in (''|*[!0-9]*) _b=0 ;; esac
        printf '%s' "$((_b - _a))"
    }
    _irq=$(_sample_irq)
    if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
        _ts=$(date +%s%3N 2>/dev/null || date +%s)
        printf '%s\n' \
            "{\"sessionId\":\"63ebe6\",\"runId\":\"prewarm\",\"hypothesisId\":\"H43\",\"location\":\"touch-prep:prewarm_before\",\"message\":\"irq_1s\",\"data\":{\"irq\":$_irq},\"timestamp\":$_ts}" \
            >>"$_dbg" 2>/dev/null || true
    fi
    if [ ! -x "$_probe" ] || [ -z "$_inproc" ] || [ ! -f "$_hwc" ]; then
        log "nvt_prewarm=skip missing probe/inproc"
        return 0
    fi
    sleep 2
    mount --bind "$_inproc" "$_hwc" 2>/dev/null || true
    cp -f /apex/com.android.vndk.v34/lib64/android.hardware.graphics.common-V4-ndk.so \
        "$_compat/" 2>/dev/null || true
    export LD_LIBRARY_PATH="$_compat:/vendor/lib64:/vendor/lib64/hw:/system/lib64"
    export HWC2_STUB_HAL_PRESENT=1 HWC2_STUB_HAL_CALLBACK=1 HWC2_STUB_BL_MAX=1
    export HWC2_STUB_SKIP_VENDOR_POWER=1
    export HWC2_STUB_HAL_STEP=open,callback
    "$_probe" callback >/data/local/tmp/nvt-prewarm-cb.log 2>&1 || true
    _irq=$(_sample_irq)
    if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
        _ts=$(date +%s%3N 2>/dev/null || date +%s)
        printf '%s\n' \
            "{\"sessionId\":\"63ebe6\",\"runId\":\"prewarm\",\"hypothesisId\":\"H43\",\"location\":\"touch-prep:prewarm_after_callback\",\"message\":\"irq_1s\",\"data\":{\"irq\":$_irq},\"timestamp\":$_ts}" \
            >>"$_dbg" 2>/dev/null || true
    fi
    sleep 2
    unset HWC2_STUB_HAL_STEP
    "$_probe" present >/data/local/tmp/nvt-prewarm-probe.log 2>&1 || true
    _i=0
    _storm=0
    while [ "$_i" -lt 8 ]; do
        _irq=$(_sample_irq)
        if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
            _ts=$(date +%s%3N 2>/dev/null || date +%s)
            printf '%s\n' \
                "{\"sessionId\":\"63ebe6\",\"runId\":\"prewarm\",\"hypothesisId\":\"H44\",\"location\":\"touch-prep:prewarm_after_present\",\"message\":\"irq_1s\",\"data\":{\"t\":$_i,\"irq\":$_irq},\"timestamp\":$_ts}" \
                >>"$_dbg" 2>/dev/null || true
        fi
        if [ "$_irq" -gt 40 ] 2>/dev/null; then
            _storm=1
        fi
        _i=$((_i + 1))
    done
    log "nvt_prewarm=done storm=$_storm (two-phase)"
    unset _dbg _probe _compat _inproc _hwc _a _b _irq _ts _i _storm _d
}
# #endregion

cmd_auto_finish() {
    log "auto_finish start (no finger gate)"
    export_hwc2_stub_env
    # Stay-on only; avoid POWER key toggle (H46 rejected as sole cause).
    /system/bin/svc power stayon true 2>/dev/null || true
    # H47: skip heal while NVT may be suspended after stop-android-ui —
    # sendevent/libinput on a suspended NVT correlated with post-resume FD storm.
    # Post-Mir heal still runs from start-lomiri.sh once Wayland is up.
    if [ "${NVT_AUTO_FINISH_HEAL:-0}" = "1" ]; then
        NVT_HEAL_POST_MIR=1 NVT_HEAL_SKIP_FINGER=1 NVT_WAKE_DISABLE=1 run_heal || log "heal warn (continuing)"
    else
        log "auto_finish_heal=skipped (NVT_AUTO_FINISH_HEAL!=1)"
    fi
    nvt_hwc_prewarm
    touch /data/local/tmp/touch-prep-gate-ok 2>/dev/null || true
    start_nvt_keepalive
    # #region agent log
    if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
        _a=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
        sleep 1
        _b=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
        case "$_a" in (''|*[!0-9]*) _a=0 ;; esac
        case "$_b" in (''|*[!0-9]*) _b=0 ;; esac
        _irq=$((_b - _a))
        _ts=$(date +%s%3N 2>/dev/null || date +%s)
        printf '%s\n' \
            "{\"sessionId\":\"63ebe6\",\"runId\":\"auto_finish\",\"hypothesisId\":\"H47\",\"location\":\"touch-prep:auto_finish\",\"message\":\"irq_1s_baseline\",\"data\":{\"irq\":$_irq},\"timestamp\":$_ts}" \
            >>"$UBUNTU_GSI_DEBUG_TRACE_LOG" 2>/dev/null || true
        unset _a _b _irq _ts
    fi
    # #endregion
    log "auto_finish=ok"
}

cmd_gate_touch() {
    log "gate_touch start (touch panel within 3s when prompted)"
    if ! wait_nvt_resume; then
        fail_touch 5 "NVT resume timeout — display handoff did not wake touch"
    fi
    export_hwc2_stub_env
    NVT_HEAL_SKIP_FINGER=0 NVT_WAKE_DISABLE=1 run_heal
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        fail_touch "$_rc" "touch gate failed (storm/dead/mt stuck)"
    fi
    touch /data/local/tmp/touch-prep-gate-ok 2>/dev/null || true
    log "gate_touch=ok"
    start_nvt_keepalive
}

MODE=${1:-}
case "$MODE" in
    pre_pivot)
        [ -n "${2:-}" ] || fail_touch 1 "usage: pre_pivot <OVERLAY_MERGED>"
        cmd_pre_pivot "$2"
        ;;
    gpu_prep)
        cmd_gpu_prep
        ;;
    auto_finish)
        cmd_auto_finish
        ;;
    gate_touch)
        cmd_gate_touch
        ;;
    full)
        [ -n "${2:-}" ] || fail_touch 1 "usage: full <OVERLAY_MERGED>"
        cmd_pre_pivot "$2"
        cmd_gpu_prep
        cmd_gate_touch
        ;;
    *)
        fail_touch 1 "usage: pre_pivot|gpu_prep|auto_finish|gate_touch|full"
        ;;
esac
