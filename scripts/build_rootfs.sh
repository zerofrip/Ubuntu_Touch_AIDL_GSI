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
CORE_APPS_LIST="$REPO_ROOT/rootfs/packages.core-apps.list"
CLICK_CACHE_DIR="${GSI_CLICK_CACHE:-$REPO_ROOT/builder/cache/openstore-clicks}"
CLICK_MISSING_FILE="${GSI_CLICK_MISSING:-$REPO_ROOT/builder/out/core-apps-missing.txt}"
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
OVERLAY_LOWER_DIR="$REPO_ROOT/rootfs/overlay-lower-layer"
GSI_DISPLAY_MODE="${GSI_DISPLAY_MODE:-hwc}"
case "$GSI_DISPLAY_MODE" in
    hwc|lower-layer) ;;
    *) echo "Invalid GSI_DISPLAY_MODE=$GSI_DISPLAY_MODE (use hwc|lower-layer)" >&2; exit 1 ;;
esac
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

unmount_rootfs_chroot() {
    local dir="${1:-$TARGET_DIR}"
    [ -d "$dir" ] || return 0

    # Never fuser -km here: bind-mounted /dev makes fuser match systemd PID 1 and crash WSL.
    local mp
    for mp in \
        "$dir/sys/fs/cgroup" \
        "$dir/sys" \
        "$dir/proc" \
        "$dir/dev/shm" \
        "$dir/dev/mqueue" \
        "$dir/dev/hugepages" \
        "$dir/dev/pts" \
        "$dir/dev"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -l "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
        fi
    done
}

remove_rootfs_dir() {
    local dir="${1:-$TARGET_DIR}"
    unmount_rootfs_chroot "$dir"
    rm -rf "$dir"
}

mount_rootfs_chroot() {
    mount --bind /dev     "$TARGET_DIR/dev"     || true
    mount --bind /dev/pts "$TARGET_DIR/dev/pts" || true
    mount -t proc  proc   "$TARGET_DIR/proc"    || true
    mount -t sysfs sysfs  "$TARGET_DIR/sys"     || true
}

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
    remove_rootfs_dir "$TARGET_DIR"
fi

