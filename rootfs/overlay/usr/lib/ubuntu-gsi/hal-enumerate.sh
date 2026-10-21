#!/bin/sh
# =============================================================================
# hal-enumerate.sh — One-shot, device-agnostic HAL / kernel inventory
# =============================================================================
# No polling. No binder traffic beyond an optional short `service list`.
# Writes:
#   $STATUS_ROOT/hal-inventory.json
#   $STATUS_ROOT/hal-inventory.env   (shell-friendly flags)
# =============================================================================

set -u

LOG_TAG="hal-enumerate"

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
mkdir -p "$STATUS_ROOT" 2>/dev/null || true
JSON_OUT="${HAL_INVENTORY_JSON:-$STATUS_ROOT/hal-inventory.json}"
ENV_OUT="${HAL_INVENTORY_ENV:-$STATUS_ROOT/hal-inventory.env}"

# --- helpers ---
any_path() {
    for p in "$@"; do
        # shellcheck disable=SC2086
        for m in $p; do
            [ -e "$m" ] && return 0
        done
    done
    return 1
}

flag() {
    # flag NAME 0|1
    eval "INV_$1=$2"
}

json_str_list() {
    # stdin: one item per line → ["a","b"]
    _first=1
    printf '['
    while IFS= read -r _line || [ -n "${_line:-}" ]; do
        [ -n "$_line" ] || continue
        _esc=$(printf '%s' "$_line" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ "$_first" = 1 ]; then
            _first=0
        else
            printf ','
        fi
        printf '"%s"' "$_esc"
    done
    printf ']'
}

# --- meta ---
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
RO_HW=$(getprop ro.hardware 2>/dev/null || echo unknown)
RO_PLAT=$(getprop ro.board.platform 2>/dev/null || echo unknown)
RO_VNDK=$(getprop ro.vndk.version 2>/dev/null || echo unknown)

# --- vendor hw libs (lib64 then lib) ---
HW_DIR=""
for cand in /vendor/lib64/hw /vendor/lib/hw; do
    if [ -d "$cand" ]; then
        HW_DIR="$cand"
        break
    fi
done

HW_LIST=""
if [ -n "$HW_DIR" ]; then
    HW_LIST=$(ls "$HW_DIR" 2>/dev/null | sort)
fi

# --- VINTF tags (bounded) ---
VINTF_TAGS=""
for f in /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/compatibility_matrix.xml; do
    [ -f "$f" ] || continue
    _tags=$(grep -oE 'android\.hardware\.[a-zA-Z0-9_.]+' "$f" 2>/dev/null | sort -u | head -80)
    if [ -n "$_tags" ]; then
        VINTF_TAGS="${VINTF_TAGS}${VINTF_TAGS:+
}${_tags}"
    fi
done

# --- optional short service list (once) ---
SVC_SNIP=""
if [ -n "${SERVICE_LIST_FILE:-}" ] && [ -f "$SERVICE_LIST_FILE" ]; then
    SVC_SNIP=$(head -200 "$SERVICE_LIST_FILE" 2>/dev/null || true)
elif [ -f /data/local/tmp/service_list.txt ]; then
    SVC_SNIP=$(head -200 /data/local/tmp/service_list.txt 2>/dev/null || true)
elif command -v timeout >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
    SVC_SNIP=$(timeout 5 service list 2>/dev/null | head -200 || true)
fi

# --- kernel / sysfs presence ---
flag input 0
any_path "/dev/input/event*" && flag input 1

flag dri 0
any_path "/dev/dri/card*" "/dev/dri/renderD*" && flag dri 1

flag audio 0
any_path "/dev/snd/*" && flag audio 1
[ -e /proc/asound/cards ] && flag audio 1

flag bluetooth 0
any_path "/dev/ttyBT*" "/dev/stpbt*" "/sys/class/bluetooth/*" && flag bluetooth 1

flag sensors 0
any_path "/dev/iio:device*" "/sys/bus/iio/devices/iio:device*" && flag sensors 1

flag camera 0
any_path "/dev/video*" "/dev/media*" && flag camera 1

flag gnss 0
any_path "/dev/gps*" "/dev/gnss*" "/dev/stpgps*" && flag gnss 1

flag telephony 0
any_path "/dev/ccci*" "/dev/ttyC*" "/dev/gsm*" && flag telephony 1

