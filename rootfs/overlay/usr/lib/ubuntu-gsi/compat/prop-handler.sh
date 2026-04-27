#!/bin/bash
# =============================================================================
# compat/prop-handler.sh — Linux translation of phh-prop-handler.sh
# =============================================================================
# device_phh_treble/phh-prop-handler.sh is invoked by Android `init` whenever
# a `persist.sys.phh.*` property changes. Ubuntu GSI runs Linux userspace, so
# instead of getprop/setprop we read flags from the runtime env file produced
# by compat-engine.sh and translate them into sysfs/proc/udev/systemctl
# actions. This gives us behavioural parity for the most common toggles:
#
#   UBUNTU_GSI_DT2W_VENDOR     -> double-tap-to-wake on/off (xiaomi/oppo/asus/transsion)
#   UBUNTU_GSI_HEADSET_FIX     -> Huawei devinput jack quirk
#   UBUNTU_GSI_HEADSET_DEVINPUT-> Force devinput jack
#   UBUNTU_GSI_FORCE_NAVBAR    -> Force navigation bar overlay
#   UBUNTU_GSI_NOTCH_EXTEND    -> Extend status bar over notch (Essential PH-1)
#   UBUNTU_GSI_USB_FFS_MTP     -> Use AOSP FFS MTP gadget (Samsung)
#   UBUNTU_GSI_BT_SYSTEM_AUDIO -> Mark BT system audio HAL flag
#   UBUNTU_GSI_RESTART_RIL     -> MediaTek RIL restart helper
#   UBUNTU_GSI_BACKLIGHT_SCALE -> Cache max-brightness for percentile scaling
#
# Invocation modes:
#   prop-handler.sh apply-all      # Iterate all known toggles
#   prop-handler.sh apply <NAME>   # Apply one toggle
#   prop-handler.sh status         # Print toggle status as JSON
# =============================================================================

set -u

COMPAT_RUN_DIR="${COMPAT_RUN_DIR:-/run/ubuntu-gsi/compat}"
COMPAT_RUNTIME_ENV="${UBUNTU_GSI_COMPAT_RUNTIME:-/etc/default/ubuntu-gsi-compat.runtime}"
COMPAT_USER_ENV="${COMPAT_USER_ENV:-/etc/default/ubuntu-gsi-compat}"
COMPAT_LOG="${COMPAT_LOG:-/var/log/ubuntu-gsi-compat.log}"

mkdir -p "$COMPAT_RUN_DIR" 2>/dev/null || true

log() {
    local ts
    ts=$(date -Iseconds 2>/dev/null || date +%s)
    printf '[%s] [prop-handler] %s\n' "$ts" "$*" | tee -a "$COMPAT_LOG"
}

# ---------------------------------------------------------------------------
# Source compat-engine output (set with safe defaults so unset vars don't
# trigger set -u)
# ---------------------------------------------------------------------------
load_env() {
    # shellcheck source=/dev/null
    [ -r "$COMPAT_RUNTIME_ENV" ] && . "$COMPAT_RUNTIME_ENV"
    # shellcheck source=/dev/null
    [ -r "$COMPAT_USER_ENV" ]    && . "$COMPAT_USER_ENV"

    : "${UBUNTU_GSI_DT2W_VENDOR:=}"
    : "${UBUNTU_GSI_HEADSET_FIX:=0}"
    : "${UBUNTU_GSI_HEADSET_DEVINPUT:=0}"
    : "${UBUNTU_GSI_FORCE_NAVBAR:=0}"
    : "${UBUNTU_GSI_NOTCH_EXTEND:=0}"
    : "${UBUNTU_GSI_USB_FFS_MTP:=0}"
    : "${UBUNTU_GSI_BT_SYSTEM_AUDIO:=0}"
    : "${UBUNTU_GSI_RESTART_RIL:=0}"
    : "${UBUNTU_GSI_BACKLIGHT_SCALE:=0}"
}

