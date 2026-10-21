#!/system/bin/sh
# =============================================================================
# hal-aidl-probe.sh — Thin binder/AIDL discovery (no custom bridge daemon)
# =============================================================================
# Prefer SERVICE_LIST_FILE (host-pushed) to avoid OEM `service list` hangs under su.
# Falls back to service list with a short timeout when available.
# =============================================================================

set -u

STATUS_DIR="${HAL_STATUS_DIR:-/data/uhl_overlay/hal-status}"
mkdir -p "$STATUS_DIR" 2>/dev/null || {
    STATUS_DIR="/tmp/ubuntu-gsi-hal-status"
    mkdir -p "$STATUS_DIR" 2>/dev/null || true
}
LOG_TAG="hal-aidl-probe"

log() { echo "[$LOG_TAG] $*" >&2; }

write_probe() {
    _id="$1"
    _found="$2"
    _matches="$3"
    {
        echo "probe=aidl"
        echo "found=$_found"
        echo "matches=$_matches"
        echo "updated=$(date 2>/dev/null || echo unknown)"
    } >"$STATUS_DIR/aidl_$_id" 2>/dev/null || true
}

SVC_OUT=""
if [ -n "${SERVICE_LIST_FILE:-}" ] && [ -f "$SERVICE_LIST_FILE" ]; then
    SVC_OUT=$(cat "$SERVICE_LIST_FILE" 2>/dev/null || true)
elif [ -f /data/local/tmp/service_list.txt ]; then
    SVC_OUT=$(cat /data/local/tmp/service_list.txt 2>/dev/null || true)
fi

if [ -z "$SVC_OUT" ]; then
    if command -v timeout >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        SVC_OUT=$(timeout 5 service list 2>/dev/null || true)
    elif [ -x /system/bin/service ] && command -v timeout >/dev/null 2>&1; then
        SVC_OUT=$(timeout 5 /system/bin/service list 2>/dev/null || true)
    fi
fi

# binderfs presence
if [ -c /dev/binderfs/binder ] || [ -c /dev/binder ]; then
    echo "binderfs=yes" >"$STATUS_DIR/aidl_binderfs" 2>/dev/null || true
else
    echo "binderfs=no" >"$STATUS_DIR/aidl_binderfs" 2>/dev/null || true
fi

if [ -z "$SVC_OUT" ]; then
    log "WARNING: no service list — push /data/local/tmp/service_list.txt from host"
    for id in audio sensors gnss telephony camera bluetooth power fingerprint wifi graphics; do
        write_probe "$id" unknown "no_service_list"
    done
    exit 0
fi

probe_pat() {
    _id="$1"
    shift
    _matches=""
    for m in "$@"; do
        echo "$SVC_OUT" | grep -qi "$m" && _matches="${_matches}${_matches:+;}$m"
    done
    if [ -n "$_matches" ]; then
        write_probe "$_id" yes "$_matches"
        log "$_id: FOUND ($_matches)"
    else
        write_probe "$_id" no ""
        log "$_id: not found"
    fi
}

probe_pat audio      "android.hardware.audio" "IAudio" "audio@7" "AudioEffect" "soundtrigger"
probe_pat sensors    "android.hardware.sensors" "ISensors"
probe_pat gnss       "android.hardware.gnss" "IGnss"
probe_pat telephony  "android.hardware.radio" "IRadio" "phone"
probe_pat camera     "android.hardware.camera" "ICamera"
probe_pat bluetooth  "android.hardware.bluetooth" "IBluetooth"
probe_pat power      "android.hardware.power" "IPower" "health"
probe_pat fingerprint "android.hardware.biometrics.fingerprint" "IFingerprint" "biometrics.face"
probe_pat wifi       "android.hardware.wifi" "IWifi" "wifinl80211" "wifi.nl80211"
probe_pat graphics   "android.hardware.graphics.composer" "IComposer" "hwcomposer" "IAllocator" "graphics.allocator"

log "probe complete → $STATUS_DIR/aidl_*"
exit 0
