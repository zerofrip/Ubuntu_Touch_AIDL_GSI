#!/bin/bash
# =============================================================================
# build.sh — Halium-style master build orchestrator (AIDL variant)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$SCRIPT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }
warning() { echo -e "${YELLOW}[$(date -Iseconds)]${NC} ${BOLD}[Orchestrator]${NC} $1"; }

CONFIG_FILE="$SCRIPT_DIR/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=config.env
    source "$CONFIG_FILE"
fi

BUILD_START=$(date +%s)

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}     Ubuntu GSI — Halium-style master build (AIDL)            ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ -f "$SCRIPT_DIR/scripts/check_environment.sh" ]; then
    info "Phase 0 — Environment check"
    if ! bash "$SCRIPT_DIR/scripts/check_environment.sh"; then
        warning "Environment check reported issues. Continuing."
    fi
    echo ""
fi

info "Phase 1 — Fetching PHH Treble GSI base"
bash "$SCRIPT_DIR/scripts/fetch_phh_gsi.sh"
echo ""

info "Phase 2 — Building Ubuntu chroot rootfs"
if [ "$(id -u)" -ne 0 ]; then
    info "  (re-invoking with sudo)"
    sudo bash "$SCRIPT_DIR/scripts/build_rootfs.sh"
else
    bash "$SCRIPT_DIR/scripts/build_rootfs.sh"
fi
echo ""

info "Phase 3 — Packing rootfs as erofs"
bash "$SCRIPT_DIR/scripts/build_rootfs_erofs.sh"
echo ""

info "Phase 4 — Generating vbmeta-disabled.img"
bash "$SCRIPT_DIR/scripts/build_vbmeta_disabled.sh"
echo ""

info "Phase 5 — Composing system.img"
if [ "$(id -u)" -ne 0 ]; then
    info "  (re-invoking with sudo for loop-mount)"
    sudo bash "$SCRIPT_DIR/scripts/build_system_img.sh"
else
    bash "$SCRIPT_DIR/scripts/build_system_img.sh"
fi
echo ""

BUILD_END=$(date +%s)
ELAPSED=$((BUILD_END - BUILD_START))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✔  BUILD COMPLETE${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

OUT="$WORKSPACE_DIR/builder/out"
for f in system.img vbmeta-disabled.img linux_rootfs.erofs; do
    if [ -f "$OUT/$f" ]; then
        SZ=$(du -h "$OUT/$f" | cut -f1)
        echo -e "  ${CYAN}$(printf '%-22s' "$f")${NC}: $SZ"
    fi
done

echo ""
echo -e "  Elapsed: ${BOLD}${ELAPSED_MIN}m ${ELAPSED_SEC}s${NC}"
echo ""
echo -e "  ${BOLD}Deploy:${NC}"
echo -e "    fastboot --disable-verity --disable-verification flash vbmeta $OUT/vbmeta-disabled.img"
echo -e "    fastboot flash system $OUT/system.img"
echo -e "    fastboot reboot"
echo -e "    ${CYAN}— or run: make flash${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