# ---------------------------------------------------------------------------
# echo_to FILE VALUE — best-effort write helper
# ---------------------------------------------------------------------------
echo_to() {
    local file="$1" value="$2"
    [ -e "$file" ] || return 1
    printf '%s' "$value" > "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Toggle implementations
# ---------------------------------------------------------------------------

# DT2W — equivalent to phh-prop-handler.sh xiaomi_toggle_dt2w_*
toggle_dt2w() {
    local enable="${1:-1}" vendor="${UBUNTU_GSI_DT2W_VENDOR:-}"
    [ -z "$vendor" ] && { log "DT2W: vendor not set, skipping"; return 0; }

    case "$vendor" in
        xiaomi|redmi|poco)
            for n in /proc/touchpanel/wakeup_gesture /proc/tp_wakeup_gesture /proc/tp_gesture; do
                echo_to "$n" "$enable" && log "DT2W xiaomi: $n=$enable"
            done
            # ioctl fallback (mirrors xiaomi_toggle_dt2w_ioctl)
            if [ -c /dev/xiaomi-touch ] && command -v xiaomi-touch >/dev/null 2>&1; then
                xiaomi-touch 14 "$enable" >/dev/null 2>&1 && log "DT2W xiaomi: ioctl=$enable"
            fi
            ;;
        oppo|realme|oneplus)
            echo_to /proc/touchpanel/double_tap_enable "$enable" && log "DT2W oppo: enable=$enable"
            ;;
        asus)
            echo_to /proc/touchpanel/double_tap "$enable" && log "DT2W asus: enable=$enable"
            ;;
        transsion)
            # phh-prop-handler.sh: echo cc${prop_value} > /proc/gesture_function
            echo_to /proc/gesture_function "cc${enable}" && log "DT2W transsion: cc${enable}"
            ;;
        vsmart)
            if [ "$enable" = 1 ]; then
                echo_to /sys/class/vsm/tp/gesture_control 0
            else
                printf '' > /sys/class/vsm/tp/gesture_control 2>/dev/null || true
            fi
            log "DT2W vsmart: $enable"
            ;;
        *)
            log "DT2W: unknown vendor '$vendor' — best-effort scan"
            for n in /proc/touchpanel/wakeup_gesture \
                     /proc/touchpanel/double_tap_enable \
                     /proc/touchpanel/double_tap \
                     /proc/tp_wakeup_gesture \
                     /proc/tp_gesture; do
                echo_to "$n" "$enable" && log "DT2W generic: $n=$enable"
            done
            ;;
    esac
}

# Headset / devinput jack — for Huawei vendors that mis-report the jack switch
toggle_headset_jack() {
    local enable="${1:-1}"
    if [ "$enable" = 1 ]; then
        log "Headset: enabling devinput jack quirk"
        # Set Linux equivalent — make sure ALSA jack-detection gets routed
        # through evdev SW_HEADPHONE_INSERT instead of vendor jack node.
        if [ -d /etc/pulse ]; then
            mkdir -p /etc/pulse/default.pa.d 2>/dev/null || true
            cat > /etc/pulse/default.pa.d/10-devinput-jack.pa <<'PAEOF' 2>/dev/null
.ifexists module-jackdbus-detect.so
load-module module-jackdbus-detect
.endif
.ifexists module-switch-on-port-available.so
load-module module-switch-on-port-available
.endif
PAEOF
        fi
    fi
}

# Force navigation bar (LG / HTC quirk)
toggle_force_navbar() {
    local enable="${1:-0}"
    [ "$enable" = 1 ] || return 0
    log "NavBar: forcing navigation bar overlay"
    if command -v gsettings >/dev/null 2>&1 && id -u ubuntu >/dev/null 2>&1; then
        su - ubuntu -c "gsettings set com.lomiri.shell.test forceNavbar true" \
            >/dev/null 2>&1 || true
    fi
}

# Notch extension (Essential PH-1)
toggle_notch_extend() {
    local enable="${1:-0}"
    [ "$enable" = 1 ] || return 0
    log "Notch: extending status bar over camera cutout"
    if command -v gsettings >/dev/null 2>&1 && id -u ubuntu >/dev/null 2>&1; then
        su - ubuntu -c "gsettings set com.lomiri.shell statusBarExtendedTop true" \
            >/dev/null 2>&1 || true
    fi
}

# Samsung FFS MTP gadget preference (mirrors device_phh_treble system.prop:
#   vendor.usb.use_ffs_mtp=1)
toggle_usb_ffs_mtp() {
    local enable="${1:-0}"
    [ "$enable" = 1 ] || return 0
    if [ -f /usr/lib/ubuntu-gsi/usb-gadget.sh ]; then
        log "USB: preferring FFS-based MTP gadget"
        # The gadget script reads /run/ubuntu-gsi/compat for hints
        echo "ffs-mtp" > "$COMPAT_RUN_DIR/usb-gadget-mode" 2>/dev/null || true
    fi
}

# BT system-audio HAL flag (treble_app Misc.kt 'sysbta' / phh-on-boot.sh)
toggle_bt_system_audio() {
    local enable="${1:-0}"
    [ "$enable" = 1 ] || return 0
    log "Bluetooth: marking system_audio_hal.enabled=true"
    # Linux side just records the choice; the actual A2DP path is decided by
    # PipeWire/PulseAudio module-bluetooth-discover.
    echo "system_audio_hal=true" > "$COMPAT_RUN_DIR/bluetooth-mode" 2>/dev/null || true
    if command -v gsettings >/dev/null 2>&1 && id -u ubuntu >/dev/null 2>&1; then
        su - ubuntu -c "gsettings set org.gnome.Bluetooth profile a2dp" \
            >/dev/null 2>&1 || true
    fi
}

