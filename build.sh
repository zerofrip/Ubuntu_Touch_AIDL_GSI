#!/bin/bash
# =============================================================================
# build.sh (Master Build Orchestrator)
# =============================================================================
# The single entry point for building the Ubuntu Touch GSI.
# Sequences rootfs extraction, SquashFS compilation, and system.img packaging.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${SCRIPT_DIR}/builder"
ROOTFS_OUT="$WORKSPACE_DIR/out/ubuntu-rootfs"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }
warning() { echo -e "${YELLOW}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }

# ---------------------------------------------------------------------------
# Source configuration
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=config.env
    source "$CONFIG_FILE"
fi

ROOTFS_URL="${ROOTFS_URL:-https://ci.ubports.com/job/ubuntu-touch-rootfs/job/main/lastStableBuild/artifact/ubuntu-touch-android9plus-rootfs-arm64.tar.gz}"
ROOTFS_TARBALL_NAME="${ROOTFS_TARBALL_NAME:-ubuntu-touch-rootfs.tar.gz}"
ROOTFS_TARBALL="${SCRIPT_DIR}/${ROOTFS_TARBALL_NAME}"
SQUASHFS_COMP="${SQUASHFS_COMP:-xz}"
SYSTEM_IMG_SIZE_MB="${SYSTEM_IMG_SIZE_MB:-512}"

BUILD_START=$(date +%s)

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}         Ubuntu GSI — Master Build Sequence                   ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ---------------------------------------------------------------------------
# Phase 0: Environment check (non-blocking, warn only)
# ---------------------------------------------------------------------------
if [ -f "${SCRIPT_DIR}/scripts/check_environment.sh" ]; then
    info "Running environment check..."
    if ! bash "${SCRIPT_DIR}/scripts/check_environment.sh"; then
        warning "Environment check reported issues (see above). Continuing anyway..."
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Phase 1: RootFS Acquisition
# ---------------------------------------------------------------------------
info "Phase 1 — RootFS Acquisition"

mkdir -p "$WORKSPACE_DIR/out"

if [ -f "$ROOTFS_TARBALL" ]; then
    info "Detected RootFS tarball: $(basename "$ROOTFS_TARBALL")"
elif [ ! -d "$ROOTFS_OUT" ] || [ -z "$(ls -A "$ROOTFS_OUT" 2>/dev/null)" ]; then
    info "RootFS not found. Downloading from: $ROOTFS_URL"

    if command -v wget > /dev/null 2>&1; then
        wget -O "$ROOTFS_TARBALL" "$ROOTFS_URL" || { error "FATAL: Download failed via wget!"; exit 1; }
    elif command -v curl > /dev/null 2>&1; then
        curl -L -o "$ROOTFS_TARBALL" "$ROOTFS_URL" || { error "FATAL: Download failed via curl!"; exit 1; }
    else
        error "FATAL: Neither 'wget' nor 'curl' found."
        echo "  Install one: sudo apt install wget"
        echo "  Or manually place the tarball at: $ROOTFS_TARBALL"
        exit 1
    fi
    success "RootFS downloaded to $ROOTFS_TARBALL"
fi

if [ -f "$ROOTFS_TARBALL" ]; then
    if [ -d "$ROOTFS_OUT" ]; then
        warning "Purging existing $ROOTFS_OUT for clean extraction..."
        rm -rf "$ROOTFS_OUT"
    fi

    mkdir -p "$ROOTFS_OUT"
    info "Extracting RootFS... (this may take a minute)"
    tar -xf "$ROOTFS_TARBALL" -C "$ROOTFS_OUT" || { error "FATAL: Extraction failed!"; exit 1; }
    success "RootFS extracted to $ROOTFS_OUT"
else
    info "Using existing rootfs at $ROOTFS_OUT"
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 2: SquashFS Compilation
# ---------------------------------------------------------------------------
info "Phase 2 — SquashFS Compilation"
chmod +x "$WORKSPACE_DIR/scripts/rootfs-builder.sh"
"$WORKSPACE_DIR/scripts/rootfs-builder.sh"

echo ""

# ---------------------------------------------------------------------------
# Phase 3: system.img Packaging
# ---------------------------------------------------------------------------
info "Phase 3 — system.img Packaging"
chmod +x "$WORKSPACE_DIR/scripts/gsi-pack.sh"
"$WORKSPACE_DIR/scripts/gsi-pack.sh"

echo ""

# ---------------------------------------------------------------------------
# Build Summary
# ---------------------------------------------------------------------------
BUILD_END=$(date +%s)
ELAPSED=$((BUILD_END - BUILD_START))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✔  BUILD COMPLETE${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Show artifact sizes
if [ -f "$WORKSPACE_DIR/out/system.img" ]; then
    SIMG_SIZE=$(du -h "$WORKSPACE_DIR/out/system.img" | cut -f1)
    echo -e "  ${CYAN}system.img${NC}            : $SIMG_SIZE"
fi
if [ -f "$WORKSPACE_DIR/out/linux_rootfs.squashfs" ]; then
    RIMG_SIZE=$(du -h "$WORKSPACE_DIR/out/linux_rootfs.squashfs" | cut -f1)
    echo -e "  ${CYAN}linux_rootfs.squashfs${NC}  : $RIMG_SIZE"
fi

echo ""
echo -e "  Elapsed: ${BOLD}${ELAPSED_MIN}m ${ELAPSED_SEC}s${NC}"
echo ""
echo -e "  ${BOLD}Deploy:${NC}"
echo -e "    fastboot flash system builder/out/system.img"
echo -e "    adb push builder/out/linux_rootfs.squashfs /data/"
echo -e "    ${CYAN}— or run: make install${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
