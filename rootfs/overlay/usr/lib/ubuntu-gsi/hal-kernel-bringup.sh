#!/system/bin/sh
# =============================================================================
# hal-kernel-bringup.sh — Per-boot kernel permissions + selective daemons
# =============================================================================
# Prefer being invoked via hal-capability-router.sh.
# Env (optional, default=enable when unset for backward compat):
#   HAL_ENABLE_AUDIO|BLUETOOTH|SENSORS|CAMERA|GNSS|TELEPHONY|WIFI|POWER|INPUT
#   HAL_LAZY_DAEMONS=1  — start daemons only if not already running + device present
#   HAL_SKIP_WIFI=1     — skip wifi-bringup (router calls it separately)
# =============================================================================

set -u
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

LOG_TAG="hal-kernel-bringup"
STATUS_DIR="${HAL_STATUS_DIR:-/run/ubuntu-gsi/hal-status}"
if ! mkdir -p "$STATUS_DIR" 2>/dev/null; then
    STATUS_DIR="/data/uhl_overlay/hal-status"
    mkdir -p "$STATUS_DIR" 2>/dev/null || STATUS_DIR="/tmp/ubuntu-gsi-hal-status"
    mkdir -p "$STATUS_DIR" 2>/dev/null || true
fi

log() { echo "[$LOG_TAG] $*" >&2; }
set_status() {
    _id="$1"; _status="$2"; _detail="${3:-}"
    # Do not clobber router path= lines — append/update detail files with _kern suffix
    printf 'status=%s\ndetail=%s\nupdated=%s\n' "$_status" "$_detail" "$(date -Iseconds 2>/dev/null || date)" \
        >"$STATUS_DIR/${_id}_kern" 2>/dev/null || true
}

enabled() {
    # enabled VAR — unset or non-zero => yes
    _v=$(eval "echo \${$1:-1}")
    [ "$_v" != "0" ]
}

lazy_ok() {
    # Return 0 if we should start a daemon (lazy: skip if already running)
    if [ "${HAL_LAZY_DAEMONS:-0}" = "1" ]; then
        pgrep -x "$1" >/dev/null 2>&1 && return 1
    fi
    return 0
}

