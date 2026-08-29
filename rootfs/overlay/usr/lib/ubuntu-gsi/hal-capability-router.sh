#!/bin/sh
# =============================================================================
# hal-capability-router.sh — Kernel-first HAL path selection (low latency/power)
# =============================================================================
# Runs once per Lomiri/boot. Prefer kernel + event-driven Linux daemons.
# AIDL: one-shot probe only (no polling bridge). Device-agnostic discovery.
# =============================================================================

set -u
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

LOG_TAG="hal-router"

log() { echo "[$LOG_TAG] $*" >&2; }

pick_status_root() {
    for d in /run/ubuntu-gsi /data/uhl_overlay /tmp/ubuntu-gsi; do
        if mkdir -p "$d" 2>/dev/null; then
            echo "$d"
            return 0
        fi
    done
    echo "/tmp"
}

STATUS_ROOT="${HAL_STATUS_ROOT:-$(pick_status_root)}"
STATUS_DIR="${HAL_STATUS_DIR:-$STATUS_ROOT/hal-status}"
mkdir -p "$STATUS_DIR" 2>/dev/null || true
export HAL_STATUS_DIR="$STATUS_DIR"
export HAL_STATUS_ROOT="$STATUS_ROOT"

ENV_IN="${HAL_INVENTORY_ENV:-$STATUS_ROOT/hal-inventory.env}"
ENUM="/usr/lib/ubuntu-gsi/hal-enumerate.sh"
BRINGUP="/usr/lib/ubuntu-gsi/hal-kernel-bringup.sh"
PROBE="/usr/lib/ubuntu-gsi/hal-aidl-probe.sh"
WIFI="/usr/lib/ubuntu-gsi/wifi-bringup.sh"
GPU="/usr/lib/ubuntu-gsi/hal-gpu-bringup.sh"
# Writable fallback when overlay whiteouts block new files under /usr/lib/ubuntu-gsi
_pick_tool() {
    # $1=varname $2=filename — keep current if executable, else first alt hit
    _var="$1"
    _name="$2"
    eval "_cur=\$$_var"
    if [ -x "$_cur" ]; then
        return 0
    fi
    for _alt in /data/uhl_overlay/ubuntu-gsi-bin /data/local/tmp; do
        if [ -x "$_alt/$_name" ]; then
            eval "$_var=\"\$_alt/\$_name\""
            return 0
        fi
    done
}
_pick_tool ENUM hal-enumerate.sh
_pick_tool BRINGUP hal-kernel-bringup.sh
_pick_tool PROBE hal-aidl-probe.sh
_pick_tool WIFI wifi-bringup.sh
_pick_tool GPU hal-gpu-bringup.sh
unset _alt _var _name _cur _pick_tool

set_route() {
    _id="$1"
    _path="$2"
    _status="$3"
    _detail="${4:-}"
    {
        echo "path=$_path"
        echo "status=$_status"
        echo "detail=$_detail"
        echo "updated=$(date -Iseconds 2>/dev/null || date)"
    } >"$STATUS_DIR/$_id" 2>/dev/null || true
}

# --- 1. Enumerate (once) ---
if [ -x "$ENUM" ]; then
    "$ENUM" || log "enumerate failed (continuing)"
elif [ ! -f "$ENV_IN" ]; then
    log "WARNING: no enumerate script and no inventory.env"
fi

# shellcheck disable=SC1090
[ -f "$ENV_IN" ] && . "$ENV_IN"

