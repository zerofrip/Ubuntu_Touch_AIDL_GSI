#!/usr/bin/env bash
# =============================================================================
# build_dual_system_imgs.sh — Build HWC + lower-layer system.img pair
# =============================================================================
# Preferred: sudo rootfs → erofs → system (full).
# Fallback (no passwordless sudo): clone existing system.img and inject
#   /system/etc/ubuntu-gsi/display-mode + updated start-lomiri via debugfs.
#
# Usage:
#   GSI_FORCE_REBUILD_ROOTFS=1 bash scripts/build_dual_system_imgs.sh
#   bash scripts/build_dual_system_imgs.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/scripts/load_vendor_config.sh" 2>/dev/null || true
if [ -f "$REPO/config.env" ]; then
    # shellcheck source=/dev/null
    source "$REPO/config.env"
fi

OUT="$REPO/builder/out"
ROOTFS="${ROOTFS_DIR:-$OUT/ubuntu-rootfs}"
VER="${VENDOR_ANDROID_VERSION:-android-16.0}"
HWC_IMG="${RELEASE_SYSTEM_IMG:-${VER}_system.img}"
LL_IMG="${VER}_system_lower-layer.img"
HWC_EROFS="$OUT/linux_rootfs_hwc.erofs"
LL_EROFS="$OUT/linux_rootfs_lower-layer.erofs"
DEF_EROFS="$OUT/linux_rootfs.erofs"
BASE_SYS="${DUAL_BASE_SYSTEM_IMG:-$OUT/system.img}"
[ -f "$BASE_SYS" ] || BASE_SYS="$OUT/$HWC_IMG"

log() { echo "[dual-system] $*"; }

have_sudo() { sudo -n true 2>/dev/null; }

inject_flavor() {
    local src="$1" dest="$2" mode="$3"
    local tmpdir stamp_file start_src
    tmpdir=$(mktemp -d)
    stamp_file="$tmpdir/display-mode"
    printf '%s\n' "$mode" >"$stamp_file"
    start_src="$REPO/halium/lomiri/start-lomiri.sh"

    cp -f "$src" "$dest"
    # Ensure destination dirs exist inside image
    debugfs -w "$dest" -R 'mkdir /system' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R 'mkdir /system/etc' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R 'mkdir /system/etc/ubuntu-gsi' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R "rm /system/etc/ubuntu-gsi/display-mode" >/dev/null 2>&1 || true
    debugfs -w "$dest" -R "write $stamp_file /system/etc/ubuntu-gsi/display-mode" >/dev/null
    # Refresh Lomiri helper on system partition (outside erofs)
    debugfs -w "$dest" -R 'mkdir /system/usr' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R 'mkdir /system/usr/share' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R 'mkdir /system/usr/share/ubuntu-gsi' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R 'mkdir /system/usr/share/ubuntu-gsi/halium-lomiri' >/dev/null 2>&1 || true
    debugfs -w "$dest" -R "rm /system/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh" >/dev/null 2>&1 || true
    debugfs -w "$dest" -R "write $start_src /system/usr/share/ubuntu-gsi/halium-lomiri/start-lomiri.sh" >/dev/null
    # Refresh launcher (binds display-mode + system start-lomiri into chroot)
    launch_src="$REPO/halium/bin/ubuntu-gsi-launcher"
    if [ -f "$launch_src" ]; then
        debugfs -w "$dest" -R "rm /system/bin/ubuntu-gsi-launcher" >/dev/null 2>&1 || true
        debugfs -w "$dest" -R "write $launch_src /system/bin/ubuntu-gsi-launcher" >/dev/null
    fi
    rm -rf "$tmpdir"
    # Verify
    local got
    got=$(debugfs -R 'cat /system/etc/ubuntu-gsi/display-mode' "$dest" 2>/dev/null | tr -d '\r\n' || true)
    if [ "$got" != "$mode" ]; then
        log "ERROR: inject verify failed for $dest (got='$got' want='$mode')"
        exit 1
    fi
    log "Injected display-mode=$mode into $dest"
}