# --- DRM / backlight / power (cheap chmod only) ---
if enabled HAL_ENABLE_POWER; then
    for dri in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$dri" ] || continue
        chmod 0666 "$dri" 2>/dev/null || true
    done
    for bl in /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness; do
        [ -e "$bl" ] || continue
        chmod a+r "$bl" 2>/dev/null || true
    done
    [ -e /sys/class/backlight ] && set_status power_backlight ok "sysfs present" \
        || set_status power_backlight missing "no backlight"

    for psu in /sys/class/power_supply/*; do
        [ -d "$psu" ] || continue
        for f in capacity status type online voltage_now current_now temp health; do
            [ -e "$psu/$f" ] && chmod a+r "$psu/$f" 2>/dev/null || true
        done
    done
    [ -d /sys/class/power_supply ] && set_status power_supply ok || set_status power_supply missing
fi

# --- Input ---
if enabled HAL_ENABLE_INPUT; then
    chmod a+rw /dev/input/event* 2>/dev/null || true
    [ -d /dev/input ] && set_status input ok || set_status input missing
fi

# --- Sound (ALSA) + optional Pulse ---
if enabled HAL_ENABLE_AUDIO; then
    chmod a+rw /dev/snd/* 2>/dev/null || true
    if [ -e /proc/asound/cards ]; then
        set_status audio_alsa ok "$(tr '\n' ' ' </proc/asound/cards | head -c 120)"
    else
        set_status audio_alsa missing "no /proc/asound/cards"
    fi
    if command -v amixer >/dev/null 2>&1; then
        amixer -q set Master unmute 2>/dev/null || true
        amixer -q set Master 80% 2>/dev/null || true
        amixer -q set Speaker unmute 2>/dev/null || true
        amixer -q set Headphone unmute 2>/dev/null || true
    fi
    if [ -e /proc/asound/cards ] && command -v pulseaudio >/dev/null 2>&1; then
        if lazy_ok pulseaudio; then
            pulseaudio --start --exit-idle-time=-1 2>/dev/null \
                || pulseaudio -D --exit-idle-time=-1 2>/dev/null \
                || true
        fi
        if pgrep -x pulseaudio >/dev/null 2>&1; then
            set_status audio_pulse ok "pulseaudio running"
        else
            set_status audio_pulse missing "pulseaudio not running"
        fi
    else
        set_status audio_pulse skipped "no snd or no pulseaudio"
    fi
fi

# --- Bluetooth ---
# Runtime: MTK bt_drv exposes /dev/stpbt but not Linux HCI (/dev/hci*).
# BlueZ bluetoothd exits with "Number of controllers: 0". Do not claim bridged.
if enabled HAL_ENABLE_BLUETOOTH; then
    for rk in /sys/class/rfkill/rfkill*; do
        [ -e "$rk/type" ] || continue
        typ=$(cat "$rk/type" 2>/dev/null || true)
        if [ "$typ" = "bluetooth" ]; then
            echo 1 >"$rk/state" 2>/dev/null || true
        fi
    done
    chmod a+rw /dev/ttyBT* /dev/stpbt* /dev/hbt 2>/dev/null || true

    _hci_present=0
    ls /sys/class/bluetooth/hci* >/dev/null 2>&1 && _hci_present=1
    ls /dev/hci* >/dev/null 2>&1 && _hci_present=1

    if [ "$_hci_present" = 1 ]; then
        if command -v bluetoothctl >/dev/null 2>&1 || [ -x /usr/lib/bluetooth/bluetoothd ]; then
            if lazy_ok bluetoothd && command -v systemctl >/dev/null 2>&1; then
                systemctl start bluetooth.service 2>/dev/null || true
            fi
            if ! pgrep -x bluetoothd >/dev/null 2>&1 && [ -x /usr/lib/bluetooth/bluetoothd ]; then
                /usr/lib/bluetooth/bluetoothd >/data/local/tmp/bluetoothd.log 2>&1 &
            fi
            if pgrep -x bluetoothd >/dev/null 2>&1; then
                set_status bluetooth ok "bluetoothd + HCI"
            else
                set_status bluetooth kernel_only "HCI present, bluetoothd not running"
            fi
        fi
    else
        # Vendor BT HAL may be running (Android); BlueZ has nothing to manage.
        set_status bluetooth missing_linux "no /dev/hci* (vendor BT HAL only)"
        log "bluetooth: no Linux HCI — Lomiri BlueZ UI will stay empty"
    fi
fi

# --- Sensors (IIO) ---
if enabled HAL_ENABLE_SENSORS; then
    for iio in /dev/iio:device*; do
        [ -c "$iio" ] || continue
        chmod 0666 "$iio" 2>/dev/null || true
    done
    for iio in /sys/bus/iio/devices/iio:device*; do
        [ -d "$iio" ] || continue
        chmod -R a+rX "$iio" 2>/dev/null || true
    done
    if ls /sys/bus/iio/devices/iio:device* >/dev/null 2>&1; then
        if lazy_ok iio-sensor-proxy && command -v systemctl >/dev/null 2>&1; then
            systemctl start iio-sensor-proxy.service 2>/dev/null || true
        fi
        set_status sensors ok "iio present"
    else
        set_status sensors missing "no iio devices"
    fi
fi

# --- Camera (V4L2) ---
if enabled HAL_ENABLE_CAMERA; then
    chmod 0666 /dev/video* /dev/media* 2>/dev/null || true
    if ls /dev/video* >/dev/null 2>&1; then
        set_status camera ok "v4l2 nodes"
    else
        set_status camera missing "no /dev/video*"
    fi
fi

# --- GNSS ---
if enabled HAL_ENABLE_GNSS; then
    chmod a+rw /dev/gps* /dev/gnss* /dev/stpgps* 2>/dev/null || true
    if ls /dev/gps* /dev/gnss* /dev/stpgps* >/dev/null 2>&1; then
        set_status gnss kernel_only "device nodes"
    else
        set_status gnss missing "no gnss nodes"
    fi
fi

# --- Modem / ofono ---
if enabled HAL_ENABLE_TELEPHONY; then
    chmod a+rw /dev/ccci* /dev/ttyC* 2>/dev/null || true
    if [ -e /dev/ccci_md_partition ] || ls /dev/ccci* >/dev/null 2>&1 || ls /dev/ttyC* >/dev/null 2>&1; then
        if lazy_ok ofonod && command -v systemctl >/dev/null 2>&1; then
            systemctl start ofono.service 2>/dev/null || true
        fi
    fi
    if pgrep -x ofonod >/dev/null 2>&1; then
        set_status telephony ok "ofonod running"
    elif ls /dev/ccci* >/dev/null 2>&1; then
        set_status telephony kernel_only "ccci nodes, ofono not running"
    else
        set_status telephony missing "no modem nodes"
    fi
fi

# --- Vibrator (generic sysfs) ---
for v in /sys/class/timed_output/vibrator/enable /sys/class/leds/vibrator/brightness \
         /sys/class/leds/vibrator_0/brightness; do
    [ -e "$v" ] || continue
    chmod 0666 "$v" 2>/dev/null || true
done

# --- WiFi (delegate; skip when router owns it) ---
if [ "${HAL_SKIP_WIFI:-0}" != "1" ] && enabled HAL_ENABLE_WIFI; then
    if [ -x /usr/lib/ubuntu-gsi/wifi-bringup.sh ]; then
        /usr/lib/ubuntu-gsi/wifi-bringup.sh || true
        set_status wifi ok "wifi-bringup invoked"
    else
        # Generic rfkill unblock even without vendor wmtWifi script
        for rk in /sys/class/rfkill/rfkill*; do
            [ -e "$rk/type" ] || continue
            typ=$(cat "$rk/type" 2>/dev/null || true)
            if [ "$typ" = "wlan" ] || [ "$typ" = "wifi" ]; then
                echo 1 >"$rk/state" 2>/dev/null || true
            fi
        done
        command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null || true
        set_status wifi kernel_only "rfkill only"
    fi
fi

# Indicators: no systemd --user here. start-lomiri.sh ensure_indicators
# spawns ayatana/lomiri indicator services on the session bus.
set_status indicators deferred "start-lomiri ensure_indicators"

log "done — kern status in $STATUS_DIR (*_kern)"
exit 0