if [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/etc/os-release" ]; then
    PREV_PROFILE=""
    if [ -f "$ROOTFS_PROFILE_FILE" ]; then
        PREV_PROFILE="$(tr -d '[:space:]' < "$ROOTFS_PROFILE_FILE")"
    fi
    if [ "$PREV_PROFILE" != "$ROOTFS_PROFILE" ]; then
        info "Rootfs profile changed ($PREV_PROFILE -> $ROOTFS_PROFILE) — rebuilding rootfs"
        remove_rootfs_dir "$TARGET_DIR"
    else
        info "Existing rootfs detected — skipping debootstrap"
    fi
fi

if [ ! -d "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/etc/os-release" ]; then
    remove_rootfs_dir "$TARGET_DIR"
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

mkdir -p "$TARGET_DIR/etc/apt/sources.list.d" "$TARGET_DIR/etc/apt/keyrings"
UBPORTS_KEYRING="/etc/apt/keyrings/ubports.gpg"
cat > "$TARGET_DIR/etc/apt/sources.list.d/ubports.list" <<UBEOF
deb [signed-by=${UBPORTS_KEYRING}] http://repo.ubports.com/ focal main
UBEOF

install_ubports_keyring() {
    local dest="$TARGET_DIR${UBPORTS_KEYRING}"
    local tmp
    tmp="$(mktemp -d)"
    if ! command -v gpg >/dev/null 2>&1; then
        error "gpg not found — required to install UBports apt signing keys"
        rm -rf "$tmp"
        exit 1
    fi
    curl -fsSL "http://repo.ubports.com/pubkey.gpg" -o "$tmp/ubports-new.asc" || \
        wget -qO "$tmp/ubports-new.asc" "http://repo.ubports.com/pubkey.gpg" || true
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4BD4B4D6DBB583F1" \
        -o "$tmp/ubports-old.asc" || true
    if [ ! -s "$tmp/ubports-new.asc" ] && [ ! -s "$tmp/ubports-old.asc" ]; then
        error "Could not fetch UBports signing keys"
        rm -rf "$tmp"
        exit 1
    fi
    # InRelease is dual-signed (2026 + legacy keys); merge into one keyring.
    gpg --batch --no-default-keyring --keyring "$tmp/combined.gpg" \
        --import "$tmp/ubports-new.asc" "$tmp/ubports-old.asc" 2>/dev/null || true
    gpg --batch --no-default-keyring --keyring "$tmp/combined.gpg" \
        --export --output "$dest" 2>/dev/null || {
        error "Failed to export UBports keyring"
        rm -rf "$tmp"
        exit 1
    }
    chmod 644 "$dest"
    rm -rf "$tmp"
}
install_ubports_keyring
rm -f "$TARGET_DIR/etc/apt/trusted.gpg.d/ubports-signing.gpg" 2>/dev/null || true

success "apt sources configured (Ubuntu + UBports)"
echo ""

info "Phase 3 — Installing packages"
if [ -n "$CI_MINIMAL_PACKAGES" ]; then
    PACKAGES="systemd systemd-sysv dbus udev sudo bash bash-completion locales ca-certificates network-manager iproute2 openssh-server"
    info "Using minimal package set for CI stability"
else
    PACKAGES=""
    PKG_FILES=()
    [ -f "$PACKAGES_FILE" ] && PKG_FILES+=("$PACKAGES_FILE")
    if [ "$ROOTFS_PROFILE" = "full" ] && [ -f "$CORE_APPS_LIST" ]; then
        PKG_FILES+=("$CORE_APPS_LIST")
    fi
    if [ "${#PKG_FILES[@]}" -gt 0 ]; then
        PACKAGES=$(cat "${PKG_FILES[@]}" | grep -vE '^[[:space:]]*(#|$)' | awk '{print $1}' | sort -u | tr '\n' ' ')
        info "Packages from ${PKG_FILES[*]}: $(echo "$PACKAGES" | wc -w) unique entries"
    else
        PACKAGES="systemd systemd-sysv sudo bash-completion openssh-server"
    fi
fi

mount_rootfs_chroot
CHROOT_MOUNTED=1
trap 'if [ "${CHROOT_MOUNTED:-0}" = "1" ]; then unmount_rootfs_chroot "$TARGET_DIR"; fi' EXIT

# Resolve available packages first — packages.list may contain aspirational names.
# Core Apps (packages.core-apps.list) must all resolve or the build fails.
chroot "$TARGET_DIR" bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
" 

RESOLVED_PACKAGES=""
MISSING_OPTIONAL=""
for pkg in $PACKAGES; do
    if chroot "$TARGET_DIR" apt-cache show "$pkg" >/dev/null 2>&1; then
        RESOLVED_PACKAGES="$RESOLVED_PACKAGES $pkg"
    else
        MISSING_OPTIONAL="$MISSING_OPTIONAL $pkg"
    fi
done
RESOLVED_PACKAGES="$(echo $RESOLVED_PACKAGES | xargs)"
info "Resolvable packages: $(echo "$RESOLVED_PACKAGES" | wc -w)"
if [ -n "$MISSING_OPTIONAL" ]; then
    info "Skipping unavailable packages:$(echo "$MISSING_OPTIONAL" | tr -s ' ')"
    mkdir -p "$(dirname "$CLICK_MISSING_FILE")"
    echo "apt_unavailable:$(echo $MISSING_OPTIONAL)" >> "$CLICK_MISSING_FILE"
fi

# Core Apps must all be resolvable
if [ -z "$CI_MINIMAL_PACKAGES" ] && [ "$ROOTFS_PROFILE" = "full" ] && [ -f "$CORE_APPS_LIST" ]; then
    core_missing=""
    while IFS= read -r pkg || [ -n "$pkg" ]; do
        pkg="${pkg%%#*}"
        pkg="$(echo "$pkg" | tr -d '[:space:]')"
        [ -z "$pkg" ] && continue
        case " $RESOLVED_PACKAGES " in
            *" $pkg "*) ;;
            *) core_missing="$core_missing $pkg" ;;
        esac
    done < "$CORE_APPS_LIST"
    if [ -n "$core_missing" ]; then
        error "FATAL: Core Apps apt packages not in apt indexes:$core_missing"
        exit 1
    fi
fi

# shellcheck disable=SC2086
chroot "$TARGET_DIR" bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends $RESOLVED_PACKAGES
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    test -x /lib/systemd/systemd -o -x /usr/lib/systemd/systemd
"