# MediaTek RIL restart (mirrors phh-on-boot.sh mtkmal block)
toggle_restart_ril() {
    local enable="${1:-0}"
    [ "$enable" = 1 ] || return 0
    if command -v systemctl >/dev/null 2>&1; then
        log "Telephony: restarting telephony-hal & ofono (MTK RIL workaround)"
        systemctl restart telephony-hal.service 2>/dev/null || true
        systemctl restart ofono.service        2>/dev/null || true
    fi
}

# Backlight scale — cache max brightness for percentile scaling
toggle_backlight_scale() {
    local enable="${1:-0}"
    [ "$enable" = 1 ] || return 0
    local maxfile out
    for maxfile in \
        /sys/class/leds/lcd-backlight/max_brightness \
        /sys/class/backlight/panel0-backlight/max_brightness \
        /sys/class/backlight/sprd_backlight/max_brightness; do
        if [ -r "$maxfile" ]; then
            out=$(cat "$maxfile" 2>/dev/null)
            echo "$out" > "$COMPAT_RUN_DIR/backlight-max" 2>/dev/null || true
            log "Backlight: cached max brightness=$out from $maxfile"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
apply_one() {
    local name="$1"
    case "$name" in
        dt2w)            toggle_dt2w 1 ;;
        headset)         toggle_headset_jack    "${UBUNTU_GSI_HEADSET_FIX}" ;;
        navbar)          toggle_force_navbar    "${UBUNTU_GSI_FORCE_NAVBAR}" ;;
        notch)           toggle_notch_extend    "${UBUNTU_GSI_NOTCH_EXTEND}" ;;
        ffsmtp)          toggle_usb_ffs_mtp     "${UBUNTU_GSI_USB_FFS_MTP}" ;;
        btsysaudio)      toggle_bt_system_audio "${UBUNTU_GSI_BT_SYSTEM_AUDIO}" ;;
        restartril)      toggle_restart_ril     "${UBUNTU_GSI_RESTART_RIL}" ;;
        backlightscale)  toggle_backlight_scale "${UBUNTU_GSI_BACKLIGHT_SCALE}" ;;
        *)
            log "Unknown toggle: $name"
            return 1
            ;;
    esac
}

apply_all() {
    [ -n "${UBUNTU_GSI_DT2W_VENDOR:-}" ] && toggle_dt2w 1
    [ "${UBUNTU_GSI_HEADSET_FIX:-0}"      = 1 ] && toggle_headset_jack 1
    [ "${UBUNTU_GSI_FORCE_NAVBAR:-0}"     = 1 ] && toggle_force_navbar 1
    [ "${UBUNTU_GSI_NOTCH_EXTEND:-0}"     = 1 ] && toggle_notch_extend 1
    [ "${UBUNTU_GSI_USB_FFS_MTP:-0}"      = 1 ] && toggle_usb_ffs_mtp 1
    [ "${UBUNTU_GSI_BT_SYSTEM_AUDIO:-0}"  = 1 ] && toggle_bt_system_audio 1
    [ "${UBUNTU_GSI_RESTART_RIL:-0}"      = 1 ] && toggle_restart_ril 1
    [ "${UBUNTU_GSI_BACKLIGHT_SCALE:-0}"  = 1 ] && toggle_backlight_scale 1
    return 0
}

print_status() {
    cat <<EOF
{
  "dt2w_vendor":          "${UBUNTU_GSI_DT2W_VENDOR:-}",
  "headset_fix":          "${UBUNTU_GSI_HEADSET_FIX:-0}",
  "headset_devinput":     "${UBUNTU_GSI_HEADSET_DEVINPUT:-0}",
  "force_navbar":         "${UBUNTU_GSI_FORCE_NAVBAR:-0}",
  "notch_extend":         "${UBUNTU_GSI_NOTCH_EXTEND:-0}",
  "usb_ffs_mtp":          "${UBUNTU_GSI_USB_FFS_MTP:-0}",
  "bt_system_audio":      "${UBUNTU_GSI_BT_SYSTEM_AUDIO:-0}",
  "restart_ril":          "${UBUNTU_GSI_RESTART_RIL:-0}",
  "backlight_scale":      "${UBUNTU_GSI_BACKLIGHT_SCALE:-0}"
}
EOF
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
load_env

case "${1:-apply-all}" in
    apply-all) apply_all ;;
    apply)     apply_one "${2:-}" ;;
    status)    print_status ;;
    *)
        echo "Usage: $0 {apply-all|apply <name>|status}" >&2
        exit 2
        ;;
esac
