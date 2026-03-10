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

# Replacement for: make_ext4fs -l 512M -s -a system "$OUT_IMG" "$BOOTSTRAP_DIR"
# Step 1: Create a 512MB zero-filled file
dd if=/dev/zero of="$OUT_IMG" bs=1M count=512

# Step 2: Format as ext4 with label 'system' and populate with bootstrap contents
# Sample command: mkfs.ext4 -L system out/system.img -d out/gsi_sys
mkfs.ext4 -L system "$OUT_IMG" -d "$BOOTSTRAP_DIR"

echo "[$(date -Iseconds)] [GSI Packager] SUCCESS: Flashable Final Master Array built cleanly at $OUT_IMG!"
echo "Flash via: fastboot flash system out/system.img"
