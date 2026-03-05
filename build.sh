#!/bin/bash
# =============================================================================
# build.sh — Assemble the Ubuntu GSI system image
# =============================================================================
#
# This script packages the system/ directory into a flashable GSI image.
# It is intended to be run on a Linux build host.
#
# Prerequisites:
#   - simg2img / img2simg (from android-tools-fsutils or AOSP)
#   - mke2fs / e2fsdroid (from AOSP)
#   - secilc (from SELinux project, for policy compilation)
#   - make_ext4fs or mke2fs
#
# Usage:
#   ./build.sh [output_image]
#
# Output:
#   ubuntu-gsi-arm64.img (sparse ext4 image, flashable via fastboot)
# =============================================================================

set -euo pipefail

# ---- Configuration ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="${SCRIPT_DIR}/system"
OUTPUT_IMAGE="${1:-${SCRIPT_DIR}/ubuntu-gsi-arm64.img}"
TEMP_DIR="$(mktemp -d)"
IMAGE_SIZE="128M"  # Minimal — no Android framework

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

# ---- Validation ----
log_info "=== Ubuntu GSI Build ==="
log_info "System directory: ${SYSTEM_DIR}"
log_info "Output image:     ${OUTPUT_IMAGE}"

# Verify required files exist
REQUIRED_FILES=(
    "${SYSTEM_DIR}/etc/init/ubuntu-gsi.rc"
    "${SYSTEM_DIR}/etc/lxc/ubuntu/config"
    "${SYSTEM_DIR}/etc/selinux/ubuntu_gsi.cil"
    "${SYSTEM_DIR}/etc/seccomp/ubuntu_container.json"
    "${SYSTEM_DIR}/build.prop"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        log_error "Missing required file: $f"
        exit 1
    fi
done
log_info "All required files present."

# ---- Compile SELinux Policy (if secilc available) ----
if command -v secilc > /dev/null 2>&1; then
    log_info "Compiling SELinux policy..."
    secilc "${SYSTEM_DIR}/etc/selinux/ubuntu_gsi.cil" \
        -o "${SYSTEM_DIR}/etc/selinux/ubuntu_gsi_sepolicy.bin" \
        -M 1 2>/dev/null || {
        log_warn "SELinux policy compilation failed (may need platform policy merge)."
        log_warn "The CIL source file will be included as-is."
    }
else
    log_warn "secilc not found — skipping SELinux policy compilation."
    log_warn "Policy will need to be compiled during AOSP integration."
fi

# ---- Validate JSON ----
if command -v python3 > /dev/null 2>&1; then
    log_info "Validating seccomp profile JSON..."
    python3 -c "
import json, sys
with open('${SYSTEM_DIR}/etc/seccomp/ubuntu_container.json') as f:
    json.load(f)
print('  JSON valid.')
" || {
        log_error "Invalid JSON in seccomp profile!"
        exit 1
    }
else
    log_warn "python3 not found — skipping JSON validation."
fi

# ---- Create ext4 Image ----
log_info "Creating ext4 filesystem image (${IMAGE_SIZE})..."

if command -v mke2fs > /dev/null 2>&1; then
    # Create raw ext4 image
    RAW_IMAGE="${TEMP_DIR}/system_raw.img"

    # Create empty file
    fallocate -l "${IMAGE_SIZE}" "${RAW_IMAGE}" 2>/dev/null || \
        dd if=/dev/zero of="${RAW_IMAGE}" bs=1M count=128 status=none

    # Format as ext4
    mke2fs -t ext4 -b 4096 -L system -M /system \
        -O ^has_journal,^metadata_csum \
        -d "${SYSTEM_DIR}" \
        "${RAW_IMAGE}" 2>/dev/null

    # Convert to sparse image for fastboot
    if command -v img2simg > /dev/null 2>&1; then
        log_info "Converting to sparse image..."
        img2simg "${RAW_IMAGE}" "${OUTPUT_IMAGE}"
    else
        log_warn "img2simg not found — producing raw ext4 image instead."
        cp "${RAW_IMAGE}" "${OUTPUT_IMAGE}"
    fi
else
    log_error "mke2fs not found. Install e2fsprogs:"
    log_error "  apt install e2fsprogs android-sdk-libsparse-utils"
    exit 1
fi

# ---- Summary ----
IMAGE_ACTUAL_SIZE=$(du -sh "${OUTPUT_IMAGE}" | cut -f1)
log_info "=== Build Complete ==="
log_info "Output:  ${OUTPUT_IMAGE}"
log_info "Size:    ${IMAGE_ACTUAL_SIZE}"
log_info ""
log_info "Flash with:"
log_info "  fastboot flash system ${OUTPUT_IMAGE}"
log_info ""
log_info "First boot setup:"
log_info "  adb shell sh /system/scripts/setup-ubuntu.sh"