build_full_sudo() {
    log "Using full sudo rootfs→erofs→system path"
    export GSI_DISPLAY_MODE=hwc
    if [ "${GSI_FORCE_REBUILD_ROOTFS:-0}" = "1" ] || [ ! -d "$ROOTFS/usr" ]; then
        sudo -n --preserve-env=GSI_FORCE_REBUILD_ROOTFS,GSI_ROOTFS_PROFILE,GSI_DISPLAY_MODE \
            bash "$REPO/scripts/build_rootfs.sh"
    else
        sudo -n cp -a "$REPO/rootfs/overlay"/. "$ROOTFS/"
        printf 'hwc\n' | sudo -n tee "$ROOTFS/etc/ubuntu-gsi/display-mode" >/dev/null
        sudo -n install -m 0755 "$REPO/halium/lomiri/start-lomiri.sh" \
            "$ROOTFS/usr/lib/ubuntu-gsi/halium/start-lomiri.sh"
    fi
    sudo -n env EROFS_OUT="$HWC_EROFS" bash "$REPO/scripts/build_rootfs_erofs.sh"
    cp -f "$HWC_EROFS" "$DEF_EROFS"
    sudo -n env EROFS_IMG="$HWC_EROFS" SYSTEM_OUT="$OUT/system.img" \
        RELEASE_SYSTEM_IMG="$HWC_IMG" bash "$REPO/scripts/build_system_img.sh"
    cp -f "$OUT/system.img" "$OUT/$HWC_IMG"

    sudo -n cp -a "$REPO/rootfs/overlay"/. "$ROOTFS/"
    sudo -n cp -a "$REPO/rootfs/overlay-lower-layer"/. "$ROOTFS/"
    printf 'lower-layer\n' | sudo -n tee "$ROOTFS/etc/ubuntu-gsi/display-mode" >/dev/null
    sudo -n install -m 0755 "$REPO/halium/lomiri/start-lomiri.sh" \
        "$ROOTFS/usr/lib/ubuntu-gsi/halium/start-lomiri.sh"
    sudo -n env EROFS_OUT="$LL_EROFS" bash "$REPO/scripts/build_rootfs_erofs.sh"
    sudo -n env EROFS_IMG="$LL_EROFS" SYSTEM_OUT="$OUT/system_lower-layer.img" \
        RELEASE_SYSTEM_IMG="$LL_IMG" bash "$REPO/scripts/build_system_img.sh"
    cp -f "$OUT/system_lower-layer.img" "$OUT/$LL_IMG"
    cp -f "$HWC_EROFS" "$DEF_EROFS"
}

build_debugfs_fallback() {
    log "No passwordless sudo — using debugfs inject fallback on $BASE_SYS"
    if [ ! -f "$BASE_SYS" ]; then
        log "ERROR: base system image missing: $BASE_SYS"
        exit 1
    fi
    if ! command -v debugfs >/dev/null 2>&1; then
        log "ERROR: debugfs required for fallback"
        exit 1
    fi
    inject_flavor "$BASE_SYS" "$OUT/$HWC_IMG" "hwc"
    inject_flavor "$BASE_SYS" "$OUT/$LL_IMG" "lower-layer"
    # Keep conventional names
    cp -f "$OUT/$HWC_IMG" "$OUT/system.img"
    cp -f "$OUT/$LL_IMG" "$OUT/system_lower-layer.img"
    # erofs copies: keep existing as hwc placeholder if present
    if [ -f "$DEF_EROFS" ]; then
        cp -f "$DEF_EROFS" "$HWC_EROFS" 2>/dev/null || true
    fi
    printf 'debugfs-fallback\n' >"$OUT/dual_system_build_method.txt"
}

mkdir -p "$OUT"
if [ ! -f "$REPO/builder/cache/phh-gsi.img" ] && [ ! -f "$BASE_SYS" ]; then
    log "ERROR: need phh-gsi.img or an existing system.img"
    exit 1
fi

if have_sudo; then
    build_full_sudo
    printf 'sudo-full\n' >"$OUT/dual_system_build_method.txt"
else
    build_debugfs_fallback
fi

log "=== Done ==="
ls -lh "$OUT/$HWC_IMG" "$OUT/$LL_IMG"
echo "method=$(cat "$OUT/dual_system_build_method.txt")"
echo "Flash lower-layer:"
echo "  RELEASE_SYSTEM_IMG=$LL_IMG bash scripts/flash.sh --system-only"