flag wifi 0
any_path "/sys/class/net/wlan*" "/dev/wmtWifi*" && flag wifi 1

flag backlight 0
any_path "/sys/class/backlight/*" && flag backlight 1

flag power 0
any_path "/sys/class/power_supply/*" && flag power 1

flag vibrator 0
any_path "/sys/class/timed_output/vibrator*" "/sys/class/leds/vibrator*" && flag vibrator 1

flag fingerprint 0
any_path "/dev/fingerprint*" "/dev/goodix*" "/dev/fpsensor*" "/dev/fpc*" "/dev/silead*" && flag fingerprint 1

# Android HAL presence from hw dir / vintf / services (name match only)
hw_match() {
    echo "$HW_LIST" | grep -qiE "$1" && return 0
    echo "$VINTF_TAGS" | grep -qiE "$1" && return 0
    echo "$SVC_SNIP" | grep -qiE "$1" && return 0
    return 1
}

flag and_gpu 0
hw_match 'hwcomposer|gralloc|composer|graphics\.allocator|IAllocator' && flag and_gpu 1

flag and_audio 0
hw_match 'audio|IAudio' && flag and_audio 1

flag and_bt 0
hw_match 'bluetooth|IBluetooth' && flag and_bt 1

flag and_sensors 0
hw_match 'sensors|ISensors' && flag and_sensors 1

flag and_camera 0
hw_match 'camera|ICamera' && flag and_camera 1

flag and_gnss 0
hw_match 'gnss|gps|IGnss' && flag and_gnss 1

flag and_radio 0
hw_match 'radio|IRadio|ril' && flag and_radio 1

flag and_wifi 0
hw_match 'wifi|IWifi|wifinl80211' && flag and_wifi 1

flag and_power 0
hw_match 'power|IPower|health|IHealth' && flag and_power 1

flag and_fp 0
hw_match 'fingerprint|biometrics' && flag and_fp 1

# Linux packages (best-effort; chroot paths)
bin_ok() {
    command -v "$1" >/dev/null 2>&1 && return 0
    [ -x "/usr/bin/$1" ] || [ -x "/usr/sbin/$1" ] || [ -x "/usr/libexec/$1" ]
}

flag pkg_lomiri 0; bin_ok lomiri && flag pkg_lomiri 1
flag pkg_pulse 0; bin_ok pulseaudio && flag pkg_pulse 1
flag pkg_bluez 0; bin_ok bluetoothctl && flag pkg_bluez 1
flag pkg_iio 0
if bin_ok iio-sensor-proxy || [ -x /usr/libexec/iio-sensor-proxy ]; then
  flag pkg_iio 1
fi
flag pkg_ofono 0; bin_ok ofonod && flag pkg_ofono 1
flag pkg_nm 0; bin_ok nmcli && flag pkg_nm 1
flag pkg_cam 0; bin_ok cam && flag pkg_cam 1

# --- write .env ---
{
    echo "# generated by hal-enumerate.sh — do not edit"
    echo "INV_TS=$TS"
    echo "INV_RO_HARDWARE=$RO_HW"
    echo "INV_RO_PLATFORM=$RO_PLAT"
    echo "INV_RO_VNDK=$RO_VNDK"
    echo "INV_HW_DIR=$HW_DIR"
    echo "INV_input=${INV_input:-0}"
    echo "INV_dri=${INV_dri:-0}"
    echo "INV_audio=${INV_audio:-0}"
    echo "INV_bluetooth=${INV_bluetooth:-0}"
    echo "INV_sensors=${INV_sensors:-0}"
    echo "INV_camera=${INV_camera:-0}"
    echo "INV_gnss=${INV_gnss:-0}"
    echo "INV_telephony=${INV_telephony:-0}"
    echo "INV_wifi=${INV_wifi:-0}"
    echo "INV_backlight=${INV_backlight:-0}"
    echo "INV_power=${INV_power:-0}"
    echo "INV_vibrator=${INV_vibrator:-0}"
    echo "INV_fingerprint=${INV_fingerprint:-0}"
    echo "INV_and_gpu=${INV_and_gpu:-0}"
    echo "INV_and_audio=${INV_and_audio:-0}"
    echo "INV_and_bt=${INV_and_bt:-0}"
    echo "INV_and_sensors=${INV_and_sensors:-0}"
    echo "INV_and_camera=${INV_and_camera:-0}"
    echo "INV_and_gnss=${INV_and_gnss:-0}"
    echo "INV_and_radio=${INV_and_radio:-0}"
    echo "INV_and_wifi=${INV_and_wifi:-0}"
    echo "INV_and_power=${INV_and_power:-0}"
    echo "INV_and_fp=${INV_and_fp:-0}"
    echo "INV_pkg_lomiri=${INV_pkg_lomiri:-0}"
    echo "INV_pkg_pulse=${INV_pkg_pulse:-0}"
    echo "INV_pkg_bluez=${INV_pkg_bluez:-0}"
    echo "INV_pkg_iio=${INV_pkg_iio:-0}"
    echo "INV_pkg_ofono=${INV_pkg_ofono:-0}"
    echo "INV_pkg_nm=${INV_pkg_nm:-0}"
    echo "INV_pkg_cam=${INV_pkg_cam:-0}"
} >"$ENV_OUT" 2>/dev/null || true

