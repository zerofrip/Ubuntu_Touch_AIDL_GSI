#!/bin/bash
# =============================================================================
# scripts/load_vendor_config.sh — Load vendor-version-specific build settings
# =============================================================================
# Resolves VENDOR_ANDROID_VERSION from env or git branch (android-XX.Y),
# then sources vendor/${VENDOR_ANDROID_VERSION}.env
# =============================================================================

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

_load_vendor_config() {
    local version="${VENDOR_ANDROID_VERSION:-}"
    local branch=""
    local env_file=""

    if [ -z "$version" ]; then
        if git -C "$_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            branch="$(git -C "$_REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            case "$branch" in
                android-[0-9]*.[0-9]*)
                    version="$branch"
                    ;;
            esac
        fi
    fi

    if [ -z "$version" ]; then
        echo "[vendor-config] ERROR: VENDOR_ANDROID_VERSION is not set." >&2
        echo "[vendor-config] Checkout an android-* branch (e.g. android-16.0) or export VENDOR_ANDROID_VERSION." >&2
        echo "[vendor-config] The main branch is documentation-only and cannot build release images." >&2
        return 1
    fi

    env_file="$_REPO_ROOT/vendor/${version}.env"
    if [ ! -f "$env_file" ]; then
        echo "[vendor-config] ERROR: Missing vendor config: $env_file" >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "$env_file"

    export VENDOR_ANDROID_VERSION
    export RELEASE_SYSTEM_IMG="${RELEASE_SYSTEM_IMG:-${VENDOR_ANDROID_VERSION}_system.img}"
    export PHH_GSI_URL="${PHH_GSI_URL:-https://github.com/${PHH_GSI_REPO}/releases/download/${PHH_GSI_VERSION}/system-${PHH_GSI_VARIANT}.img.xz}"

    echo "[vendor-config] Loaded $version (PHH ${PHH_GSI_VERSION} / ${PHH_GSI_VARIANT})"
}

_load_vendor_config
