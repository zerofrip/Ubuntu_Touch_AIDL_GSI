#!/bin/bash
# =============================================================================
# telephony_daemon.sh — Telephony HAF Daemon
# =============================================================================
# Manages vendor modem/RIL integration and oFono/ModemManager lifecycle
# within the HAF (Hardware Abstraction Framework).
# =============================================================================

SERVICE="telephony"
PIPE="/dev/uhl/$SERVICE"
HAL="android.hardware.radio"

source /system/haf/common_hal.sh
log_daemon "$SERVICE" "Initializing telephony subsystem..."

evaluate_hal_provider "$SERVICE" "$HAL" "$PIPE" "SIM_STATUS" "STATUS=NO_MODEM"

log_daemon "$SERVICE" "Probing modem hardware..."

# Detect modem type from vendor
MODEM_TYPE="unknown"
if [ -f /vendor/build.prop ]; then
    PLATFORM=$(grep "ro.board.platform" /vendor/build.prop 2>/dev/null | cut -d'=' -f2)
    case "$PLATFORM" in
        mt*|MT*) MODEM_TYPE="mediatek" ;;
        msm*|sdm*|sm*) MODEM_TYPE="qualcomm" ;;
        exynos*|universal*) MODEM_TYPE="samsung" ;;
    esac
fi
log_daemon "$SERVICE" "Modem type: $MODEM_TYPE"

# Detect modem devices
MODEM_FOUND=false
for dev in /dev/cdc-wdm* /dev/ttyACM* /dev/ttyUSB* /dev/ttyMT* /dev/ccci_*; do
    if [ -e "$dev" ]; then
        MODEM_FOUND=true
        chmod 0660 "$dev" 2>/dev/null || true
        log_daemon "$SERVICE" "Modem device found: $dev"
    fi
done

if $MODEM_FOUND; then
    # Start telephony backend
    if command -v ofonod >/dev/null 2>&1; then
        ofonod -n -d 2>/dev/null &
        log_daemon "$SERVICE" "oFono daemon started"
    elif command -v ModemManager >/dev/null 2>&1; then
        ModemManager --debug 2>/dev/null &
        log_daemon "$SERVICE" "ModemManager started"
    else
        log_daemon "$SERVICE" "No telephony backend available"
    fi
else
    log_daemon "$SERVICE" "No modem hardware found — service idle"
fi

tail -f "$PIPE" 2>/dev/null | while read -r line; do
    log_daemon "$SERVICE" "Telephony request -> $line"
done &
