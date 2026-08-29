#!/bin/bash
# =============================================================================
# scripts/isolate_gsi_bootloop.sh — A/B isolate GSI bootloop causes on F8
# =============================================================================
# Prerequisite: stock Android boots (bash scripts/restore_stock_f8.sh succeeded).
#
# MODE=vbmeta-only-stock     — empty vbmeta ONLY; keep stock system (H90: OK)
# MODE=overlays-only-stock   — empty product/system_ext ONLY (H93: bootloops — do not use)
# MODE=official-phh          — empty vbmeta + nested PHH cache (no flatten) (H100)
# MODE=empty-vanilla         — alias of official-phh
# MODE=empty-ubuntu          — empty vbmeta + Ubuntu system.img (must be nested layout)
#
# Interpreting results:
#   vbmeta-only-stock boots            → empty vbmeta OK
#   overlays-only-stock loops          → empty product/system_ext break boot
#   flat vanilla loops, official boots → flatten breaks F8 (H100)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="${MODE:-empty-ubuntu}"
# H93: empty overlays bootloop stock — default keep OEM product/system_ext
export REPLACE_OEM_OVERLAYS="${REPLACE_OEM_OVERLAYS:-${DELETE_OEM_OVERLAYS:-0}}"

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Do not run isolate with sudo. Flash as normal user:"
    echo "  MODE=$MODE bash scripts/isolate_gsi_bootloop.sh"
    exit 1
fi

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi


case "$MODE" in
    vbmeta-only-stock)
        export REPLACE_OEM_OVERLAYS=0
        export SKIP_SYSTEM=1
        export SKIP_VBMETA=0
        export WIPE_USERDATA=0
        export FORMAT_METADATA=0
        export VBMETA_MODE=empty
        SYSTEM_IMG="(stock kept)"
        ;;
    overlays-only-stock)
        # Assumes device already boots (stock system + preferably empty vbmeta from H90).
        export REPLACE_OEM_OVERLAYS=1
        export SKIP_SYSTEM=1
        export SKIP_VBMETA=1
        export WIPE_USERDATA=0
        export FORMAT_METADATA=0
        export VBMETA_MODE=empty
        SYSTEM_IMG="(stock kept)"
        ;;
    empty-vanilla-keep-overlays|empty-vanilla|official-phh)
        # H100: F8 boots official nested PHH; flattened image bootloops.
        NESTED="$REPO_ROOT/builder/cache/phh-gsi-android-16.0.img"
        if [ ! -f "$NESTED" ] && [ -f "$REPO_ROOT/builder/cache/phh-gsi.img" ]; then
            NESTED="$REPO_ROOT/builder/cache/phh-gsi.img"
        fi
        # Optional override only if caller passes a nested image explicitly
        if [ -n "${OFFICIAL_PHH_IMG:-}" ]; then
            NESTED="$OFFICIAL_PHH_IMG"
        fi
        [ -f "$NESTED" ] || { echo "Missing nested PHH at $NESTED — bash scripts/fetch_phh_gsi.sh"; exit 1; }
        if [[ "$NESTED" == *phh-vanilla-flat* ]] || [[ "$NESTED" == *android-16.0_system.img ]]; then
            echo "Refusing flattened/Ubuntu image for official-phh (H100). Use cache/phh-gsi*.img"
            exit 1
        fi
        # Sanity: nested must have /system/build.prop
        if ! debugfs -R 'stat /system/build.prop' "$NESTED" 2>&1 | grep -q 'Inode:'; then
            echo "Image is not nested SAR layout: $NESTED"
            exit 1
        fi
        SYSTEM_IMG="$NESTED"
        export REPLACE_OEM_OVERLAYS=0
        export SKIP_SYSTEM=0
        export SKIP_VBMETA=0
        export WIPE_USERDATA=1
        export FORMAT_METADATA=1
        export VBMETA_MODE=empty
        ;;
    empty-ubuntu)
        SYSTEM_IMG="${SYSTEM_IMG:-$REPO_ROOT/builder/out/${RELEASE_SYSTEM_IMG:-system.img}}"
        if [ ! -f "$SYSTEM_IMG" ] && [ -f "$REPO_ROOT/builder/out/system.img" ]; then
            SYSTEM_IMG="$REPO_ROOT/builder/out/system.img"
        fi
        [ -f "$SYSTEM_IMG" ] || { echo "Missing $SYSTEM_IMG — sudo make system"; exit 1; }
        # Prefer nested builder/out/system.img if RELEASE name is stale/flat
        if ! debugfs -R 'stat /system/build.prop' "$SYSTEM_IMG" 2>&1 | grep -q 'Inode:'; then
            if [ -f "$REPO_ROOT/builder/out/system.img" ] \
                && debugfs -R 'stat /system/build.prop' "$REPO_ROOT/builder/out/system.img" 2>&1 | grep -q 'Inode:'; then
                echo "NOTE: $SYSTEM_IMG is flat/stale; using builder/out/system.img (nested)"
                SYSTEM_IMG="$REPO_ROOT/builder/out/system.img"
            fi
        fi
        [ -f "$SYSTEM_IMG" ] || { echo "Missing $SYSTEM_IMG — sudo make system"; exit 1; }
        # H100: F8 requires nested SAR layout
        if ! debugfs -R 'stat /system/build.prop' "$SYSTEM_IMG" 2>&1 | grep -q 'Inode:'; then
            echo "ERROR: $SYSTEM_IMG is FLAT (no /system/build.prop)."
            echo "Rebuild nested Ubuntu first: sudo make system"
            echo "Expect log: keeping layout (no flatten)"
            exit 1
        fi
        if ! debugfs -R 'stat /system/etc/init/ubuntu-gsi.rc' "$SYSTEM_IMG" 2>&1 | grep -q 'Inode:'; then
            echo "ERROR: missing /system/etc/init/ubuntu-gsi.rc — incomplete Halium overlay"
            exit 1
        fi
        export REPLACE_OEM_OVERLAYS=0
        export SKIP_SYSTEM=0
        export SKIP_VBMETA=0
        export WIPE_USERDATA=1
        export FORMAT_METADATA=1
        export VBMETA_MODE=empty
        ;;
    *)
        echo "MODE=vbmeta-only-stock|overlays-only-stock|official-phh|empty-vanilla|empty-vanilla-keep-overlays|empty-ubuntu"
        exit 1
        ;;
esac

echo "=== Isolation: MODE=$MODE ==="
echo "system: $SYSTEM_IMG"
echo "vbmeta: ${VBMETA_MODE} (flags=3 when empty)"
echo "REPLACE_OEM_OVERLAYS=$REPLACE_OEM_OVERLAYS"
echo "SKIP_SYSTEM=${SKIP_SYSTEM:-0} WIPE_USERDATA=${WIPE_USERDATA:-1} FORMAT_METADATA=${FORMAT_METADATA:-1}"
echo ""

export SYSTEM_IMG
export SET_ACTIVE_SLOT=a

bash "$REPO_ROOT/scripts/recover_f8_gsi_boot.sh"
