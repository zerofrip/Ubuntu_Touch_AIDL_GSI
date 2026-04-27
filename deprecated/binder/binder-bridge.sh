#!/bin/bash
# =============================================================================
# binder/binder-bridge.sh — Ubuntu ↔ Android Binder Bridge Daemon
# =============================================================================
# Manages the connection between Ubuntu userspace services and Android
# vendor HAL services exposed via /dev/binder.
#
# Responsibilities:
#   1. Verify binder device availability
#   2. Start AIDL HAL wrappers from manifest.json
#   3. Monitor HAL health and restart on failure
#   4. Provide service status via state files
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
BINDER_DEV="/dev/binder"
VNDBINDER_DEV="/dev/vndbinder"
MANIFEST="$REPO_ROOT/aidl/manifest.json"
LOG_FILE="/data/uhl_overlay/binder-bridge.log"
STATE_DIR="/run/ubuntu-gsi/hal"
PID_DIR="/run/ubuntu-gsi/pids"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date -Iseconds)] [binder-bridge] $1" >> "$LOG_FILE"; }
log_stdout() { echo "[binder-bridge] $1"; log "$1"; }

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------
init() {
    mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$PID_DIR"

    log_stdout "Starting binder bridge daemon (PID $$)"

    # Verify binder devices
    if [ ! -c "$BINDER_DEV" ]; then
        log_stdout "FATAL: $BINDER_DEV not available"
        log_stdout "  Ensure BinderFS is mounted and /dev/binder symlinked"
        exit 1
    fi
    log_stdout "Binder device: $BINDER_DEV ✓"

    if [ -c "$VNDBINDER_DEV" ]; then
        log_stdout "Vendor binder: $VNDBINDER_DEV ✓"
    else
        log_stdout "Vendor binder: not available (vendor HALs may be limited)"
    fi

    # Verify manifest
    if [ ! -f "$MANIFEST" ]; then
        log_stdout "FATAL: AIDL manifest not found: $MANIFEST"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_stdout "FATAL: jq not found (required to parse manifest)"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# HAL Module Management
# ---------------------------------------------------------------------------
start_hal_module() {
    local name="$1"
    local binary="$2"
    local critical="$3"
    local delay="$4"

    if [ "$delay" -gt 0 ]; then
        log "Delaying $name start by ${delay}s"
        sleep "$delay"
    fi

    if [ ! -f "$binary" ]; then
        if [ "$critical" = "true" ]; then
            log_stdout "FATAL: Critical HAL binary missing: $binary"
            return 1
        fi
        log "WARN: HAL binary missing: $binary (non-critical, skipping)"
        return 0
    fi

    chmod +x "$binary"
    bash "$binary" &
    local pid=$!
    echo "$pid" > "$PID_DIR/$name.pid"
    log_stdout "Started HAL: $name (PID $pid)"

    return 0
}

start_all_modules() {
    local module_count
    module_count=$(jq '.hal_modules | length' "$MANIFEST")

    log_stdout "Loading $module_count AIDL HAL modules"

    # Start critical modules first
    for i in $(seq 0 $((module_count - 1))); do
        local name critical
        critical=$(jq -r ".hal_modules[$i].critical" "$MANIFEST")
        if [ "$critical" = "true" ]; then
            name=$(jq -r ".hal_modules[$i].name" "$MANIFEST")
            local binary delay
            binary=$(jq -r ".hal_modules[$i].binary" "$MANIFEST")
            delay=$(jq -r ".hal_modules[$i].start_delay" "$MANIFEST")
            start_hal_module "$name" "$binary" "$critical" "$delay" || {
                log_stdout "FATAL: Critical module '$name' failed to start"
                exit 1
            }
        fi
    done

    # Then optional modules
    for i in $(seq 0 $((module_count - 1))); do
        local name critical
        critical=$(jq -r ".hal_modules[$i].critical" "$MANIFEST")
        if [ "$critical" != "true" ]; then
            name=$(jq -r ".hal_modules[$i].name" "$MANIFEST")
            local binary delay
            binary=$(jq -r ".hal_modules[$i].binary" "$MANIFEST")
            delay=$(jq -r ".hal_modules[$i].start_delay" "$MANIFEST")
            start_hal_module "$name" "$binary" "$critical" "$delay" || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Health Monitor
# ---------------------------------------------------------------------------
monitor_health() {
    local check_interval=30

    while true; do
        sleep "$check_interval"

        for pidfile in "$PID_DIR"/*.pid; do
            [ -f "$pidfile" ] || continue
            local name pid
            name=$(basename "$pidfile" .pid)
            pid=$(cat "$pidfile")

            if ! kill -0 "$pid" 2>/dev/null; then
                log "WARN: HAL '$name' (PID $pid) died"

                # Check if critical
                local critical
                critical=$(jq -r ".hal_modules[] | select(.name==\"$name\") | .critical" "$MANIFEST")
                local binary
                binary=$(jq -r ".hal_modules[] | select(.name==\"$name\") | .binary" "$MANIFEST")

                if [ "$critical" = "true" ]; then
                    log_stdout "Restarting critical HAL: $name"
                    start_hal_module "$name" "$binary" "true" "0"
                else
                    log "Non-critical HAL '$name' died — not restarting"
                    rm -f "$pidfile"
                fi
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log_stdout "Shutting down binder bridge"
    for pidfile in "$PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        local pid name
        pid=$(cat "$pidfile")
        name=$(basename "$pidfile" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "Stopped HAL: $name (PID $pid)"
        fi
        rm -f "$pidfile"
    done
    log_stdout "Binder bridge stopped"
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
init
start_all_modules
log_stdout "All HAL modules started — entering health monitor"
monitor_health