# defaults if env missing
: "${INV_input:=0}" "${INV_dri:=0}" "${INV_audio:=0}" "${INV_bluetooth:=0}"
: "${INV_sensors:=0}" "${INV_camera:=0}" "${INV_gnss:=0}" "${INV_telephony:=0}"
: "${INV_wifi:=0}" "${INV_backlight:=0}" "${INV_power:=0}" "${INV_vibrator:=0}"
: "${INV_fingerprint:=0}"
: "${INV_and_gpu:=0}" "${INV_and_audio:=0}" "${INV_and_bt:=0}" "${INV_and_sensors:=0}"
: "${INV_and_camera:=0}" "${INV_and_gnss:=0}" "${INV_and_radio:=0}" "${INV_and_wifi:=0}"
: "${INV_pkg_lomiri:=0}" "${INV_pkg_pulse:=0}" "${INV_pkg_bluez:=0}" "${INV_pkg_iio:=0}"
: "${INV_pkg_ofono:=0}" "${INV_pkg_nm:=0}" "${INV_pkg_cam:=0}"

# Export selective bringup hints for hal-kernel-bringup.sh
# 1 = enable section, 0 = skip heavy daemon start (still may chmod if kernel=1)
export HAL_ENABLE_AUDIO="$INV_audio"
export HAL_ENABLE_BLUETOOTH="$INV_bluetooth"
export HAL_ENABLE_SENSORS="$INV_sensors"
export HAL_ENABLE_CAMERA="$INV_camera"
export HAL_ENABLE_GNSS="$INV_gnss"
export HAL_ENABLE_TELEPHONY="$INV_telephony"
export HAL_ENABLE_WIFI="$INV_wifi"
export HAL_ENABLE_POWER=1
export HAL_ENABLE_INPUT=1
# GPU heavy prep is deferred to Lomiri (hal-gpu-bringup lomiri_prep).
# Boot only does cheap DRM chmod via kernel bringup + optional chmod_only.
if [ "$INV_pkg_lomiri" = 1 ] || [ "$INV_and_gpu" = 1 ] || [ "$INV_dri" = 1 ]; then
    export HAL_ENABLE_GPU=1
else
    export HAL_ENABLE_GPU=0
fi
export HAL_LAZY_DAEMONS=1
export HAL_SKIP_WIFI=1

# --- 2. Route decisions (record before bringup) ---
# display_gpu: hybris path; heavy lomiri_prep is lazy (start-lomiri)
if [ "$HAL_ENABLE_GPU" = 1 ]; then
    set_route display_gpu hybris bridged "libhybris HWC/EGL (lazy lomiri_prep)"
else
    set_route display_gpu hybris missing "no lomiri/gpu"
fi

if [ "$INV_input" = 1 ]; then
    set_route input kernel bridged "evdev"
else
    set_route input kernel missing "no /dev/input"
fi

if [ "$INV_backlight" = 1 ] || [ "$INV_power" = 1 ]; then
    set_route power kernel bridged "sysfs backlight/power_supply"
else
    set_route power kernel missing "no power sysfs"
fi

# audio: kernel → pulse (lazy)
if [ "$INV_audio" = 1 ] && [ "$INV_pkg_pulse" = 1 ]; then
    set_route audio linux_daemon bridged "ALSA+Pulse"
elif [ "$INV_audio" = 1 ]; then
    set_route audio kernel kernel_only "ALSA only"
elif [ "$INV_and_audio" = 1 ]; then
    set_route audio aidl_unavailable missing_linux "audio HAL present, no kernel snd"
else
    set_route audio kernel missing "no audio"
fi

# bluetooth — BlueZ only if Linux HCI exists (MTK often has stpbt without hci*)
_hci=0
ls /sys/class/bluetooth/hci* >/dev/null 2>&1 && _hci=1
ls /dev/hci* >/dev/null 2>&1 && _hci=1
if [ "$_hci" = 1 ] && [ "$INV_pkg_bluez" = 1 ]; then
    set_route bluetooth linux_daemon bridged "BlueZ+HCI"
elif [ "$INV_bluetooth" = 1 ] && [ "$_hci" = 0 ]; then
    set_route bluetooth aidl_unavailable missing_linux "vendor BT node, no Linux HCI"
elif [ "$INV_bluetooth" = 1 ]; then
    set_route bluetooth kernel kernel_only "bt nodes"
