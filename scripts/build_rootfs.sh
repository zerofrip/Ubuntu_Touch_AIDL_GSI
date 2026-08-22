#!/bin/bash
# =============================================================================
# scripts/build_rootfs.sh — Ubuntu chroot rootfs builder (Halium-style)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

TARGET_DIR="$REPO_ROOT/builder/out/ubuntu-rootfs"
ARCH="${ARCH:-arm64}"
SUITE="${UBUNTU_SUITE:-focal}"
MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
PACKAGES_FILE="$REPO_ROOT/rootfs/packages.list"
ROOTFS_PROFILE="${GSI_ROOTFS_PROFILE:-full}"
if [ "$ROOTFS_PROFILE" = "minimal" ]; then
    PACKAGES_FILE="$REPO_ROOT/rootfs/packages.minimal.list"
fi
ROOTFS_PRUNE_LEVEL="${GSI_ROOTFS_PRUNE_LEVEL:-}"
if [ -z "$ROOTFS_PRUNE_LEVEL" ] && [ "$ROOTFS_PROFILE" = "minimal" ]; then
    ROOTFS_PRUNE_LEVEL="aggressive"
fi
ROOTFS_PROFILE_FILE="$TARGET_DIR/.gsi-rootfs-profile"
FORCE_REBUILD_ROOTFS="${GSI_FORCE_REBUILD_ROOTFS:-0}"
OVERLAY_DIR="$REPO_ROOT/rootfs/overlay"
SYSTEMD_DIR="$REPO_ROOT/rootfs/systemd"
HALIUM_DIR="$REPO_ROOT/halium"

# CI builds should be stable and fast; full Lomiri stacks can be unavailable
# on public CI mirrors, so default to minimal package set under CI.
CI_MINIMAL_PACKAGES="${GSI_CI_MINIMAL_PACKAGES:-}"
if [ -z "$CI_MINIMAL_PACKAGES" ] && [ "${CI:-}" = "true" ]; then
    CI_MINIMAL_PACKAGES=1
fi

if [ -n "${GSI_VARIANT:-}" ]; then
    VARIANT="$GSI_VARIANT"
else
    case "$(basename "$REPO_ROOT")" in
        *AIDL*) VARIANT="aidl" ;;
        *)      VARIANT="hidl" ;;
    esac
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[Rootfs]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[Rootfs]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[Rootfs]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (debootstrap requires it)."
    error "  sudo bash $0"
    exit 1
fi

for cmd in debootstrap chroot; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "$cmd not found — install: sudo apt install debootstrap"
        exit 1
    }
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}         Ubuntu GSI — Halium-style chroot rootfs builder      ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
info "Variant      : $VARIANT"
info "Architecture : $ARCH"
info "Suite        : $SUITE"
info "Target       : $TARGET_DIR"
[ "$ROOTFS_PROFILE" = "minimal" ] && info "Profile      : minimal"
[ -n "$ROOTFS_PRUNE_LEVEL" ] && info "Prune level  : $ROOTFS_PRUNE_LEVEL"
[ -n "$CI_MINIMAL_PACKAGES" ] && info "CI mode      : minimal package set"
echo ""

info "Phase 1 — Debootstrap ($SUITE for $ARCH)"
if [ "$FORCE_REBUILD_ROOTFS" = "1" ] && [ -d "$TARGET_DIR" ]; then
    info "GSI_FORCE_REBUILD_ROOTFS=1 — removing existing rootfs"
    rm -rf "$TARGET_DIR"
fi