# Verify Core Apps apt packages are actually present when full profile
if [ -z "$CI_MINIMAL_PACKAGES" ] && [ "$ROOTFS_PROFILE" = "full" ] && [ -f "$CORE_APPS_LIST" ]; then
    info "Verifying Core Apps apt packages from $CORE_APPS_LIST"
    missing_apt=""
    while IFS= read -r pkg || [ -n "$pkg" ]; do
        pkg="${pkg%%#*}"
        pkg="$(echo "$pkg" | tr -d '[:space:]')"
        [ -z "$pkg" ] && continue
        if ! chroot "$TARGET_DIR" dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            missing_apt="$missing_apt $pkg"
        fi
    done < "$CORE_APPS_LIST"
    if [ -n "$missing_apt" ]; then
        error "FATAL: Core Apps apt packages missing after install:$missing_apt"
        exit 1
    fi
    success "Core Apps apt packages verified"
fi

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

HALIUM_DEBS_DIR="$REPO_ROOT/builder/cache/halium-debs"
if [ -d "$HALIUM_DEBS_DIR" ] && ls "$HALIUM_DEBS_DIR"/*.deb >/dev/null 2>&1; then
    info "Phase 3.5 — Installing halium-extras debs"
    mkdir -p "$TARGET_DIR/tmp/halium-debs"
    cp "$HALIUM_DEBS_DIR"/*.deb "$TARGET_DIR/tmp/halium-debs/"
    chroot "$TARGET_DIR" bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        dpkg -i /tmp/halium-debs/*.deb || apt-get install -f -y --no-install-recommends
        rm -rf /tmp/halium-debs
        test -f /usr/lib/aarch64-linux-gnu/libsync.so.2 || test -f /usr/lib/aarch64-linux-gnu/libsync.so
        ls /usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android*.so* >/dev/null
    "
    success "halium-extras debs installed"
else
    info "Phase 3.5 — Skipped (no debs in $HALIUM_DEBS_DIR)"
fi

unmount_rootfs_chroot "$TARGET_DIR"
CHROOT_MOUNTED=0
trap - EXIT

success "Packages installed"
echo ""

info "Phase 4 — Applying overlay (display-mode=$GSI_DISPLAY_MODE)"
if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR"/. "$TARGET_DIR/"
    success "Base overlay applied"
fi
if [ "$GSI_DISPLAY_MODE" = "lower-layer" ] && [ -d "$OVERLAY_LOWER_DIR" ]; then
    cp -a "$OVERLAY_LOWER_DIR"/. "$TARGET_DIR/"
    success "Lower-layer overlay applied"
fi
mkdir -p "$TARGET_DIR/etc/ubuntu-gsi"
printf '%s\n' "$GSI_DISPLAY_MODE" > "$TARGET_DIR/etc/ubuntu-gsi/display-mode"
echo ""

info "Phase 4.5 — Bundling preinstalled OpenStore clicks"
# Fetch Core Apps clicks unless explicitly skipped (missing apps do not abort).
if [ "${GSI_SKIP_CLICK_FETCH:-0}" = "1" ]; then
    info "GSI_SKIP_CLICK_FETCH=1 — skipping OpenStore fetch"
elif [ -x "$REPO_ROOT/scripts/fetch_openstore_clicks.sh" ] || [ -f "$REPO_ROOT/scripts/fetch_openstore_clicks.sh" ]; then
    info "Fetching OpenStore clicks from rootfs/clicks.core-apps.list"
    bash "$REPO_ROOT/scripts/fetch_openstore_clicks.sh" || \
        info "WARN: fetch_openstore_clicks.sh exited non-zero — continuing with cache"
else
    info "fetch_openstore_clicks.sh missing — using cache only"
fi

PRECLICK_DST="$TARGET_DIR/usr/share/ubuntu-gsi/preinstalled-clicks"
DESKTOP_MANIFEST="$TARGET_DIR/usr/share/ubuntu-gsi/preinstalled-click-desktops.list"
mkdir -p "$PRECLICK_DST" "$(dirname "$DESKTOP_MANIFEST")"
: > "$DESKTOP_MANIFEST"
click_count=0
# Only stage clicks named in clicks.core-apps.list (ignore leftover cache files).
CLICK_LIST_FILE="$REPO_ROOT/rootfs/clicks.core-apps.list"
if [ -f "$CLICK_LIST_FILE" ] && [ -d "$CLICK_CACHE_DIR" ]; then
    while IFS= read -r app_id || [ -n "$app_id" ]; do
        app_id="${app_id%%#*}"
        app_id="$(echo "$app_id" | tr -d '[:space:]')"
        [ -z "$app_id" ] && continue
        src="$CLICK_CACHE_DIR/${app_id}_arm64.click"
        if [ -f "$src" ]; then
            cp -a "$src" "$PRECLICK_DST/"
            click_count=$((click_count + 1))
        else
            info "WARN: click not in cache: $app_id"
        fi
    done < "$CLICK_LIST_FILE"
fi
if [ "$click_count" -gt 0 ]; then
    success "Copied $click_count click(s) → /usr/share/ubuntu-gsi/preinstalled-clicks/"
else
    info "No clicks staged (run scripts/fetch_openstore_clicks.sh or unset GSI_SKIP_CLICK_FETCH)"
fi

# Unpack clicks into /opt/click.ubuntu.com so Terminal etc. work without flaky
# `click install` under Android/Halium (SELinux / missing frameworks).
CLICK_OPT="$TARGET_DIR/opt/click.ubuntu.com"
APPS_DST="$TARGET_DIR/usr/share/applications"
mkdir -p "$CLICK_OPT" "$APPS_DST"
unpacked=0

# Make a .desktop visible in the Lomiri app drawer.
tune_drawer_desktop() {
    local desk_file="$1"
    [ -f "$desk_file" ] || return 0
    sed -i \
        -e 's/^NoDisplay=.*/NoDisplay=false/' \
        -e 's/^Hidden=.*/Hidden=false/' \
        "$desk_file" 2>/dev/null || true
    if ! grep -qE '^X-Ubuntu-Touch=' "$desk_file"; then
        printf '\nX-Ubuntu-Touch=true\n' >> "$desk_file"
    fi
}

