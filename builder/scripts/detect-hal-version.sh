#!/bin/bash
# =============================================================================
# scripts/detect-hal-version.sh — VINTF HAL Capability Scanner
# =============================================================================
# Accepts either:
#   * AIDL-style service: android.hardware.power.IPower
#   * HIDL-style service: android.hardware.power@1.3::IPower
# Performs resilient lookup across vendor/odm VINTF manifests and fragments.
# =============================================================================

TARGET_SERVICE="${1:-}"
LOG_FILE="/data/uhl_overlay/hal.log"

if [ -z "$TARGET_SERVICE" ]; then
    echo "Usage: $0 <android.hardware.service>"
    exit 1
fi

mkdir -p /data/uhl_overlay 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

log() {
    echo "[$(date -Iseconds)] [HAL Scanner] $1" >> "$LOG_FILE"
}

VINTF_FILES="
/vendor/etc/vintf/manifest.xml
/vendor/etc/vintf/manifest/*.xml
/vendor/etc/vintf/manifest_*xml
/vendor/manifest.xml
/vendor/manifest.xml.d/*.xml
/odm/etc/vintf/manifest.xml
/odm/etc/vintf/manifest/*.xml
/odm/etc/vintf/manifest_*xml
/odm/manifest.xml
/odm/manifest.xml.d/*.xml
"

SERVICE_PKG=""
SERVICE_IFACE=""

case "$TARGET_SERVICE" in
    *::*)
        SERVICE_PKG="${TARGET_SERVICE%%::*}"
        SERVICE_IFACE="${TARGET_SERVICE##*::}"
        ;;
    *.*)
        SERVICE_PKG="${TARGET_SERVICE%.*}"
        SERVICE_IFACE="${TARGET_SERVICE##*.}"
        ;;
    *)
        SERVICE_PKG="$TARGET_SERVICE"
        SERVICE_IFACE="$TARGET_SERVICE"
        ;;
esac

for pattern in $VINTF_FILES; do
    for f in $pattern; do
        [ -f "$f" ] || continue

        # Strongest match: exact target token in file.
        if grep -qF "$TARGET_SERVICE" "$f" 2>/dev/null; then
            log "Discovered native provider (exact): $TARGET_SERVICE in $f"
            echo "STATE: SUPPORTED ($TARGET_SERVICE)"
            exit 0
        fi

        # Structured fallback: package + interface name both present.
        if grep -qF "$SERVICE_PKG" "$f" 2>/dev/null && grep -qF "$SERVICE_IFACE" "$f" 2>/dev/null; then
            log "Discovered native provider (pkg+iface): $TARGET_SERVICE in $f"
            echo "STATE: SUPPORTED ($TARGET_SERVICE)"
            exit 0
        fi
    done
done

log "WARNING: Provider omitted from vendor layout: $TARGET_SERVICE"
echo "STATE: MISSING ($TARGET_SERVICE)"
exit 1
