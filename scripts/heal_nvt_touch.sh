#!/system/bin/sh
# NVT touch health: SPI storm, MT slot stuck (double tracking ID), driver dead (no IRQ/events).
# Do NOT unbind/bind NVT-ts — rebind triggers novatek_ts_fw rewrite loops.
# Recovery for nvt_dead: reboot, then keep HWC2_STUB_SKIP_VENDOR_POWER=1.
setenforce 0 2>/dev/null || true
# Opt-in debug trace log (formerly debug-63ebe6.log). Set UBUNTU_GSI_DEBUG_TRACE=1 to enable.
UBUNTU_GSI_DEBUG_TRACE_LOG=${UBUNTU_GSI_DEBUG_TRACE_LOG:-/data/local/tmp/ubuntu-gsi-debug-trace.log}

clear_nvt_mt_slots() {
    _ev=$1
    [ -e "$_ev" ] || return 1
    _se=/system/bin/sendevent
    for _slot in 0 1 2 3 4 5 6 7 8 9; do
        $_se "$_ev" 3 47 "$_slot" 2>/dev/null || true
        $_se "$_ev" 3 57 4294967295 2>/dev/null || true
        $_se "$_ev" 3 48 0 2>/dev/null || true
        $_se "$_ev" 3 58 0 2>/dev/null || true
        $_se "$_ev" 3 53 0 2>/dev/null || true
        $_se "$_ev" 3 54 0 2>/dev/null || true
    done
    $_se "$_ev" 1 330 0 2>/dev/null || true
    $_se "$_ev" 3 47 0 2>/dev/null || true
    $_se "$_ev" 3 57 4294967295 2>/dev/null || true
    $_se "$_ev" 0 0 0 2>/dev/null || true
    return 0
}

NVT_EV=/dev/input/event3

