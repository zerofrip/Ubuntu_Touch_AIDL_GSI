#!/bin/bash
# =============================================================================
# scripts/build_rootfs.sh — Automated Ubuntu Rootfs Builder
# =============================================================================
# Creates a minimal Ubuntu root filesystem using debootstrap, configures
# apt repositories, installs required packages, and sets up systemd.
#
# Usage:
#   sudo bash scripts/build_rootfs.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source configuration
CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Configuration
TARGET_DIR="$REPO_ROOT/builder/out/ubuntu-rootfs"
ARCH="${ARCH:-arm64}"
SUITE="${UBUNTU_SUITE:-focal}"
MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
PACKAGES_FILE="$REPO_ROOT/rootfs/packages.list"
OVERLAY_DIR="$REPO_ROOT/rootfs/overlay"
SYSTEMD_DIR="$REPO_ROOT/rootfs/systemd"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[Rootfs Builder]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[Rootfs Builder]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[Rootfs Builder]${NC} $1"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (debootstrap requires it)"
    echo "  Usage: sudo bash $0"
    exit 1
fi

# Dependency check
for cmd in debootstrap chroot; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "$cmd not found — install: sudo apt install debootstrap"
        exit 1
    fi
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}         Ubuntu GSI — Rootfs Builder                          ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
info "Architecture : $ARCH"
info "Suite        : $SUITE"
info "Target       : $TARGET_DIR"
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Debootstrap
# ---------------------------------------------------------------------------
info "Phase 1 — Debootstrap ($SUITE for $ARCH)"

if [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/etc/os-release" ]; then
    info "Existing rootfs detected — skipping debootstrap"
else
    rm -rf "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"

    QEMU_ARCH=""
    case "$ARCH" in
        arm64) QEMU_ARCH="aarch64" ;;
        armhf) QEMU_ARCH="arm" ;;
        *)     QEMU_ARCH="" ;;
    esac

    DEBOOTSTRAP_OPTS="--arch=$ARCH --variant=minbase"

    if [ -n "$QEMU_ARCH" ] && [ "$(uname -m)" != "$QEMU_ARCH" ]; then
        info "Cross-architecture build: using qemu-$QEMU_ARCH-static"
        DEBOOTSTRAP_OPTS="$DEBOOTSTRAP_OPTS --foreign"
    fi

    debootstrap $DEBOOTSTRAP_OPTS "$SUITE" "$TARGET_DIR" "$MIRROR"

    # Complete foreign debootstrap if cross-building
    if echo "$DEBOOTSTRAP_OPTS" | grep -q "foreign"; then
        if [ -f "/usr/bin/qemu-${QEMU_ARCH}-static" ]; then
            cp "/usr/bin/qemu-${QEMU_ARCH}-static" "$TARGET_DIR/usr/bin/"
        fi
        chroot "$TARGET_DIR" /debootstrap/debootstrap --second-stage
    fi

    success "Debootstrap complete"
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Configure apt sources
# ---------------------------------------------------------------------------
info "Phase 2 — Configuring apt sources"

cat > "$TARGET_DIR/etc/apt/sources.list" << EOF
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR ${SUITE}-updates main restricted universe multiverse
deb $MIRROR ${SUITE}-security main restricted universe multiverse
EOF

# Add UBports PPA for Lomiri / Ubuntu Touch packages
info "Adding UBports PPA for Lomiri components"
mkdir -p "$TARGET_DIR/etc/apt/sources.list.d"
cat > "$TARGET_DIR/etc/apt/sources.list.d/ubports.list" << 'UBEOF'
deb http://repo.ubports.com/ focal main
UBEOF

# Import UBports GPG keys
mkdir -p "$TARGET_DIR/etc/apt/trusted.gpg.d"

# Key 1: UBports Apt Signing Key (from repo.ubports.com)
if command -v wget >/dev/null 2>&1; then
    wget -qO "$TARGET_DIR/etc/apt/trusted.gpg.d/ubports-signing.gpg" \
        "http://repo.ubports.com/pubkey.gpg" 2>/dev/null || \
        info "WARNING: Could not fetch UBports signing key from repo"
fi

# Key 2: UBports build key (from Ubuntu keyserver)
if command -v gpg >/dev/null 2>&1; then
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 4BD4B4D6DBB583F1 2>/dev/null && \
    gpg --export 4BD4B4D6DBB583F1 > "$TARGET_DIR/etc/apt/trusted.gpg.d/ubports-build.gpg" 2>/dev/null || \
        info "WARNING: Could not fetch UBports build key from keyserver"
fi

success "apt sources configured (including UBports PPA)"
echo ""

# ---------------------------------------------------------------------------
# Phase 3: Install packages
# ---------------------------------------------------------------------------
info "Phase 3 — Installing packages"

