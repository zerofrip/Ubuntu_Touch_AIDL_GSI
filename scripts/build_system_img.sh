#!/bin/bash
# =============================================================================
# scripts/build_system_img.sh — Halium-style system.img builder
# =============================================================================
# Replaces the legacy `gsi-pack.sh`. Produces a flashable `system.img` by:
#   1. Loop-mounting the cached PHH Treble GSI as a read-only base.
#   2. Copying the contents into a writeable staging directory.
#   3. Overlaying our additions:
#        - /system/etc/init/ubuntu-gsi.rc           (init service)
#        - /system/bin/ubuntu-gsi-launcher          (chroot driver)
#        - /system/bin/ubuntu-gsi-stop-android-ui   (SF stopper)
#        - /system/usr/lib/ubuntu-gsi/compat/       (PHH/Treble-style quirks)
#        - /system/usr/share/ubuntu-gsi/rootfs.erofs (the Ubuntu chroot)
#        - /system/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh
#   4. Re-packing the staging directory as ext4 with the `system` label.
#
# Output: builder/out/system.img
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

CACHE_DIR="$REPO_ROOT/builder/cache"
PHH_IMG="$CACHE_DIR/phh-gsi.img"
EROFS_IMG="${EROFS_IMG:-$REPO_ROOT/builder/out/linux_rootfs.erofs}"
HALIUM_DIR="$REPO_ROOT/halium"

OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="${SYSTEM_OUT:-$OUT_DIR/system.img}"
STAGING="$OUT_DIR/system_staging"
PHH_MNT="$OUT_DIR/.phh-mount"

SYSTEM_IMG_SIZE_MB="${SYSTEM_IMG_SIZE_MB:-0}"
SYSTEM_IMG_HEADROOM_MB="${SYSTEM_IMG_HEADROOM_MB:-96}"
SYSTEM_IMG_MIN_MB="${SYSTEM_IMG_MIN_MB:-768}"
SYSTEM_IMG_GROWTH_STEP_MB="${SYSTEM_IMG_GROWTH_STEP_MB:-256}"
SYSTEM_IMG_MAX_RETRIES="${SYSTEM_IMG_MAX_RETRIES:-4}"
ROOTFS_SEED_IN_SYSTEM="${ROOTFS_SEED_IN_SYSTEM:-0}"

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[system.img]${NC} $1"; }

cleanup() {
    if mountpoint -q "$PHH_MNT" 2>/dev/null; then
        umount "$PHH_MNT" || true
    fi
    rmdir "$PHH_MNT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (loop-mount + chown + mkfs require it)."
    error "  sudo bash $0"
    exit 1
fi

if [ ! -f "$PHH_IMG" ]; then
    error "PHH GSI base not found at $PHH_IMG"
    error "  Run: bash scripts/fetch_phh_gsi.sh"
    exit 1
fi

if [ ! -f "$EROFS_IMG" ]; then
    error "Ubuntu rootfs erofs not found at $EROFS_IMG"
    error "  Run: bash scripts/build_rootfs_erofs.sh"
    exit 1
fi

for cmd in mkfs.ext4 e2fsck resize2fs dumpe2fs mount tune2fs; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "$cmd not found — install e2fsprogs"
        exit 1
    }
done

# ---------------------------------------------------------------------------
# Stage 1: extract PHH base
# ---------------------------------------------------------------------------
info "Staging PHH GSI base into $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$PHH_MNT"

mount -o ro,loop "$PHH_IMG" "$PHH_MNT"
cp -a "$PHH_MNT/." "$STAGING/"
umount "$PHH_MNT"
rmdir "$PHH_MNT"

# Some PHH GSIs are a full Android rootfs (nested /system + /init). F8 boots
# that layout (H100). Do NOT flatten — Halium files go under /system/...
if [ -d "$STAGING/system" ] && [ -f "$STAGING/system/build.prop" ]; then
    info "PHH base uses nested /system rootfs — keeping layout (no flatten)"
    SYS_ROOT="$STAGING/system"
else
    info "PHH base is already flat system partition layout"
    SYS_ROOT="$STAGING"
fi

success "PHH base extracted ($(du -sh "$STAGING" | cut -f1))"

# ---------------------------------------------------------------------------
# Stage 2: overlay halium additions
# ---------------------------------------------------------------------------
info "Overlaying Halium scaffolding into $SYS_ROOT"

# init.rc
mkdir -p "$SYS_ROOT/etc/init"
install -m 0644 "$HALIUM_DIR/etc/init/ubuntu-gsi.rc" "$SYS_ROOT/etc/init/ubuntu-gsi.rc"