nvt_count_dmesg() {
    _pat=$1
    _n=$(dmesg 2>/dev/null | grep -c "$_pat" 2>/dev/null || true)
    case "$_n" in (''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

nvt_irq_delta_1s() {
    _i1=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    sleep 1
    _i2=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    case "$_i1" in (''|*[!0-9]*) _i1=0 ;; esac
    case "$_i2" in (''|*[!0-9]*) _i2=0 ;; esac
    printf '%s' "$((_i2 - _i1))"
}

nvt_cs_delta_2s() {
    _c1=$(nvt_count_dmesg 'nvt_ts_point_data_checksum')
    sleep 2
    _c2=$(nvt_count_dmesg 'nvt_ts_point_data_checksum')
    printf '%s' "$((_c2 - _c1))"
}

# Active storm = high *rate*, not cumulative dmesg total.
# IRQ alone is authoritative: dmesg checksum counts wrap and go negative.
nvt_storm_active_rate() {
    _csd=$1
    _irq=$2
    # #region agent log
    if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
        _ts=$(date +%s%3N 2>/dev/null || date +%s)
        printf '%s\n' "{\"sessionId\":\"63ebe6\",\"runId\":\"storm-fix\",\"hypothesisId\":\"H3\",\"location\":\"heal_nvt:storm_active_rate\",\"message\":\"rate inputs\",\"data\":{\"csd\":$_csd,\"irq\":$_irq},\"timestamp\":$_ts}" >>"$UBUNTU_GSI_DEBUG_TRACE_LOG" 2>/dev/null || true
    fi
    # #endregion
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

nvt_wake_and_wait_resume() {
    _sus=$(nvt_count_dmesg 'nvt_ts_suspend 2521: start')
    _res=$(nvt_count_dmesg 'nvt_ts_resume 2623: end')
    _cs=$(nvt_count_dmesg 'nvt_ts_point_data_checksum')
    echo "nvt_suspend_count=$_sus nvt_resume_count=$_res"
    if [ "${NVT_WAKE_DISABLE:-0}" = "1" ]; then
        return 0
    fi
    _svc=/system/bin/svc
    [ -x "$_svc" ] || _svc=svc
    _input=/system/bin/input
    [ -x "$_input" ] || _input=input
    $_svc power stayon true 2>/dev/null || true
    # Do not send KEYCODE_POWER (26) — toggles display and correlates with NVT FD storm.
    $_input keyevent 224 2>/dev/null || true
    # $_input keyevent 26 2>/dev/null || true
    _wait=15
    [ "${NVT_WAIT_RESUME:-0}" = "1" ] && _wait=30
    _i=0
    while [ "$_i" -lt "$_wait" ]; do
        if dmesg 2>/dev/null | tail -30 | grep -qE 'nvt_ts_resume 2623: end|nvt_ts_resume 2591: Touch is already resume'; then
            echo "nvt_wake=resume_seen"
            return 0
        fi
        if dmesg 2>/dev/null | tail -15 | grep -q 'nvt_irq_enable 181: enable=1, desc->depth=0'; then
            echo "nvt_wake=irq_enabled"
            return 0
        fi
        sleep 0.5
        _i=$((_i + 1))
    done
    if [ "${NVT_WAIT_RESUME:-0}" = "1" ]; then
        echo "nvt_suspended=yes (resume wait timeout after display prep)"
        return 1
    fi
    return 0
}

if [ ! -e "$NVT_EV" ]; then
    echo "nvt_event3=missing"
    exit 1
fi

if [ "${NVT_WAKE_DISABLE:-0}" != "1" ] || [ "${NVT_WAIT_RESUME:-0}" = "1" ]; then
    nvt_wake_and_wait_resume || true
fi
I1=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
sleep 1
I2=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
case "$I1" in (''|*[!0-9]*) I1=0 ;; esac
case "$I2" in (''|*[!0-9]*) I2=0 ;; esac
DELTA=$((I2 - I1))
CS=$(nvt_count_dmesg 'nvt_ts_point_data_checksum')
CS_DELTA=$(nvt_cs_delta_2s)
RC=$(nvt_count_dmesg 'Recover for fw reset')
FWLOOP=$(dmesg 2>/dev/null | tail -200 | grep -c 'update_firmware_request' 2>/dev/null || true)
case "$FWLOOP" in (''|*[!0-9]*) FWLOOP=0 ;; esac
echo "nvt_irq_1s=$DELTA cs_delta_2s=$CS_DELTA checksum_log=$CS recover_fw=$RC fw_loop_hits=$FWLOOP"

# #region agent log
if [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ]; then
    _ts=$(date +%s%3N 2>/dev/null || date +%s)
    printf '%s\n' "{\"sessionId\":\"63ebe6\",\"hypothesisId\":\"H2\",\"location\":\"heal_nvt:storm_check\",\"message\":\"metrics\",\"data\":{\"delta\":$DELTA,\"cs_delta\":$CS_DELTA,\"cs\":$CS,\"post_mir\":${NVT_HEAL_POST_MIR:-0}},\"timestamp\":$_ts}" >>"$UBUNTU_GSI_DEBUG_TRACE_LOG" 2>/dev/null || true
fi
# #endregion

if nvt_storm_active_rate "$CS_DELTA" "$DELTA"; then
    echo "nvt_storm=yes active_now=1"
    if [ "${NVT_HEAL_POST_MIR:-0}" != "1" ]; then
        echo "nvt_action=reboot_required (SPI rebind forbidden)"
        exit 2
    fi
    echo "nvt_post_mir_wake_only=1 (skip MT clear during active storm)"
    nvt_wake_and_wait_resume || true
    echo "nvt_storm=no"
    exit 0
fi

echo "nvt_storm=no active_now=0"

clear_nvt_mt_slots "$NVT_EV" && echo "nvt_mt_slots_cleared=1"

# libinput sanity: synthetic frame must not hit "double tracking ID"
DOUBLE=0
SYN_OK=0
if [ -x /mnt/halium/merged/usr/bin/libinput ] && [ -d /mnt/halium/merged/proc/1 ]; then
    _rec=/data/local/tmp/heal-nvt-rec.txt
    _err=/data/local/tmp/heal-nvt-rec.err
    timeout 3 chroot /mnt/halium/merged /usr/bin/libinput record "$NVT_EV" >"$_rec" 2>"$_err" &
    _rp=$!
    sleep 0.4
    clear_nvt_mt_slots "$NVT_EV"
    sleep 0.1
    _se=/system/bin/sendevent
    $_se "$NVT_EV" 3 47 0
    $_se "$NVT_EV" 3 57 3001
    $_se "$NVT_EV" 3 48 10
    $_se "$NVT_EV" 3 58 50
    $_se "$NVT_EV" 3 53 800
    $_se "$NVT_EV" 3 54 1280
    $_se "$NVT_EV" 1 330 1
    $_se "$NVT_EV" 0 0 0
    sleep 0.15
    $_se "$NVT_EV" 3 57 4294967295
    $_se "$NVT_EV" 1 330 0
    $_se "$NVT_EV" 0 0 0
    wait "$_rp" 2>/dev/null || true
    if grep -qi 'double tracking ID' "$_err" 2>/dev/null; then
        DOUBLE=1
    fi
    if grep -q 'ABS_MT_TRACKING_ID' "$_rec" 2>/dev/null; then
        SYN_OK=1
    fi
fi
echo "nvt_libinput_double_id=$DOUBLE nvt_libinput_syn_ok=$SYN_OK"

# Optional finger probe (3s window)
FINGER_LINES=0
if [ "${NVT_HEAL_SKIP_FINGER:-0}" != 1 ]; then
    echo "nvt_finger_probe=3s (touch the panel now)"
    _ge=/data/local/tmp/heal-nvt-finger.txt
    : >"$_ge"
    timeout 3 getevent -lt "$NVT_EV" >>"$_ge" 2>&1 || true
    FINGER_LINES=$(wc -l <"$_ge" 2>/dev/null || echo 0)
    I3=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
    FINGER_IRQ=$((I3 - I2))
    echo "nvt_finger_lines=$FINGER_LINES nvt_finger_irq=$FINGER_IRQ"
else
    FINGER_IRQ=0
fi

if [ "$DOUBLE" -eq 1 ] 2>/dev/null; then
    echo "nvt_mt_stuck=yes (double tracking ID — slots re-cleared, restart Lomiri)"
    exit 4
fi

if [ "${NVT_WAIT_RESUME:-0}" = "1" ] && dmesg 2>/dev/null | tail -40 | grep -q "nvt_ts_suspend 2576: end" && ! dmesg 2>/dev/null | tail -40 | grep -qE "nvt_ts_resume 2623: end|nvt_ts_resume 2591: Touch is already resume"; then
    echo "nvt_suspended=yes (post-gpu resume missing)"
    exit 5
fi

if [ "${NVT_HEAL_SKIP_FINGER:-0}" != 1 ] && [ "$FINGER_LINES" -eq 0 ] 2>/dev/null && [ "${FINGER_IRQ:-0}" -eq 0 ] 2>/dev/null; then
    echo "nvt_dead=yes (no finger IRQ/events — reboot required)"
    echo "nvt_action=reboot_required"
    exit 3
fi

echo "nvt_storm=no"
exit 0