# Read package list (skip comments and empty lines)
PACKAGES=""
if [ -f "$PACKAGES_FILE" ]; then
    PACKAGES=$(grep -v '^#' "$PACKAGES_FILE" | grep -v '^$' | tr '\n' ' ')
    info "Packages from $PACKAGES_FILE: $(echo "$PACKAGES" | wc -w) packages"
else
    info "No packages.list found — installing minimal set"
    PACKAGES="systemd systemd-sysv sudo bash-completion openssh-server"
fi

# Mount necessary filesystems for chroot
mount --bind /dev "$TARGET_DIR/dev" || true
mount --bind /dev/pts "$TARGET_DIR/dev/pts" || true
mount -t proc proc "$TARGET_DIR/proc" || true
mount -t sysfs sysfs "$TARGET_DIR/sys" || true

# Update and install packages
chroot "$TARGET_DIR" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends $PACKAGES
    apt-get clean
    rm -rf /var/lib/apt/lists/*
"

# Unmount
umount "$TARGET_DIR/sys" 2>/dev/null || true
umount "$TARGET_DIR/proc" 2>/dev/null || true
umount "$TARGET_DIR/dev/pts" 2>/dev/null || true
umount "$TARGET_DIR/dev" 2>/dev/null || true

success "Packages installed"
echo ""

# ---------------------------------------------------------------------------
# Phase 4: Apply overlay files
# ---------------------------------------------------------------------------
info "Phase 4 — Applying overlay"

if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR"/. "$TARGET_DIR/"
    success "Overlay applied from $OVERLAY_DIR"
else
    info "No overlay directory found — skipping"
fi

# ---------------------------------------------------------------------------
# Phase 5: Install systemd units
# ---------------------------------------------------------------------------
info "Phase 5 — Installing systemd units"

if [ -d "$SYSTEMD_DIR" ]; then
    mkdir -p "$TARGET_DIR/etc/systemd/system"
    cp "$SYSTEMD_DIR"/*.service "$TARGET_DIR/etc/systemd/system/" 2>/dev/null || true
    cp "$SYSTEMD_DIR"/*.timer "$TARGET_DIR/etc/systemd/system/" 2>/dev/null || true

    # Enable services
    for service in binder-bridge ubuntu-gsi-compat lomiri ubuntu-gsi-firstboot ubuntu-gsi-setup-wizard usb-gadget; do
        if [ -f "$TARGET_DIR/etc/systemd/system/${service}.service" ]; then
            chroot "$TARGET_DIR" systemctl enable "${service}.service" 2>/dev/null || true
            info "Enabled: ${service}.service"
        fi
    done

    success "Systemd units installed"
else
    info "No systemd directory found — skipping"
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 6: Install Ubuntu GSI components
# ---------------------------------------------------------------------------
info "Phase 6 — Installing Ubuntu GSI components"

# Install AIDL HAL layer
if [ -d "$REPO_ROOT/aidl" ]; then
    mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/aidl"
    cp -r "$REPO_ROOT/aidl/"* "$TARGET_DIR/usr/lib/ubuntu-gsi/aidl/"
    info "AIDL HAL layer installed"
fi

# Install binder bridge
if [ -d "$REPO_ROOT/binder" ]; then
    mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/binder"
    cp -r "$REPO_ROOT/binder/"* "$TARGET_DIR/usr/lib/ubuntu-gsi/binder/"
    chmod +x "$TARGET_DIR/usr/lib/ubuntu-gsi/binder/"*.sh
    info "Binder bridge installed"
fi

# Install GUI launcher
if [ -d "$REPO_ROOT/gui" ]; then
    mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/gui"
    cp -r "$REPO_ROOT/gui/"* "$TARGET_DIR/usr/lib/ubuntu-gsi/gui/"
    chmod +x "$TARGET_DIR/usr/lib/ubuntu-gsi/gui/"*.sh 2>/dev/null || true
    info "GUI components installed"
fi

# Firstboot script
if [ -f "$TARGET_DIR/usr/lib/ubuntu-gsi/firstboot.sh" ]; then
    chmod +x "$TARGET_DIR/usr/lib/ubuntu-gsi/firstboot.sh"
fi

# Setup wizard script
if [ -f "$TARGET_DIR/usr/lib/ubuntu-gsi/setup-wizard.sh" ]; then
    chmod +x "$TARGET_DIR/usr/lib/ubuntu-gsi/setup-wizard.sh"
fi

# PHH/TrebleDroid-style compat layer (quirks.json + compat-engine.sh)
if [ -d "$TARGET_DIR/usr/lib/ubuntu-gsi/compat" ]; then
    find "$TARGET_DIR/usr/lib/ubuntu-gsi/compat" -type f -name '*.sh' \
        -exec chmod +x {} \;
    info "Compatibility engine installed (PHH/TrebleDroid-style quirk DB)"
fi

success "Ubuntu GSI components installed"
echo ""

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✔  Rootfs build complete: $TARGET_DIR${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
