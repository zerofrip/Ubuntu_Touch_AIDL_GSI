#!/bin/bash
# =============================================================================
# scripts/detect-vendor-services.sh — Vendor IPC Readiness Probe
# =============================================================================
# PHH-style compatibility probe:
#   * Tracks vendor fingerprint changes (cache invalidation trigger)
#   * Validates binder node readiness (/dev/binder, /dev/vndbinder, /dev/hwbinder)
#   * Best-effort checks service manager surfaces (AIDL service list, lshal)
#   * Writes machine-readable status to /tmp/binder_state
# =============================================================================

LOG_FILE="/data/uhl_overlay/hal.log"
BINDER_STATE="/tmp/binder_state"
OTA_FINGERPRINT="/data/uhl_overlay/vendor_fingerprint.cache"

mkdir -p /data/uhl_overlay
touch "$LOG_FILE"

log() {
    echo "[$(date -Iseconds)] [IPC Sanity] $1" >> "$LOG_FILE"
}

read_vendor_fingerprint() {
    local fp=""
    if [ -f /vendor/build.prop ]; then
        fp=$(grep -m1 '^ro.vendor.build.fingerprint=' /vendor/build.prop 2>/dev/null | cut -d '=' -f 2-)
    fi
    if [ -z "$fp" ] && [ -f /system/vendor/build.prop ]; then
        fp=$(grep -m1 '^ro.vendor.build.fingerprint=' /system/vendor/build.prop 2>/dev/null | cut -d '=' -f 2-)
    fi
    echo "$fp"
}

current_fp=$(read_vendor_fingerprint)
if [ -n "$current_fp" ]; then
    if [ -f "$OTA_FINGERPRINT" ]; then
        cached_fp=$(cat "$OTA_FINGERPRINT" 2>/dev/null)
        if [ "$current_fp" != "$cached_fp" ]; then
            log "Vendor fingerprint changed; invalidating compatibility caches"
            log "Fingerprint: ($cached_fp) -> ($current_fp)"
            rm -f /data/uhl_overlay/gpu_success.cache
            echo "$current_fp" > "$OTA_FINGERPRINT"
        fi
    else
        log "Caching vendor fingerprint for OTA drift detection"
        echo "$current_fp" > "$OTA_FINGERPRINT"
    fi
fi

max_retries=12
retry_delay=0.5
attempt=0

aidl_ok=0
hidl_ok=0
vnd_ok=0

while [ "$attempt" -lt "$max_retries" ]; do
    [ -c /dev/binder ] && aidl_ok=1
    [ -c /dev/hwbinder ] && hidl_ok=1
    [ -c /dev/vndbinder ] && vnd_ok=1

    if [ "$aidl_ok" -eq 1 ] || [ "$hidl_ok" -eq 1 ]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep "$retry_delay"
done

aidl_svc="unknown"
if command -v service >/dev/null 2>&1 && service list >/dev/null 2>&1; then
    aidl_svc="ready"
fi

hidl_svc="unknown"
if command -v lshal >/dev/null 2>&1; then
    if lshal -ip >/dev/null 2>&1; then
        hidl_svc="ready"
    else
        hidl_svc="present_but_no_output"
    fi
fi

{
    if [ "$aidl_ok" -eq 1 ] || [ "$hidl_ok" -eq 1 ]; then
        echo "IPC_STATUS=ACTIVE"
    else
        echo "IPC_STATUS=DEAD"
    fi
    echo "BINDER_NODE=$aidl_ok"
    echo "HWBINDER_NODE=$hidl_ok"
    echo "VNDBINDER_NODE=$vnd_ok"
    echo "AIDL_SERVICE_MANAGER=$aidl_svc"
    echo "HIDL_SERVICE_MANAGER=$hidl_svc"
} > "$BINDER_STATE"

if [ "$aidl_ok" -eq 1 ] || [ "$hidl_ok" -eq 1 ]; then
    log "Binder nodes ready (binder=$aidl_ok hwbinder=$hidl_ok vndbinder=$vnd_ok)"
    exit 0
fi

log "FATAL: no binder-capable IPC node found after retries"
exit 1