elif [ "$INV_and_bt" = 1 ]; then
    set_route bluetooth aidl_unavailable missing_linux "BT HAL, no kernel node"
else
    set_route bluetooth kernel missing "no bluetooth"
fi

# sensors
if [ "$INV_sensors" = 1 ] && [ "$INV_pkg_iio" = 1 ]; then
    set_route sensors linux_daemon bridged "IIO+iio-sensor-proxy"
elif [ "$INV_sensors" = 1 ]; then
    set_route sensors kernel kernel_only "IIO nodes"
elif [ "$INV_and_sensors" = 1 ]; then
    set_route sensors aidl_unavailable missing_linux "Sensors HAL, no IIO"
else
    set_route sensors kernel missing "no sensors"
fi

# camera
if [ "$INV_camera" = 1 ] && [ "$INV_pkg_cam" = 1 ]; then
    set_route camera linux_daemon bridged "V4L2+libcamera"
elif [ "$INV_camera" = 1 ]; then
    set_route camera kernel kernel_only "V4L2 nodes"
elif [ "$INV_and_camera" = 1 ]; then
    set_route camera aidl_unavailable missing_linux "Camera HAL, no V4L2"
else
    set_route camera kernel missing "no camera"
fi

# gnss
if [ "$INV_gnss" = 1 ]; then
    set_route gnss kernel kernel_only "gnss device nodes"
elif [ "$INV_and_gnss" = 1 ]; then
    set_route gnss aidl_unavailable missing_linux "IGnss present, no /dev/gps*"
else
    set_route gnss kernel missing "no gnss"
fi

# telephony
if [ "$INV_telephony" = 1 ] && [ "$INV_pkg_ofono" = 1 ]; then
    set_route telephony linux_daemon bridged "ccci+ofono"
elif [ "$INV_telephony" = 1 ]; then
    set_route telephony kernel kernel_only "modem nodes"
elif [ "$INV_and_radio" = 1 ]; then
    set_route telephony aidl_unavailable missing_linux "IRadio present, no modem nodes"
else
    set_route telephony kernel missing "no telephony"
fi

# wifi
if [ "$INV_wifi" = 1 ]; then
    set_route wifi kernel bridged "rfkill/net (+ vendor wifi node if any)"
elif [ "$INV_and_wifi" = 1 ]; then
    set_route wifi aidl_unavailable missing_linux "wifi HAL, no netdev"
else
    set_route wifi kernel missing "no wifi"
fi

if [ "$INV_vibrator" = 1 ]; then
    set_route vibrator kernel bridged "sysfs vibrator"
else
    set_route vibrator kernel missing "no vibrator"
fi

if [ "$INV_fingerprint" = 1 ]; then
    set_route fingerprint kernel kernel_only "fp device nodes"
elif [ "$INV_and_fp" = 1 ]; then
    set_route fingerprint aidl_unavailable missing_linux "fp HAL only"
else
    set_route fingerprint kernel missing "no fingerprint"
fi

# --- 3. Apply kernel bringup (permissions + selective daemons) ---
if [ -x "$BRINGUP" ]; then
    "$BRINGUP" || log "bringup failed (continuing)"
fi

# GPU: boot path is chmod-only (low power). SF/HWC reclaim waits for Lomiri.
if [ "${HAL_ENABLE_GPU:-0}" = "1" ] && [ -x "$GPU" ]; then
    "$GPU" chmod_only || log "gpu chmod_only failed"
fi

# WiFi: only if kernel wifi present (wmtWifi optional inside script)
if [ "$INV_wifi" = 1 ] && [ -x "$WIFI" ]; then
    "$WIFI" || log "wifi-bringup failed"
fi

# --- 4. One-shot AIDL probe (no continuous conversion) ---
if [ -x "$PROBE" ]; then
    "$PROBE" || log "aidl probe failed"
fi

log "routes written under $STATUS_DIR"
exit 0