# --- write JSON (bounded lists) ---
HW_JSON=$(printf '%s\n' "$HW_LIST" | head -80 | json_str_list)
VINTF_JSON=$(printf '%s\n' "$VINTF_TAGS" | head -80 | json_str_list)

{
    printf '{\n'
    printf '  "schema": "ubuntu-gsi.hal-inventory.v1",\n'
    printf '  "timestamp": "%s",\n' "$TS"
    printf '  "device": {"ro.hardware": "%s", "ro.board.platform": "%s", "ro.vndk.version": "%s"},\n' \
        "$(printf '%s' "$RO_HW" | sed 's/"/\\"/g')" \
        "$(printf '%s' "$RO_PLAT" | sed 's/"/\\"/g')" \
        "$(printf '%s' "$RO_VNDK" | sed 's/"/\\"/g')"
    printf '  "vendor_hw_dir": "%s",\n' "$HW_DIR"
    printf '  "vendor_hw": %s,\n' "$HW_JSON"
    printf '  "vintf_tags": %s,\n' "$VINTF_JSON"
    printf '  "kernel": {\n'
    printf '    "input": %s, "dri": %s, "audio": %s, "bluetooth": %s,\n' \
        "${INV_input:-0}" "${INV_dri:-0}" "${INV_audio:-0}" "${INV_bluetooth:-0}"
    printf '    "sensors": %s, "camera": %s, "gnss": %s, "telephony": %s,\n' \
        "${INV_sensors:-0}" "${INV_camera:-0}" "${INV_gnss:-0}" "${INV_telephony:-0}"
    printf '    "wifi": %s, "backlight": %s, "power": %s, "vibrator": %s, "fingerprint": %s\n' \
        "${INV_wifi:-0}" "${INV_backlight:-0}" "${INV_power:-0}" "${INV_vibrator:-0}" "${INV_fingerprint:-0}"
    printf '  },\n'
    printf '  "android_hal": {\n'
    printf '    "gpu": %s, "audio": %s, "bluetooth": %s, "sensors": %s,\n' \
        "${INV_and_gpu:-0}" "${INV_and_audio:-0}" "${INV_and_bt:-0}" "${INV_and_sensors:-0}"
    printf '    "camera": %s, "gnss": %s, "radio": %s, "wifi": %s, "power": %s, "fingerprint": %s\n' \
        "${INV_and_camera:-0}" "${INV_and_gnss:-0}" "${INV_and_radio:-0}" "${INV_and_wifi:-0}" \
        "${INV_and_power:-0}" "${INV_and_fp:-0}"
    printf '  },\n'
    printf '  "packages": {\n'
    printf '    "lomiri": %s, "pulseaudio": %s, "bluez": %s, "iio_sensor_proxy": %s,\n' \
        "${INV_pkg_lomiri:-0}" "${INV_pkg_pulse:-0}" "${INV_pkg_bluez:-0}" "${INV_pkg_iio:-0}"
    printf '    "ofono": %s, "nmcli": %s, "cam": %s\n' \
        "${INV_pkg_ofono:-0}" "${INV_pkg_nm:-0}" "${INV_pkg_cam:-0}"
    printf '  },\n'
    printf '  "policy": {"prefer": "kernel", "aidl": "probe_once", "no_polling_bridge": true}\n'
    printf '}\n'
} >"$JSON_OUT" 2>/dev/null || true

log "wrote $JSON_OUT"
log "wrote $ENV_OUT"
exit 0
