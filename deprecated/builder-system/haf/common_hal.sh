#!/bin/bash
# =============================================================================
# system/haf/common_hal.sh (Universal HAL Library)
# =============================================================================
# Simplifies DAEMON boilerplate natively. Provides strict Logging, Mocks,
# and Pipe evaluation logic ensuring perfect extensibility.
# =============================================================================

LOG_FILE="/data/uhl_overlay/daemon.log"

log_daemon() {
    echo "[$(date -Iseconds)] [HAF $1] $2" >> "$LOG_FILE"
}

execute_mock_loop() {
    local SERVICE=$1
    local PIPE=$2
    local REQ_MATCH=$3
    local MOCK_REPLY=$4
    
    log_daemon "$SERVICE" "Engaging explicitly mocked fallback routine..."
    while true; do
        read -r req < "$PIPE" || continue
        if [ "$req" == "$REQ_MATCH" ] || [ -z "$REQ_MATCH" ]; then
            echo "$MOCK_REPLY" > "${PIPE}_out"
            log_daemon "$SERVICE" "Dummy endpoint response translated to Call."
        fi
    done &
    exit 0
}

evaluate_hal_provider() {
    local SERVICE=$1
    local HAL=$2
    local PIPE=$3
    local REQ_MATCH=$4
    local MOCK_REPLY=$5

    /scripts/detect-hal-version.sh "$HAL"
    if [ $? -ne 0 ]; then
        log_daemon "$SERVICE" "Android Provider ($HAL) explicitly missing natively."
        execute_mock_loop "$SERVICE" "$PIPE" "$REQ_MATCH" "$MOCK_REPLY"
    fi
    
    log_daemon "$SERVICE" "Hardware dependencies strictly passed!"
}