for c in "$PRECLICK_DST"/*.click; do
    [ -f "$c" ] || continue
    tmp=$(mktemp -d)
    if ! (cd "$tmp" && ar x "$c" data.tar.gz control.tar.gz 2>/dev/null); then
        rm -rf "$tmp"
        continue
    fi
    pkg=$(tar -xOf "$tmp/control.tar.gz" ./control 2>/dev/null | awk -F': ' '/^Package:/{print $2; exit}')
    ver=$(tar -xOf "$tmp/control.tar.gz" ./control 2>/dev/null | awk -F': ' '/^Version:/{print $2; exit}')
    if [ -z "$pkg" ] || [ -z "$ver" ]; then
        rm -rf "$tmp"
        continue
    fi
    dest="$CLICK_OPT/$pkg/$ver"
    mkdir -p "$dest"
    tar -xzf "$tmp/data.tar.gz" -C "$dest"
    ln -sfn "$ver" "$CLICK_OPT/$pkg/current"
    # Desktop files → system applications (Exec paths often assume click cwd)
    while IFS= read -r -d '' desk; do
        base=$(basename "$desk")
        # Rewrite Exec to absolute path under click current when relative
        if grep -q '^Exec=' "$desk"; then
            sed -E "s|^Exec=([^/].*)|Exec=/opt/click.ubuntu.com/$pkg/current/\\1|" "$desk" \
                > "$APPS_DST/$base" || cp -a "$desk" "$APPS_DST/$base"
        else
            cp -a "$desk" "$APPS_DST/$base"
        fi
        # Prefer bin/ from click for PATH-like Exec
        if [ -x "$dest/lib/aarch64-linux-gnu/bin/terminal" ] && [ "$pkg" = "com.ubuntu.terminal" ]; then
            sed -i "s|^Exec=.*|Exec=/opt/click.ubuntu.com/$pkg/current/lib/aarch64-linux-gnu/bin/terminal %u|" \
                "$APPS_DST/$base" 2>/dev/null || true
        fi
        tune_drawer_desktop "$APPS_DST/$base"
        echo "$base" >> "$DESKTOP_MANIFEST"
    done < <(find "$dest" -name '*.desktop' -print0 2>/dev/null)
    rm -rf "$tmp"
    unpacked=$((unpacked + 1))
done
if [ "$unpacked" -gt 0 ]; then
    sort -u -o "$DESKTOP_MANIFEST" "$DESKTOP_MANIFEST"
    success "Unpacked $unpacked click(s) → /opt/click.ubuntu.com/ (+ .desktop)"
fi
mkdir -p "$(dirname "$CLICK_MISSING_FILE")"
if [ -f "$CLICK_MISSING_FILE" ]; then
    cp -a "$CLICK_MISSING_FILE" "$TARGET_DIR/usr/share/ubuntu-gsi/core-apps-missing.txt" 2>/dev/null || true
    info "Click missing list present: $CLICK_MISSING_FILE"
fi
echo ""

info "Phase 5 — Installing systemd units"
if [ -d "$SYSTEMD_DIR" ]; then
    mkdir -p "$TARGET_DIR/etc/systemd/system"
    cp "$SYSTEMD_DIR"/*.service "$TARGET_DIR/etc/systemd/system/" 2>/dev/null || true
    cp "$SYSTEMD_DIR"/*.timer   "$TARGET_DIR/etc/systemd/system/" 2>/dev/null || true

    for svc in lomiri ubuntu-gsi-firstboot ubuntu-gsi-setup-wizard ubuntu-gsi-compat usb-gadget ubuntu-gsi-hal-bringup; do
        if [ -f "$TARGET_DIR/etc/systemd/system/${svc}.service" ]; then
            chroot "$TARGET_DIR" systemctl enable "${svc}.service" 2>/dev/null || true
        fi
    done
    chroot "$TARGET_DIR" systemctl set-default graphical.target 2>/dev/null || true
    info "systemd default target -> graphical.target (Lomiri WantedBy)"
    chmod 0755 "$TARGET_DIR/usr/lib/ubuntu-gsi/hal-enumerate.sh" 2>/dev/null || true
    chmod 0755 "$TARGET_DIR/usr/lib/ubuntu-gsi/hal-capability-router.sh" 2>/dev/null || true
    chmod 0755 "$TARGET_DIR/usr/lib/ubuntu-gsi/hal-kernel-bringup.sh" 2>/dev/null || true
    chmod 0755 "$TARGET_DIR/usr/lib/ubuntu-gsi/hal-aidl-probe.sh" 2>/dev/null || true
    chmod 0755 "$TARGET_DIR/usr/lib/ubuntu-gsi/hal-gpu-bringup.sh" 2>/dev/null || true
    chmod 0755 "$TARGET_DIR/usr/lib/ubuntu-gsi/wifi-bringup.sh" 2>/dev/null || true
    success "Systemd units installed"
fi
echo ""

info "Phase 6 — Installing Halium scaffolding inside the chroot"
mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/compat"
cp -a "$HALIUM_DIR/compat/." "$TARGET_DIR/usr/lib/ubuntu-gsi/compat/"
find "$TARGET_DIR/usr/lib/ubuntu-gsi/compat" -type f -name '*.sh' -exec chmod 0755 {} \;

# Ship HWC2/UI compat + egl_warmup in system.img (flash-only, no /data push).
HALIUM_COMPAT_OUT="$REPO_ROOT/builder/out/halium13-compat"
mkdir -p "$TARGET_DIR/usr/lib/ubuntu-gsi/halium-compat"
_compat_copied=0
for _cf in libui_compat_layer.so libhwc2_compat_layer.so; do
    if [ -f "$HALIUM_COMPAT_OUT/$_cf" ]; then
        cp -f "$HALIUM_COMPAT_OUT/$_cf" "$TARGET_DIR/usr/lib/ubuntu-gsi/halium-compat/$_cf"
        _compat_copied=1
    fi
done
for _extra in hwc_inproc.so hwc_patched.so; do
    if [ -f "$HALIUM_COMPAT_OUT/$_extra" ]; then
        cp -f "$HALIUM_COMPAT_OUT/$_extra" "$TARGET_DIR/usr/lib/ubuntu-gsi/halium-compat/$_extra"
        _compat_copied=1
    fi
done
if [ -f "$REPO_ROOT/builder/out/egl_warmup" ]; then
    install -m 0755 "$REPO_ROOT/builder/out/egl_warmup" \
        "$TARGET_DIR/usr/lib/ubuntu-gsi/halium-compat/egl_warmup"
    _compat_copied=1
elif [ -f "$HALIUM_COMPAT_OUT/egl_warmup" ]; then
    install -m 0755 "$HALIUM_COMPAT_OUT/egl_warmup" \
        "$TARGET_DIR/usr/lib/ubuntu-gsi/halium-compat/egl_warmup"
    _compat_copied=1
fi
if [ "$_compat_copied" = 1 ]; then
    success "halium-compat stubs installed under usr/lib/ubuntu-gsi/halium-compat"
else
    info "halium-compat: no prebuilt stubs (run scripts/build_hwc2_stubs.sh before rootfs)"
fi
unset _cf _extra _compat_copied HALIUM_COMPAT_OUT

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
GSI_DISPLAY_MODE=$GSI_DISPLAY_MODE
EOF3

echo "$ROOTFS_PROFILE" > "$ROOTFS_PROFILE_FILE"

success "Fingerprint written to /etc/ubuntu-gsi-release"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✔  Rootfs build complete: $TARGET_DIR${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Next: bash scripts/build_rootfs_erofs.sh"