if [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/etc/os-release" ]; then
    PREV_PROFILE=""
    if [ -f "$ROOTFS_PROFILE_FILE" ]; then
        PREV_PROFILE="$(tr -d '[:space:]' < "$ROOTFS_PROFILE_FILE")"
    fi
    if [ "$PREV_PROFILE" != "$ROOTFS_PROFILE" ]; then
        info "Rootfs profile changed ($PREV_PROFILE -> $ROOTFS_PROFILE) — rebuilding rootfs"
        rm -rf "$TARGET_DIR"
    else
        info "Existing rootfs detected — skipping debootstrap"
    fi
fi

if [ ! -d "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/etc/os-release" ]; then
    rm -rf "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"

    QEMU_ARCH=""
    case "$ARCH" in
        arm64) QEMU_ARCH="aarch64" ;;
        armhf) QEMU_ARCH="arm" ;;
    esac

    DEBOOTSTRAP_OPTS="--arch=$ARCH --variant=minbase"
    if [ -n "$QEMU_ARCH" ] && [ "$(uname -m)" != "$QEMU_ARCH" ]; then
        info "Cross-architecture build via qemu-$QEMU_ARCH-static"
        DEBOOTSTRAP_OPTS="$DEBOOTSTRAP_OPTS --foreign"
    fi

    # shellcheck disable=SC2086
    debootstrap $DEBOOTSTRAP_OPTS "$SUITE" "$TARGET_DIR" "$MIRROR"

    if echo "$DEBOOTSTRAP_OPTS" | grep -q "foreign"; then
        QEMU_STATIC="/usr/bin/qemu-${QEMU_ARCH}-static"
        if [ -f "$QEMU_STATIC" ]; then
            cp "$QEMU_STATIC" "$TARGET_DIR/usr/bin/"
        else
            error "$QEMU_STATIC not found. Install qemu-user-static."
            exit 1
        fi

        if ! chroot "$TARGET_DIR" /debootstrap/debootstrap --second-stage; then
            info "Second stage failed (likely missing binfmt); retrying via explicit qemu"
            chroot "$TARGET_DIR" "/usr/bin/qemu-${QEMU_ARCH}-static" /bin/sh /debootstrap/debootstrap --second-stage
        fi
    fi

    success "Debootstrap complete"
fi
echo ""

info "Phase 2 — Configuring apt sources"
cat > "$TARGET_DIR/etc/apt/sources.list" << EOF2
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR ${SUITE}-updates main restricted universe multiverse
deb $MIRROR ${SUITE}-security main restricted universe multiverse
EOF2

mkdir -p "$TARGET_DIR/etc/apt/sources.list.d" "$TARGET_DIR/etc/apt/trusted.gpg.d"
cat > "$TARGET_DIR/etc/apt/sources.list.d/ubports.list" <<'UBEOF'
deb http://repo.ubports.com/ focal main
UBEOF

if command -v wget >/dev/null 2>&1; then
    wget -qO "$TARGET_DIR/etc/apt/trusted.gpg.d/ubports-signing.gpg" \
        "http://repo.ubports.com/pubkey.gpg" 2>/dev/null || \
        info "WARNING: Could not fetch UBports signing key"
fi

success "apt sources configured (Ubuntu + UBports)"
echo ""

info "Phase 3 — Installing packages"
if [ -n "$CI_MINIMAL_PACKAGES" ]; then
    PACKAGES="systemd systemd-sysv dbus udev sudo bash bash-completion locales ca-certificates network-manager iproute2 openssh-server"
    info "Using minimal package set for CI stability"
else
    PACKAGES=""
    if [ -f "$PACKAGES_FILE" ]; then
        PACKAGES=$(grep -v '^#' "$PACKAGES_FILE" | grep -v '^$' | tr '\n' ' ')
        info "Packages from $PACKAGES_FILE: $(echo "$PACKAGES" | wc -w) entries"
    else
        PACKAGES="systemd systemd-sysv sudo bash-completion openssh-server"
    fi
fi

mount --bind /dev     "$TARGET_DIR/dev"     || true
mount --bind /dev/pts "$TARGET_DIR/dev/pts" || true
mount -t proc  proc   "$TARGET_DIR/proc"    || true
mount -t sysfs sysfs  "$TARGET_DIR/sys"     || true

