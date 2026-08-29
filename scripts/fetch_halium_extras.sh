#!/bin/bash
# =============================================================================
# scripts/fetch_halium_extras.sh — Obtain halium-extras debs for rootfs build
# =============================================================================
# libsync / libgralloc1 / libhwc2 are not separate apt packages on focal.
# UBports ships them inside libhybris; this script repackages them for Phase 3.5.
#
# Usage:
#   bash scripts/fetch_halium_extras.sh           # fetch + repackage
#   bash scripts/fetch_halium_extras.sh --verify  # only verify cache
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/builder/cache/halium-debs"
SRC_DIR="$REPO_ROOT/builder/cache/halium-extras-deb"
GIT_URL="${HALIUM_EXTRAS_GIT:-https://gitlab.com/ubports/development/core/halium-extras-deb}"
ARCH="${ARCH:-arm64}"
UBPORTS_MIRROR="${UBPORTS_MIRROR:-http://repo.ubports.com}"
LIBHYBRIS_DEB="${LIBHYBRIS_DEB:-pool/main/libh/libhybris/libhybris_0.1.0+git20240229+9dea23c-0ubports1+0~20240912111840.3+ubports20.04~1.gbp1dda99_arm64.deb}"

info()  { echo "[fetch_halium_extras] $*"; }
fail()  { echo "[fetch_halium_extras] ERROR: $*" >&2; exit 1; }

verify_debs() {
    local ok=0
    shopt -s nullglob
    local debs=("$CACHE_DIR"/*.deb)
    shopt -u nullglob
    [ ${#debs[@]} -gt 0 ] || return 1
    for deb in "${debs[@]}"; do
        info "cached: $(basename "$deb")"
    done
    for hint in libsync libgralloc libhwc halium-extras; do
        if ls "$CACHE_DIR"/*"${hint}"*.deb >/dev/null 2>&1; then
            ok=1
        fi
    done
    [ "$ok" -eq 1 ]
}

build_from_git() {
    [ -d "$SRC_DIR/.git" ] || git clone --depth 1 "$GIT_URL" "$SRC_DIR"
    git -C "$SRC_DIR" pull --ff-only 2>/dev/null || true
    cd "$SRC_DIR"
    if [ -x ./build.sh ]; then
        ./build.sh --arch "$ARCH" --android "${HALIUM_EXTRAS_ANDROID:-15}"
    elif [ -f Makefile ]; then
        make ARCH="$ARCH" ANDROID="${HALIUM_EXTRAS_ANDROID:-15}" || make
    else
        return 1
    fi
    shopt -s nullglob
    for dir in "$SRC_DIR/out" "$SRC_DIR" "$SRC_DIR/debs" "$SRC_DIR/build"; do
        [ -d "$dir" ] || continue
        cp -f "$dir"/*.deb "$CACHE_DIR/" 2>/dev/null || true
    done
    shopt -u nullglob
}

repackage_from_libhybris() {
    local tmp="$REPO_ROOT/builder/cache/.halium-extras-staging"
    local extract="$tmp/extract"
    local pkgroot="$tmp/pkg"
    local deb_url="$UBPORTS_MIRROR/$LIBHYBRIS_DEB"

    rm -rf "$tmp"
    mkdir -p "$CACHE_DIR" "$extract"

    info "Downloading libhybris glue libs from $deb_url"
    curl -fsSL "$deb_url" -o "$tmp/libhybris.deb"
    dpkg-deb -x "$tmp/libhybris.deb" "$extract"

    local libdir="$extract/usr/lib/aarch64-linux-gnu"
    for lib in libsync.so.2 libgralloc.so.1 libhwc2.so.1; do
        [ -e "$libdir/$lib" ] || [ -L "$libdir/$lib" ] || fail "missing $lib in libhybris deb"
    done

    local ver="0.1.0+ubports-glue1"
    rm -rf "$pkgroot"
    mkdir -p "$pkgroot/DEBIAN" "$pkgroot/usr/lib/aarch64-linux-gnu"
    cat > "$pkgroot/DEBIAN/control" <<EOF
Package: halium-extras-glue
Version: $ver
Architecture: arm64
Maintainer: Ubuntu GSI <ubuntu-gsi@local>
Section: libs
Priority: optional
Description: libsync/libgralloc/libhwc2 from UBports libhybris (Halium GPU glue)
 Provides Android HAL glue libraries required by mir-platform-graphics-android*.
EOF

    for base in libsync libgralloc libhwc2; do
        cp -a "$libdir/${base}.so."* "$pkgroot/usr/lib/aarch64-linux-gnu/" 2>/dev/null || true
        [ -L "$libdir/${base}.so.1" ] && cp -a "$libdir/${base}.so.1" "$pkgroot/usr/lib/aarch64-linux-gnu/" || true
        [ -L "$libdir/${base}.so.2" ] && cp -a "$libdir/${base}.so.2" "$pkgroot/usr/lib/aarch64-linux-gnu/" || true
    done

    dpkg-deb --build "$pkgroot" "$CACHE_DIR/halium-extras-glue_${ver}_arm64.deb"
    rm -rf "$tmp"
    info "Built $(basename "$CACHE_DIR/halium-extras-glue_${ver}_arm64.deb")"
}

mkdir -p "$CACHE_DIR"

if [ "${1:-}" = "--verify" ]; then
    verify_debs && { info "halium-debs cache OK"; exit 0; }
    fail "No usable debs in $CACHE_DIR — run without --verify"
fi

if verify_debs 2>/dev/null; then
    info "Using existing debs in $CACHE_DIR"
    exit 0
fi

if build_from_git 2>/dev/null && verify_debs 2>/dev/null; then
    info "Built halium-extras from git"
    exit 0
fi

info "Git build unavailable — repackaging glue libs from UBports libhybris"
repackage_from_libhybris
verify_debs || fail "Repackage failed"
info "Done — debs ready in $CACHE_DIR"
