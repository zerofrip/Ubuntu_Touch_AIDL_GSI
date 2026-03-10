#!/bin/bash
# =============================================================================
# aidl/common/aidl_hal_base.sh — AIDL HAL Service Base Library
# =============================================================================
# Shared functions for all AIDL HAL service wrappers. Provides binder
# service registration, health monitoring, mock fallback, and logging.
#
# Each HAL wrapper sources this file and calls:
#   aidl_hal_init  SERVICE_NAME  AIDL_INTERFACE  [CRITICAL]
#   aidl_hal_run   HANDLER_FUNCTION
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AIDL_LOG_DIR="/data/uhl_overlay"
AIDL_STATE_DIR="/run/ubuntu-gsi/hal"
BINDER_DEV="/dev/binder"
VINTF_MANIFEST="/vendor/etc/vintf/manifest.xml"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_hal_log() {
    local level="$1"
    local msg="$2"
    echo "[$(date -Iseconds)] [AIDL:${HAL_SERVICE_NAME:-unknown}] [$level] $msg" >> "${AIDL_LOG_DIR}/hal.log"
}

hal_info()  { _hal_log "INFO"  "$1"; }
hal_warn()  { _hal_log "WARN"  "$1"; }
hal_error() { _hal_log "ERROR" "$1"; }

# ---------------------------------------------------------------------------
# AIDL Service Discovery
# ---------------------------------------------------------------------------

# Check if an AIDL interface is declared in the vendor VINTF manifest
aidl_interface_available() {
    local interface="$1"

    # Check VINTF manifest for AIDL declaration
    if [ -f "$VINTF_MANIFEST" ]; then
        if grep -q "$interface" "$VINTF_MANIFEST" 2>/dev/null; then
            return 0
        fi
    fi

    # Check device manifest fragments
    for frag in /vendor/etc/vintf/manifest/*.xml /odm/etc/vintf/manifest*.xml; do
        if [ -f "$frag" ] && grep -q "$interface" "$frag" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# Query binder service list for a registered service
binder_service_registered() {
    local service="$1"
    if command -v service >/dev/null 2>&1; then
        service list 2>/dev/null | grep -q "$service"
        return $?
    fi
    # Fallback: check dumpsys
    if [ -f "/sys/kernel/debug/binder/stats" ]; then
        grep -q "$service" /sys/kernel/debug/binder/stats 2>/dev/null
        return $?
    fi
    return 1
}

# Wait for a binder service with retry
wait_for_binder_service() {
    local service="$1"
    local max_retries="${2:-10}"
    local delay="${3:-1}"
    local attempt=0

    while [ $attempt -lt $max_retries ]; do
        if binder_service_registered "$service"; then
            hal_info "Binder service '$service' available (attempt $((attempt+1)))"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$delay"
    done

    hal_warn "Binder service '$service' not available after $max_retries attempts"
    return 1
}

# ---------------------------------------------------------------------------
# HAL State Management
# ---------------------------------------------------------------------------

hal_set_state() {
    local key="$1"
    local value="$2"
    mkdir -p "$AIDL_STATE_DIR"
    echo "$value" > "$AIDL_STATE_DIR/${HAL_SERVICE_NAME}.${key}"
}

hal_get_state() {
    local key="$1"
    local state_file="$AIDL_STATE_DIR/${HAL_SERVICE_NAME}.${key}"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# HAL Initialization
# ---------------------------------------------------------------------------

# Initialize an AIDL HAL wrapper
# Usage: aidl_hal_init SERVICE_NAME AIDL_INTERFACE [critical|optional]
aidl_hal_init() {
    HAL_SERVICE_NAME="$1"
    HAL_AIDL_INTERFACE="$2"
    HAL_CRITICALITY="${3:-optional}"

    mkdir -p "$AIDL_LOG_DIR" "$AIDL_STATE_DIR"

    hal_info "Initializing AIDL HAL wrapper for $HAL_AIDL_INTERFACE"

    # Verify binder device availability
    if [ ! -c "$BINDER_DEV" ]; then
        hal_error "/dev/binder not available"
        if [ "$HAL_CRITICALITY" = "critical" ]; then
            exit 1
        fi
        return 1
    fi

    # Check AIDL interface declaration in vendor
    if aidl_interface_available "$HAL_AIDL_INTERFACE"; then
        hal_info "AIDL interface '$HAL_AIDL_INTERFACE' declared in vendor VINTF"
        hal_set_state "mode" "native"
        HAL_MODE="native"
    else
        hal_warn "AIDL interface '$HAL_AIDL_INTERFACE' NOT in vendor VINTF"
        hal_set_state "mode" "mock"
        HAL_MODE="mock"
    fi

    hal_set_state "status" "initializing"
    hal_set_state "pid" "$$"
    return 0
}

# ---------------------------------------------------------------------------
# Mock Fallback
# ---------------------------------------------------------------------------

# Run mock mode for a HAL service (provides stub responses)
hal_run_mock() {
    local mock_handler="${1:-hal_default_mock}"

    hal_info "Running in MOCK mode (vendor HAL not available)"
    hal_set_state "status" "mock"

    # Call the service-specific mock handler if it exists
    if type "$mock_handler" >/dev/null 2>&1; then
        "$mock_handler"
    else
        hal_info "No mock handler defined, entering idle"
        # Keep alive for service monitoring
        while true; do
            sleep 60
            hal_info "Mock heartbeat (PID $$)"
        done
    fi
}

# ---------------------------------------------------------------------------
# HAL Run Loop
# ---------------------------------------------------------------------------

# Main entry point — checks mode and dispatches to native or mock handler
# Usage: aidl_hal_run NATIVE_HANDLER [MOCK_HANDLER]
aidl_hal_run() {
    local native_handler="$1"
    local mock_handler="${2:-hal_default_mock}"

    hal_set_state "status" "running"
    hal_info "HAL service started (mode=$HAL_MODE, PID=$$)"

    if [ "$HAL_MODE" = "native" ]; then
        if type "$native_handler" >/dev/null 2>&1; then
            "$native_handler"
        else
            hal_error "Native handler '$native_handler' not defined"
            exit 1
        fi
    else
        hal_run_mock "$mock_handler"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

hal_cleanup() {
    hal_info "Shutting down (PID $$)"
    hal_set_state "status" "stopped"
}

trap hal_cleanup EXIT INT TERM