# Default: Lomiri auto-starts after Android boot_completed (opt out: enable=0).
_prop_files=(
    "$SYS_ROOT/build.prop"
    "$SYS_ROOT/etc/prop.default"
    "$SYS_ROOT/etc/build.prop"
)
_baked=0
for _pf in "${_prop_files[@]}"; do
    if [ -f "$_pf" ]; then
        if ! grep -q '^persist\.ubuntu_gsi\.enable=' "$_pf" 2>/dev/null; then
            printf '\n# Ubuntu GSI: auto-start Lomiri on power-on (set 0 for Android-only)\npersist.ubuntu_gsi.enable=1\n' >> "$_pf"
            info "Baked persist.ubuntu_gsi.enable=1 into ${_pf#"$SYS_ROOT"/}"
        else
            # Force default ON in the image; device persist can still override at runtime.
            sed -i 's/^persist\.ubuntu_gsi\.enable=.*/persist.ubuntu_gsi.enable=1/' "$_pf"
            info "Updated persist.ubuntu_gsi.enable=1 in ${_pf#"$SYS_ROOT"/}"
        fi
        _baked=1
        break
    fi
done
if [ "$_baked" -eq 0 ]; then
    mkdir -p "$SYS_ROOT/etc"
    printf '# Ubuntu GSI: auto-start Lomiri on power-on\npersist.ubuntu_gsi.enable=1\n' > "$SYS_ROOT/etc/prop.default"
    info "Created $SYS_ROOT/etc/prop.default with persist.ubuntu_gsi.enable=1"
fi


# Launcher binaries
mkdir -p "$SYS_ROOT/bin"
install -m 0755 "$HALIUM_DIR/bin/ubuntu-gsi-launcher"        "$SYS_ROOT/bin/ubuntu-gsi-launcher"
install -m 0755 "$HALIUM_DIR/bin/ubuntu-gsi-stop-android-ui" "$SYS_ROOT/bin/ubuntu-gsi-stop-android-ui"

# Compat layer (mirrored to /system/usr/lib/ubuntu-gsi/compat)
mkdir -p "$SYS_ROOT/usr/lib/ubuntu-gsi/compat"
cp -a "$HALIUM_DIR/compat/." "$SYS_ROOT/usr/lib/ubuntu-gsi/compat/"
find "$SYS_ROOT/usr/lib/ubuntu-gsi/compat" -type f -name '*.sh' -exec chmod 0755 {} \;

# Linux rootfs erofs seed for userdata self-heal (optional for size saving)
mkdir -p "$SYS_ROOT/usr/share/ubuntu-gsi"
if [ "$ROOTFS_SEED_IN_SYSTEM" = "1" ]; then
    cp -a "$EROFS_IMG" "$SYS_ROOT/usr/share/ubuntu-gsi/rootfs.erofs"
    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "$SYS_ROOT/usr/share/ubuntu-gsi"
            sha256sum rootfs.erofs > rootfs.erofs.sha256
        )
    fi
    info "Bundled rootfs seed in system image"
else
    info "Skipping rootfs seed in system image (ROOTFS_SEED_IN_SYSTEM=0)"
fi

# Lomiri launch helper (also linked from the Linux rootfs)
mkdir -p "$SYS_ROOT/usr/share/ubuntu-gsi/halium-lomiri"
install -m 0755 "$HALIUM_DIR/lomiri/start-lomiri.sh" \
    "$SYS_ROOT/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh"
install -m 0644 "$HALIUM_DIR/lomiri/README.md" \
    "$SYS_ROOT/usr/share/ubuntu-gsi/halium-lomiri/README.md"


# mkfs.ext4 -d does not infer SELinux labels; unlabeled binaries cannot be
# executed by init (avc: denied { execute } tcontext=unlabeled permissive=0).
label_system_file() {
    local p="$1"
    [ -e "$p" ] || return 0
    if command -v setfattr >/dev/null 2>&1; then
        setfattr -n security.selinux -v 'u:object_r:system_file:s0' "$p" || warn "setfattr failed: $p"
    else
        python3 -c "import os,sys; os.setxattr(sys.argv[1],'security.selinux',b'u:object_r:system_file:s0')" "$p" \
            || warn "setxattr failed: $p"
    fi
}
label_system_file "$SYS_ROOT/bin/ubuntu-gsi-launcher"
label_system_file "$SYS_ROOT/bin/ubuntu-gsi-stop-android-ui"
label_system_file "$SYS_ROOT/etc/init/ubuntu-gsi.rc"
while IFS= read -r -d '' f; do
    label_system_file "$f"
done < <(find "$SYS_ROOT/usr/lib/ubuntu-gsi" "$SYS_ROOT/usr/share/ubuntu-gsi" -type f -print0 2>/dev/null || true)

success "Halium scaffolding overlaid"


