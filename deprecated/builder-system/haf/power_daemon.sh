#!/bin/bash
# =============================================================================
# power_daemon.sh (Final Master HAF Blueprint)
# =============================================================================

SERVICE="power"
PIPE="/dev/uhl/$SERVICE"
HAL="android.hardware.power"

source /system/haf/common_hal.sh
log_daemon "$SERVICE" "Spinning Power Limits..."

evaluate_hal_provider "$SERVICE" "$HAL" "$PIPE" "BATTERY" "STATUS=CHARGING"

log_daemon "$SERVICE" "Mapping upower targets natively..."
/usr/libexec/upowerd > /dev/null 2>&1 &

tail -f "$PIPE" | while read -r line; do
    log_daemon "$SERVICE" "Power Routine -> $line"
done &
