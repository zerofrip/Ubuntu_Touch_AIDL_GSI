#!/bin/bash
# =============================================================================
# scripts/gsi-pack.sh (Final Master GSI Sparse Package Assembler)
# =============================================================================
# Synthesizes the exact flashable system.img bounding the Custom Linux Pivot.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_IMG="$WORKSPACE_DIR/out/system.img"
BOOTSTRAP_DIR="$WORKSPACE_DIR/out/gsi_sys"

echo "[$(date -Iseconds)] [GSI Packager] Assembling Sparse Native Targets..."

mkdir -p "$BOOTSTRAP_DIR"
rm -f "$OUT_IMG"

# Generate minimalist Android-compliant execution directories
mkdir -p "$BOOTSTRAP_DIR/system"
mkdir -p "$BOOTSTRAP_DIR/data"
mkdir -p "$BOOTSTRAP_DIR/dev/binderfs"
mkdir -p "$BOOTSTRAP_DIR/vendor"

echo "[$(date -Iseconds)] [GSI Packager] Injecting Custom Linux Initializer Sequence..."
cp -r "$WORKSPACE_DIR/init" "$BOOTSTRAP_DIR/"

# The only file on the root of the Ext4 is our Linux Pivot!
echo "[$(date -Iseconds)] [GSI Packager] Generating raw Ext4 Block..."

# Source configuration for image size
CONFIG_FILE="$(cd "$WORKSPACE_DIR/.." && pwd)/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=../../config.env
    source "$CONFIG_FILE"
fi
SYSTEM_IMG_SIZE_MB="${SYSTEM_IMG_SIZE_MB:-0}"

# Auto-compute minimal size when SYSTEM_IMG_SIZE_MB=0
if [ "${SYSTEM_IMG_SIZE_MB}" -eq 0 ]; then
    CONTENT_MB=$(du -sm "$BOOTSTRAP_DIR" | cut -f1)
    SYSTEM_IMG_SIZE_MB=$(( CONTENT_MB + 8 ))
    # Minimum 16 MB (ext4 lower bound)
    [ "$SYSTEM_IMG_SIZE_MB" -lt 16 ] && SYSTEM_IMG_SIZE_MB=16
    echo "[$(date -Iseconds)] [GSI Packager] Auto system.img size: ${SYSTEM_IMG_SIZE_MB}MB (content ${CONTENT_MB}MB + 8MB headroom)"
fi

dd if=/dev/zero of="$OUT_IMG" bs=1M count="$SYSTEM_IMG_SIZE_MB"

# Step 2: Format as ext4 with label 'system' and populate with bootstrap contents
# Sample command: mkfs.ext4 -L system out/system.img -d out/gsi_sys
mkfs.ext4 -L system "$OUT_IMG" -d "$BOOTSTRAP_DIR"

echo "[$(date -Iseconds)] [GSI Packager] SUCCESS: Flashable Final Master Array built cleanly at $OUT_IMG!"
echo "Flash via: fastboot flash system out/system.img"