# shellcheck disable=SC2086
chroot "$TARGET_DIR" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends $PACKAGES
    apt-get clean
    rm -rf /var/lib/apt/lists/*
"

if [ -n "$ROOTFS_PRUNE_LEVEL" ]; then
    info "Applying rootfs prune rules ($ROOTFS_PRUNE_LEVEL)"
    chroot "$TARGET_DIR" bash -c "
        set -e
        case \"$ROOTFS_PRUNE_LEVEL\" in
            aggressive)
                rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/lintian/* /usr/share/bug/*
                find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
                    ! -name 'en' ! -name 'en_US' ! -name 'en_US.UTF-8' ! -name 'ja' ! -name 'ja_JP' ! -name 'ja_JP.UTF-8' \
                    -exec rm -rf {} +
                ;;
            standard)
                rm -rf /usr/share/doc/* /usr/share/man/*
                ;;
            *)
                ;;
        esac
    "
fi

umount "$TARGET_DIR/sys"     2>/dev/null || true
umount "$TARGET_DIR/proc"    2>/dev/null || true
umount "$TARGET_DIR/dev/pts" 2>/dev/null || true
umount "$TARGET_DIR/dev"     2>/dev/null || true

success "Packages installed"
echo ""

info "Phase 4 — Applying overlay"
if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR"/. "$TARGET_DIR/"
    success "Overlay applied"
fi
echo ""

info "Phase 5 — Installing systemd units"
if [ -d "$SYSTEMD_DIR" ]; then
    mkdir -p "$TARGET_DIR/etc/systemd/system"
    cp "$SYSTEMD_DIR"/*.service "$TARGET_DIR/etc/systemd/system/" 2>/dev/null || true
    cp "$SYSTEMD_DIR"/*.timer   "$TARGET_DIR/etc/systemd/system/" 2>/dev/null || true

    for svc in lomiri ubuntu-gsi-firstboot ubuntu-gsi-setup-wizard ubuntu-gsi-compat usb-gadget; do
        if [ -f "$TARGET_DIR/etc/systemd/system/${svc}.service" ]; then
            chroot "$TARGET_DIR" systemctl enable "${svc}.service" 2>/dev/null || true
        fi
    done
    success "Systemd units installed"
fi
echo ""

info "Phase 6 — Installing Halium scaffolding inside the chroot"
mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/compat"
cp -a "$HALIUM_DIR/compat/." "$TARGET_DIR/usr/lib/ubuntu-gsi/compat/"
find "$TARGET_DIR/usr/lib/ubuntu-gsi/compat" -type f -name '*.sh' -exec chmod 0755 {} \;

mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/halium"
install -m 0755 "$HALIUM_DIR/lomiri/start-lomiri.sh" \
    "$TARGET_DIR/usr/lib/ubuntu-gsi/halium/start-lomiri.sh"

for f in firstboot.sh setup-wizard.sh usb-gadget.sh; do
    [ -f "$TARGET_DIR/usr/lib/ubuntu-gsi/$f" ] && chmod +x "$TARGET_DIR/usr/lib/ubuntu-gsi/$f"
done

if [ -d "$REPO_ROOT/gui" ]; then
    mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/gui"
    cp -r "$REPO_ROOT/gui/"* "$TARGET_DIR/usr/lib/ubuntu-gsi/gui/"
    chmod +x "$TARGET_DIR/usr/lib/ubuntu-gsi/gui/"*.sh 2>/dev/null || true
fi

success "Halium scaffolding installed"
echo ""

info "Phase 7 — Stamping rootfs fingerprint"
cat > "$TARGET_DIR/etc/ubuntu-gsi-release" <<EOF3
GSI_VARIANT=$VARIANT
GSI_BUILD_DATE=$(date -Iseconds)
GSI_UBUNTU_SUITE=$SUITE
GSI_ARCH=$ARCH
GSI_ARCH_MODEL=halium-inverse
GSI_ROOTFS_PROFILE=$ROOTFS_PROFILE
EOF3

echo "$ROOTFS_PROFILE" > "$ROOTFS_PROFILE_FILE"

success "Fingerprint written to /etc/ubuntu-gsi-release"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✔  Rootfs build complete: $TARGET_DIR${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Next: bash scripts/build_rootfs_erofs.sh"
