#!/system/bin/sh
# Android-side NVT keepalive — wake panel + storm recovery after Lomiri exec.
# Started from ubuntu-gsi-touch-prep auto_finish (survives exec into chroot).
set -eu

LOG=/data/local/tmp/nvt-keepalive.log
# Opt-in debug trace log (formerly debug-63ebe6.log). Set UBUNTU_GSI_DEBUG_TRACE=1 to enable.
UBUNTU_GSI_DEBUG_TRACE_LOG=${UBUNTU_GSI_DEBUG_TRACE_LOG:-/data/local/tmp/ubuntu-gsi-debug-trace.log}
NVT_EV=/dev/input/event3
HEAL=/data/local/tmp/heal_nvt_touch.sh
[ -x "$HEAL" ] || HEAL=/system/usr/share/ubuntu-gsi/heal_nvt_touch.sh

# #region agent log
dbg_log() {
    [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ] || return 0
    _hyp=$1 _loc=$2 _msg=$3 _data=$4
    _ts=$(date +%s%3N 2>/dev/null || date +%s)
    printf '%s\n' \
        "{\"sessionId\":\"63ebe6\",\"hypothesisId\":\"$_hyp\",\"location\":\"$_loc\",\"message\":\"$_msg\",\"data\":$_data,\"timestamp\":$_ts}" \
        >>"$UBUNTU_GSI_DEBUG_TRACE_LOG" 2>/dev/null || true
}
# #endregion

checksum_count() {
    _n=$(dmesg 2>/dev/null | grep -c 'nvt_ts_point_data_checksum' 2>/dev/null || true)
    case "$_n" in (''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

irq_delta_1s() {
    _i1=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    sleep 1
    _i2=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    case "$_i1" in (''|*[!0-9]*) _i1=0 ;; esac
    case "$_i2" in (''|*[!0-9]*) _i2=0 ;; esac
    printf '%s' "$((_i2 - _i1))"
}

storm_active_now() {
    _csd=$1
    _irq=$2
    # IRQ-only: dmesg checksum wrap yields negative cs_delta and false "calm".
    if [ "$_irq" -gt 40 ] 2>/dev/null; then
        return 0
    fi
    case "$_csd" in
        -*) _csd=${_csd#-} ;;
    esac
    if [ "$_csd" -gt 20 ] 2>/dev/null; then
        return 0
    fi
    if [ "$_csd" -gt 5 ] 2>/dev/null && [ "$_irq" -gt 30 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

wake_panel() {
    /system/bin/svc power stayon true 2>/dev/null || true
    /system/bin/settings put system screen_off_timeout 2147483647 2>/dev/null || true
    # Wake only — avoid KEYCODE_POWER (26) which toggles display / NVT.
    /system/bin/input keyevent 224 2>/dev/null || true
}

touch_has_events() {
    _ge=/data/local/tmp/keepalive-probe.txt
    : >"$_ge"
    timeout 1 getevent -lt "$NVT_EV" >>"$_ge" 2>&1 || true
    _n=$(wc -l <"$_ge" 2>/dev/null || echo 0)
    [ "$_n" -gt 0 ] 2>/dev/null
}

run_heal_post_mir() {
    [ -x "$HEAL" ] || return 1
    NVT_HEAL_POST_MIR=1 NVT_HEAL_SKIP_FINGER=1 NVT_WAKE_DISABLE=0 \
        "$HEAL" >>/data/local/tmp/heal-nvt-keepalive.log 2>&1 || true
    if touch_has_events; then
        echo "[keepalive] touch_recovered cycle=$_cycle" >>"$LOG"
        dbg_log "H4" "keepalive:recovered" "touch events seen" "{\"cycle\":$_cycle}"
        return 0
    fi
    return 1
}

echo "[keepalive] start pid=$$ ts=$(date 2>/dev/null || echo ?)" >>"$LOG"
wake_panel
dbg_log "H1" "keepalive:start" "daemon started" "{\"pid\":$$}"

_prev=$(checksum_count)
_cycle=0
_calm=0
while [ "$_cycle" -lt 480 ]; do
    sleep 15
    _now=$(checksum_count)
    _delta=$((_now - _prev))
    _prev=$_now
    _irq=$(irq_delta_1s)
    wake_panel

    if storm_active_now "$_delta" "$_irq"; then
        _calm=0
        echo "[keepalive] cs_delta=$_delta irq=$_irq total=$_now cycle=$_cycle (wake only)" >>"$LOG"
        dbg_log "H5" "keepalive:wake_only" "storm active" "{\"delta\":$_delta,\"irq\":$_irq,\"total\":$_now}"
    elif [ "$_delta" -le 20 ] 2>/dev/null; then
        _calm=$((_calm + 1))
        if [ "$_calm" -ge 2 ] 2>/dev/null; then
            echo "[keepalive] cs_delta=$_delta irq=$_irq cycle=$_cycle (storm subsided, heal)" >>"$LOG"
            dbg_log "H2" "keepalive:heal" "storm subsided" "{\"delta\":$_delta,\"irq\":$_irq}"
            run_heal_post_mir || true
            _calm=0
        else
            echo "[keepalive] cs_delta=$_delta irq=$_irq cycle=$_cycle (calm $_calm/2)" >>"$LOG"
        fi
    else
        _calm=0
        echo "[keepalive] cs_delta=$_delta irq=$_irq cycle=$_cycle (moderate)" >>"$LOG"
    fi
    _cycle=$((_cycle + 1))
done
