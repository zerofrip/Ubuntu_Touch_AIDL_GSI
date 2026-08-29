#!/bin/bash
# =============================================================================
# scripts/build_phh_vanilla_flat.sh — Flatten PHH GSI without Halium overlay
# =============================================================================
# Isolation image: same layout as production system.img but NO ubuntu-gsi.*
# Flash with empty vbmeta flags=3 to test if PHH alone boots on F8.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE_DIR="$REPO_ROOT/builder/cache"
PHH_IMG="$CACHE_DIR/phh-gsi.img"
OUT_DIR="$REPO_ROOT/builder/out"
OUT_IMG="$OUT_DIR/phh-vanilla-flat.img"
STAGING="$OUT_DIR/phh_vanilla_staging"
PHH_MNT="$OUT_DIR/.phh-vanilla-mount"


[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
[ -f "$PHH_IMG" ] || { echo "Missing $PHH_IMG — run: bash scripts/fetch_phh_gsi.sh"; exit 1; }

cleanup() {
    mountpoint -q "$PHH_MNT" 2>/dev/null && umount "$PHH_MNT" || true
    rmdir "$PHH_MNT" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$STAGING"
mkdir -p "$STAGING" "$PHH_MNT" "$OUT_DIR"
mount -o ro,loop "$PHH_IMG" "$PHH_MNT"
cp -a "$PHH_MNT/." "$STAGING/"
umount "$PHH_MNT"
rmdir "$PHH_MNT"

# Flatten /system subtree (same as build_system_img.sh)
if [ -d "$STAGING/system" ] && [ -f "$STAGING/system/build.prop" ]; then
    echo "[vanilla] Flattening /system subtree"
    mv "$STAGING/system" "$STAGING/.flat"
    rm -rf "${STAGING:?}"/* 2>/dev/null || true
    mv "$STAGING/.flat"/* "$STAGING/"
    rmdir "$STAGING/.flat"
fi

[ -f "$STAGING/build.prop" ] || { echo "FATAL: no build.prop after flatten"; exit 1; }

HEADROOM_MB="${SYSTEM_IMG_HEADROOM_MB:-96}"
MIN_MB="${SYSTEM_IMG_MIN_MB:-768}"
GROWTH_STEP_MB="${SYSTEM_IMG_GROWTH_STEP_MB:-256}"
MAX_RETRIES="${SYSTEM_IMG_MAX_RETRIES:-4}"

SRC_MB=$(du -sm "$STAGING" | cut -f1)
SIZE_MB=$(( SRC_MB + HEADROOM_MB ))
[ "$SIZE_MB" -lt "$MIN_MB" ] && SIZE_MB="$MIN_MB"
echo "[vanilla] Auto size: ${SIZE_MB}MB (content ${SRC_MB}MB + ${HEADROOM_MB}MB headroom)"

mkfs_log="$(mktemp)"
for attempt in $(seq 1 "$MAX_RETRIES"); do
    rm -f "$OUT_IMG"
    echo "[vanilla] Allocating ${SIZE_MB}MB ext4 (attempt $attempt/$MAX_RETRIES)"
    truncate -s "${SIZE_MB}M" "$OUT_IMG"
    if mkfs.ext4 -L system -O ^metadata_csum -d "$STAGING" "$OUT_IMG" 2>"$mkfs_log"; then
        rm -f "$mkfs_log"
        break
    fi
    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
        cat "$mkfs_log" >&2
        rm -f "$mkfs_log"
        echo "[vanilla] FATAL: mkfs.ext4 failed after ${MAX_RETRIES} attempts"
        exit 1
    fi
    echo "[vanilla] mkfs.ext4 failed at ${SIZE_MB}MB; +${GROWTH_STEP_MB}MB and retrying"
    SIZE_MB=$(( SIZE_MB + GROWTH_STEP_MB ))
done

e2fsck -fy "$OUT_IMG" >/dev/null 2>&1 || true
resize2fs -M "$OUT_IMG" >/dev/null 2>&1 || true
BLOCK_SIZE=$(dumpe2fs -h "$OUT_IMG" 2>/dev/null | awk -F': *' '/Block size:/ {print $2; exit}')
BLOCK_COUNT=$(dumpe2fs -h "$OUT_IMG" 2>/dev/null | awk -F': *' '/Block count:/ {print $2; exit}')
if [[ "$BLOCK_SIZE" =~ ^[0-9]+$ ]] && [[ "$BLOCK_COUNT" =~ ^[0-9]+$ ]]; then
    truncate -s "$((BLOCK_SIZE * BLOCK_COUNT))" "$OUT_IMG"
fi

rm -rf "$STAGING"
# shellcheck disable=SC2034
has_ubuntu=$(debugfs -R "stat /etc/init/ubuntu-gsi.rc" "$OUT_IMG" 2>&1 | grep -c "Inode:" || true)
# shellcheck disable=SC2034
has_prop=$(debugfs -R "stat /build.prop" "$OUT_IMG" 2>&1 | grep -c "Inode:" || true)


echo "OK: $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
echo "Flash with: SYSTEM_IMG=$OUT_IMG VBMETA_MODE=empty bash scripts/recover_f8_gsi_boot.sh"
