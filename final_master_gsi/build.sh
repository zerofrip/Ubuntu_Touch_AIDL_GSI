#!/bin/bash
# =============================================================================
# build.sh (Final Master Orchestrator)
# =============================================================================
# The single terminal target generating the absolute flawless Final Master
# Extensibility Framework outputs natively!
# =============================================================================

set -e

WORKSPACE_DIR="/home/zerof/github/Ubuntu_GSI/final_master_gsi"
ROOTFS_OUT="$WORKSPACE_DIR/out/ubuntu-rootfs"
ROOTFS_TARBALL="$WORKSPACE_DIR/ubuntu-touch-rootfs.tar.gz"

echo ""
echo "============================================================================="
echo "               FINAL MASTER ENHANCED GSI COMPILATION SEQUENCE              "
echo "============================================================================="
echo ""

# Automated RootFS Extraction Phase
echo "[$(date -Iseconds)] [Orchestrator] Initializing Workspace..."
mkdir -p "$WORKSPACE_DIR/out"

if [ -f "$ROOTFS_TARBALL" ]; then
    echo "[$(date -Iseconds)] [Orchestrator] Detected RootFS Tarball: $(basename "$ROOTFS_TARBALL")"
elif [ ! -d "$ROOTFS_OUT" ] || [ -z "$(ls -A "$ROOTFS_OUT")" ]; then
    echo "[$(date -Iseconds)] [Orchestrator] RootFS not found. Attempting automated download..."
    
    # Default UBports Focal arm64 rootfs (Change if needed)
    DOWNLOAD_URL="https://ci.ubports.com/job/ubuntu-touch-rootfs/job/main/lastStableBuild/artifact/ubuntu-touch-android9plus-rootfs-armhf.tar.gz"
    
    if command -v wget >/dev/null 2>&1; then
        wget -O "$ROOTFS_TARBALL" "$DOWNLOAD_URL" || { echo "[$(date -Iseconds)] [Orchestrator] FATAL: Download failed via wget!"; exit 1; }
    elif command -v curl >/dev/null 2>&1; then
        curl -L -o "$ROOTFS_TARBALL" "$DOWNLOAD_URL" || { echo "[$(date -Iseconds)] [Orchestrator] FATAL: Download failed via curl!"; exit 1; }
    else
        echo "[$(date -Iseconds)] [Orchestrator] FATAL: Neither 'wget' nor 'curl' found. Please install one or manually provide the tarball."
        exit 1
    fi
    echo "[$(date -Iseconds)] [Orchestrator] SUCCESS: RootFS downloaded to $ROOTFS_TARBALL"
fi

if [ -f "$ROOTFS_TARBALL" ]; then
    if [ -d "$ROOTFS_OUT" ]; then
        echo "[$(date -Iseconds)] [Orchestrator] WARNING: $ROOTFS_OUT already exists. Purging for clean extraction..."
        rm -rf "$ROOTFS_OUT"
    fi
    
    mkdir -p "$ROOTFS_OUT"
    echo "[$(date -Iseconds)] [Orchestrator] Extracting RootFS... (This may take a minute)"
    tar -xf "$ROOTFS_TARBALL" -C "$ROOTFS_OUT" || { echo "[$(date -Iseconds)] [Orchestrator] FATAL: Extraction failed!"; exit 1; }
    echo "[$(date -Iseconds)] [Orchestrator] SUCCESS: RootFS extracted to $ROOTFS_OUT"
else
    echo "[$(date -Iseconds)] [Orchestrator] NOTICE: Using existing contents in $ROOTFS_OUT"
fi

echo ""

chmod +x "$WORKSPACE_DIR/scripts/rootfs-builder.sh"
chmod +x "$WORKSPACE_DIR/scripts/gsi-pack.sh"

"$WORKSPACE_DIR/scripts/rootfs-builder.sh"
"$WORKSPACE_DIR/scripts/gsi-pack.sh"

echo ""
echo "============================================================================="
echo "[Ultimate Compilation] SUCCESS: All Extensibility Deliverables packed perfectly!"
echo "- Copy out/linux_rootfs.squashfs to /data/ on device."
echo "- Flash out/system.img via Fastboot."
echo "============================================================================="
