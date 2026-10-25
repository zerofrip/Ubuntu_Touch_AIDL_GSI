#!/system/bin/sh
# Bind userdata hotfixes over system NVT/touch-prep/launcher (survives reboot).
set -eu

# Opt-in debug trace log (formerly debug-63ebe6.log). Set UBUNTU_GSI_DEBUG_TRACE=1 to enable.
UBUNTU_GSI_DEBUG_TRACE_LOG=${UBUNTU_GSI_DEBUG_TRACE_LOG:-/data/local/tmp/ubuntu-gsi-debug-trace.log}
# #region agent log
_dbg_log() {
    [ "${UBUNTU_GSI_DEBUG_TRACE:-0}" = "1" ] || return 0
    _msg=$1 _data=$2
    _ts=$(date +%s%3N 2>/dev/null || date +%s)
    printf '%s\n' \
        "{\"sessionId\":\"63ebe6\",\"hypothesisId\":\"H1\",\"location\":\"hotfix-bind\",\"message\":\"$_msg\",\"data\":$_data,\"timestamp\":$_ts}" \
        >>"$UBUNTU_GSI_DEBUG_TRACE_LOG" 2>/dev/null || true
}
# #endregion

_pick() {
    _name=$1
    for _p in \
        "/data/uhl_overlay/ubuntu-gsi-bin/$_name" \
        "/data/local/tmp/$_name"; do
        if [ -f "$_p" ]; then
            printf '%s' "$_p"
            return 0
        fi
    done
    return 1
}

_bind_file() {
    _src=$1
    _dst=$2
    _label=$3
    if [ -f "$_src" ] && [ -f "$_dst" ]; then
        chmod 755 "$_src" 2>/dev/null || true
        if mount --bind "$_src" "$_dst" 2>/dev/null; then
            chmod 755 "$_dst" 2>/dev/null || true
            _dbg_log "bound" "{\"label\":\"$_label\",\"src\":\"$_src\",\"dst\":\"$_dst\"}"
            return 0
        fi
        _dbg_log "bind_failed" "{\"label\":\"$_label\",\"src\":\"$_src\",\"dst\":\"$_dst\"}"
    fi
    return 1
}

_h=$(_pick heal_nvt_touch.sh 2>/dev/null || true)
[ -n "$_h" ] && _bind_file "$_h" /system/usr/share/ubuntu-gsi/heal_nvt_touch.sh heal || true

_p=$(_pick ubuntu-gsi-touch-prep.sh 2>/dev/null || true)
[ -n "$_p" ] && _bind_file "$_p" /system/bin/ubuntu-gsi-touch-prep.sh touch_prep || true

_l=$(_pick ubuntu-gsi-launcher 2>/dev/null || true)
[ -n "$_l" ] && _bind_file "$_l" /system/bin/ubuntu-gsi-launcher launcher || true

_k=$(_pick ubuntu-gsi-nvt-keepalive.sh 2>/dev/null || true)
[ -n "$_k" ] && _bind_file "$_k" /system/usr/share/ubuntu-gsi/ubuntu-gsi-nvt-keepalive.sh keepalive 2>/dev/null || true

_s=$(_pick start-lomiri.sh 2>/dev/null || true)
if [ -n "$_s" ] && [ -f /system/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh ]; then
    _bind_file "$_s" /system/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh start_lomiri || true
fi

_dbg_log "done" "{\"launcher_bytes\":$(wc -c </system/bin/ubuntu-gsi-launcher 2>/dev/null || echo 0)}"
_s=$(_pick ubuntu-gsi-stop-android-ui 2>/dev/null || true)
[ -n "$_s" ] && _bind_file "$_s" /system/bin/ubuntu-gsi-stop-android-ui stop-ui || true
unset _dbg _dbg_log _pick _bind_file _h _p _l _k _s _msg _data _ts _name _p _src _dst _label
