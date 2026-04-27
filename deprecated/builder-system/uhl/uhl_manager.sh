#!/bin/bash
# =============================================================================
# system/uhl/uhl_manager.sh (Master Final Daemon Multiplexer)
# =============================================================================

LOG_FILE="/data/uhl_overlay/daemon.log"
mkdir -p /data/uhl_overlay
touch "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "[$(date -Iseconds)] [UHL Manager] Initiating Universal HAL Framework..." >> "$LOG_FILE"

UHL_DIR="/dev/uhl"
mkdir -p "$UHL_DIR"
chmod 0755 "$UHL_DIR"

SERVICES=("audio" "camera" "sensor" "power" "input")

for svc in "${SERVICES[@]}"; do
    PIPE="$UHL_DIR/$svc"
    if [ ! -e "$PIPE" ]; then
        touch "$PIPE"
        chmod 0660 "$PIPE"
    fi
    case $svc in
        "audio") chown root:audio "$PIPE" ;;
        "camera") chown root:video "$PIPE" ;;
        "input") chown root:input "$PIPE" ;;
        *) chown root:root "$PIPE" ;;
    esac
done
echo "[$(date -Iseconds)] [UHL Manager] 5 Localized Character Pipes safely established." >> "$LOG_FILE"

# =============================================================================
# Dependency-Aware Staggered Execution Phase
# =============================================================================

source "/tmp/binder_state"
if [ "$IPC_STATUS" == "DEAD" ]; then
   echo "[$(date -Iseconds)] [UHL Manager] DEPENDENCY WARNING: hwservicemanager explicitly dead." >> "$LOG_FILE"
   echo "[$(date -Iseconds)] [UHL Manager] Daemons will actively fall back selectively to Mocks preserving intact buses natively." >> "$LOG_FILE"
   # Removed FORCE_MOCK_ALL. Daemons use `common_hal.sh` to selectively skip missing arrays!
else
   echo "[$(date -Iseconds)] [UHL Manager] DEPENDENCY MET: hwservicemanager IPC active." >> "$LOG_FILE"
fi

echo "[$(date -Iseconds)] [UHL Manager] Instantiating abstract Universal Services from module_manifest.json natively..." >> "$LOG_FILE"

MANIFEST="/system/uhl/module_manifest.json"

if [ ! -f "$MANIFEST" ]; then
    echo "[$(date -Iseconds)] [UHL Manager] FATAL: module_manifest.json missing. Cannot load daemons!" >> "$LOG_FILE"
    exit 1
fi

# Parsing JSON via jq ensuring dynamic modular loading!
# This allows developers to drop new daemons without modifying bash execution sequences.
jq -c '.uhl_modules[]' "$MANIFEST" | while read -r module; do
    MOD_NAME=$(echo "$module" | jq -r '.name')
    MOD_BIN=$(echo "$module" | jq -r '.binary')
    MOD_DELAY=$(echo "$module" | jq -r '.delay_after')

    if [ -f "$MOD_BIN" ]; then
        echo "[$(date -Iseconds)] [UHL Manager] Launching $MOD_NAME payload..." >> "$LOG_FILE"
        chmod +x "$MOD_BIN"
        bash "$MOD_BIN" &
        
        if [ "$MOD_DELAY" -gt 0 ]; then
            echo "[$(date -Iseconds)] [UHL Manager] >> Pausing $MOD_DELAY seconds respecting IPC staggers natively..." >> "$LOG_FILE"
            sleep "$MOD_DELAY"
        fi
    else
        echo "[$(date -Iseconds)] [UHL Manager] WARN: Declared module binary ($MOD_BIN) missing natively!" >> "$LOG_FILE"
    fi
done

echo "[$(date -Iseconds)] [UHL Manager] Master Framework Multiplexer Loop Online successfully!" >> "$LOG_FILE"
wait
