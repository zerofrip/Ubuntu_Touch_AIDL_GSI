#!/bin/bash
# =============================================================================
# wifi_daemon.sh — WiFi HAF Daemon
# =============================================================================
# Manages vendor WiFi firmware loading and wpa_supplicant lifecycle
# within the HAF (Hardware Abstraction Framework).
# =============================================================================

SERVICE="wifi"
PIPE="/dev/uhl/$SERVICE"
HAL="android.hardware.wifi"

source /system/haf/common_hal.sh
log_daemon "$SERVICE" "Initializing WiFi subsystem..."

evaluate_hal_provider "$SERVICE" "$HAL" "$PIPE" "SCAN" "STATUS=NO_WIFI"

log_daemon "$SERVICE" "Probing vendor WiFi firmware..."

# Symlink vendor firmware
for fw_dir in /vendor/firmware/wlan /vendor/firmware /vendor/etc/wifi; do
    if [ -d "$fw_dir" ]; then
        mkdir -p /lib/firmware/vendor
        for fw in "$fw_dir"/*; do
            [ -f "$fw" ] || continue
            ln -sf "$fw" "/lib/firmware/$(basename "$fw")" 2>/dev/null || true
        done
        log_daemon "$SERVICE" "Linked firmware from $fw_dir"
    fi
done

# Detect WiFi interface
WIFI_IFACE=""
for _attempt in $(seq 1 10); do
    for iface_path in /sys/class/net/*/wireless; do
        if [ -d "$iface_path" ]; then
            WIFI_IFACE=$(basename "$(dirname "$iface_path")")
            break 2
        fi
    done
    sleep 1
done

if [ -n "$WIFI_IFACE" ]; then
    log_daemon "$SERVICE" "WiFi interface: $WIFI_IFACE"

    # Start wpa_supplicant
    if command -v wpa_supplicant >/dev/null 2>&1; then
        wpa_supplicant -B -i "$WIFI_IFACE" -D nl80211,wext \
            -c /etc/wpa_supplicant/wpa_supplicant.conf \
            -O /run/wpa_supplicant 2>/dev/null || true
        log_daemon "$SERVICE" "wpa_supplicant started"
    fi
else
    log_daemon "$SERVICE" "No WiFi interface found — service idle"
fi

tail -f "$PIPE" 2>/dev/null | while read -r line; do
    log_daemon "$SERVICE" "WiFi request -> $line"
done &
