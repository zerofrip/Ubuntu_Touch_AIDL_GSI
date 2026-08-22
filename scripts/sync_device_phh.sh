#!/bin/bash
# =============================================================================
# scripts/sync_device_phh.sh — Sync TrebleDroid/device_phh_treble for vendor branch
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

DEVICE_PHH_REPO="${DEVICE_PHH_REPO:-https://github.com/TrebleDroid/device_phh_treble.git}"
DEVICE_PHH_DIR="${DEVICE_PHH_DIR:-$REPO_ROOT/builder/cache/device_phh_treble}"
DEVICE_PHH_BRANCH="${DEVICE_PHH_BRANCH:-${VENDOR_ANDROID_VERSION:-}}"

if [ -z "$DEVICE_PHH_BRANCH" ]; then
    echo "[device_phh] WARNING: DEVICE_PHH_BRANCH not set — skipping sync"
    exit 0
fi

branch_ref="refs/remotes/origin/${DEVICE_PHH_BRANCH}"

if [ ! -d "$DEVICE_PHH_DIR/.git" ]; then
    echo "[device_phh] Cloning into $DEVICE_PHH_DIR"
    git clone "$DEVICE_PHH_REPO" "$DEVICE_PHH_DIR"
fi

echo "[device_phh] Syncing branch: $DEVICE_PHH_BRANCH"
(
    cd "$DEVICE_PHH_DIR"
    git fetch origin --prune
    if git show-ref --quiet "$branch_ref"; then
        git checkout -B "$DEVICE_PHH_BRANCH" "origin/$DEVICE_PHH_BRANCH"
    else
        echo "[device_phh] WARNING: missing origin/$DEVICE_PHH_BRANCH — keeping current checkout"
    fi
)