# Shrink PHH consumer apps / media for Halium (disable with GSI_SYSTEM_PRUNE=0).
if [ -f "$REPO_ROOT/scripts/prune_phh_system.sh" ]; then
    bash "$REPO_ROOT/scripts/prune_phh_system.sh" "$STAGING"
fi


# ---------------------------------------------------------------------------
# Stage 3: pack ext4 (minimal size)
# ---------------------------------------------------------------------------
if [ "$SYSTEM_IMG_SIZE_MB" -eq 0 ]; then
    SRC_MB=$(du -sm "$STAGING" | cut -f1)
    SYSTEM_IMG_SIZE_MB=$(( SRC_MB + SYSTEM_IMG_HEADROOM_MB ))
    [ "$SYSTEM_IMG_SIZE_MB" -lt "$SYSTEM_IMG_MIN_MB" ] && SYSTEM_IMG_SIZE_MB="$SYSTEM_IMG_MIN_MB"
    info "Auto system.img size: ${SYSTEM_IMG_SIZE_MB}MB (content ${SRC_MB}MB + ${SYSTEM_IMG_HEADROOM_MB}MB headroom, min ${SYSTEM_IMG_MIN_MB}MB)"
fi

rm -f "$OUT_IMG"
mkfs_log="$(mktemp)"
for attempt in $(seq 1 "$SYSTEM_IMG_MAX_RETRIES"); do
    rm -f "$OUT_IMG"
    info "Allocating ${SYSTEM_IMG_SIZE_MB}MB ext4 at $OUT_IMG (attempt $attempt/$SYSTEM_IMG_MAX_RETRIES)"
    truncate -s "${SYSTEM_IMG_SIZE_MB}M" "$OUT_IMG"

    info "Formatting ext4 with content from $STAGING"
    if mkfs.ext4 -L system -O ^metadata_csum -d "$STAGING" "$OUT_IMG" 2>"$mkfs_log"; then
        rm -f "$mkfs_log"
        break
    fi

    if [ "$attempt" -ge "$SYSTEM_IMG_MAX_RETRIES" ]; then
        cat "$mkfs_log" >&2
        rm -f "$mkfs_log"
        error "mkfs.ext4 failed after ${SYSTEM_IMG_MAX_RETRIES} attempts."
        exit 1
    fi

    warn "mkfs.ext4 failed at ${SYSTEM_IMG_SIZE_MB}MB; increasing size by ${SYSTEM_IMG_GROWTH_STEP_MB}MB and retrying."
    SYSTEM_IMG_SIZE_MB=$(( SYSTEM_IMG_SIZE_MB + SYSTEM_IMG_GROWTH_STEP_MB ))
done

# Shrink filesystem to the minimum possible size so release uploads stay small.
info "Minimizing ext4 filesystem footprint"
e2fsck -fy "$OUT_IMG" >/dev/null 2>&1 || true
resize2fs -M "$OUT_IMG" >/dev/null 2>&1 || true

# Trim image file to exact ext4 geometry after resize2fs -M.
BLOCK_SIZE=$(dumpe2fs -h "$OUT_IMG" 2>/dev/null | awk -F': *' '/Block size:/ {print $2; exit}')
BLOCK_COUNT=$(dumpe2fs -h "$OUT_IMG" 2>/dev/null | awk -F': *' '/Block count:/ {print $2; exit}')
if [[ "$BLOCK_SIZE" =~ ^[0-9]+$ ]] && [[ "$BLOCK_COUNT" =~ ^[0-9]+$ ]]; then
    FINAL_BYTES=$((BLOCK_SIZE * BLOCK_COUNT))
    truncate -s "$FINAL_BYTES" "$OUT_IMG"
fi

# Cleanup staging
rm -rf "$STAGING"

OUT_HUMAN=$(du -h "$OUT_IMG" | cut -f1)
success "system.img ready: $OUT_IMG ($OUT_HUMAN)"

# Keep release-named artifact in sync (isolate/flash default to RELEASE_SYSTEM_IMG)
if [ -n "${RELEASE_SYSTEM_IMG:-}" ] && [ "$RELEASE_SYSTEM_IMG" != "system.img" ]; then
    RELEASE_PATH="$OUT_DIR/$RELEASE_SYSTEM_IMG"
    cp -f "$OUT_IMG" "$RELEASE_PATH"
    success "Also wrote $RELEASE_PATH"
fi

echo ""
echo -e "  ${BOLD}Flash with:${NC}"
echo -e "    fastboot flash system $OUT_IMG"
echo -e "    fastboot flash vbmeta_a builder/out/vbmeta-disabled.img"
echo -e "    fastboot flash vbmeta_system_a builder/out/vbmeta-disabled.img"
echo -e "    fastboot reboot"

