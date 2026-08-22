#!/bin/bash
# =============================================================================
# scripts/build_android8_to16_aidl.sh — Android 12-16 AIDL vendor branch matrix
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
ALLOW_SKIP=1
BUILD_TARGET="build-minimal"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --strict) ALLOW_SKIP=0 ;;
        --build) BUILD_TARGET="build" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--dry-run] [--strict] [--build]" >&2
            exit 2
            ;;
    esac
done

VENDOR_VERSIONS=(
    android-12.0
    android-13.0
    android-14.0
    android-15.0
    android-16.0
)

for version in "${VENDOR_VERSIONS[@]}"; do
    env_file="$REPO_ROOT/vendor/${version}.env"
    if [ ! -f "$env_file" ]; then
        if [ "$ALLOW_SKIP" = "1" ]; then
            echo "[AIDL matrix] WARNING: missing $env_file — skipping"
            continue
        fi
        echo "[AIDL matrix] ERROR: missing $env_file" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$env_file"
    cmd="VENDOR_ANDROID_VERSION=$version make $BUILD_TARGET"
    echo "[AIDL matrix] $version -> PHH $PHH_GSI_VERSION / $PHH_GSI_VARIANT -> $cmd"
    if [ "$DRY_RUN" = "0" ]; then
        (cd "$REPO_ROOT" && eval "$cmd")
    fi
done

echo "[AIDL matrix] Done."
