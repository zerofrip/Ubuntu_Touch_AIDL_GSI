#!/bin/bash
# =============================================================================
# scripts/provision_userdata_packages.sh — Push user packages to device
# =============================================================================
# Interprets rootfs/packages.userdata.list, fetches missing clicks/debs on host,
# adb-pushes to /data/ubuntu-gsi/user-packages/, then installs clicks on device.
# Does NOT wipe userdata. Compatible with flash.sh --system-only.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LIST_FILE="${1:-$REPO_ROOT/rootfs/packages.userdata.list}"
CLICK_CACHE="${GSI_CLICK_CACHE:-$REPO_ROOT/builder/cache/openstore-clicks}"
STAGE_DIR="$REPO_ROOT/builder/out/user-packages-stage"
DEVICE_ROOT="/data/ubuntu-gsi/user-packages"
ADB="${ADB:-adb}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[Provision]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[Provision]${NC} $1"; }
error()   { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[Provision]${NC} $1"; }

if [ ! -f "$LIST_FILE" ]; then
    error "FATAL: $LIST_FILE not found"
    exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/clicks" "$STAGE_DIR/debs"
cp "$LIST_FILE" "$STAGE_DIR/packages.userdata.list"
cat > "$STAGE_DIR/README" <<'EOF'
User-added packages for Ubuntu Touch GSI.
  clicks/*.click — installed by provision / firstboot
  debs/*.deb     — staged only; install with dpkg if needed
EOF

click_ids=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in
        click:*)
            id="${line#click:}"
            click_ids+=("$id")
            ;;
        deb:*)
            pkg="${line#deb:}"
            info "Staging deb:$pkg (apt-get download on host if available)"
            (
                cd "$STAGE_DIR/debs"
                apt-get download "$pkg" 2>/dev/null || true
            ) || true
            ;;
        *)
            info "Skip unknown entry: $line"
            ;;
    esac
done < "$LIST_FILE"

if [ "${#click_ids[@]}" -gt 0 ]; then
    tmp_list="$STAGE_DIR/clicks.fetch.list"
    printf '%s\n' "${click_ids[@]}" > "$tmp_list"
    GSI_CLICK_CACHE="$CLICK_CACHE" \
        bash "$SCRIPT_DIR/fetch_openstore_clicks.sh" "$tmp_list" || true
    for id in "${click_ids[@]}"; do
        src="$CLICK_CACHE/${id}_arm64.click"
        if [ -f "$src" ]; then
            cp -a "$src" "$STAGE_DIR/clicks/"
        else
            error "Missing click for $id (not in cache)"
        fi
    done
fi

n_clicks=$(find "$STAGE_DIR/clicks" -name '*.click' 2>/dev/null | wc -l)
n_debs=$(find "$STAGE_DIR/debs" -name '*.deb' 2>/dev/null | wc -l)
info "Staged: $n_clicks click(s), $n_debs deb(s)"

if ! "$ADB" get-state 2>/dev/null | grep -q device; then
    error "No adb device — staged at $STAGE_DIR (push manually later)"
    exit 1
fi

info "Pushing to device $DEVICE_ROOT"
"$ADB" shell "mkdir -p $DEVICE_ROOT/clicks $DEVICE_ROOT/debs"
"$ADB" push "$STAGE_DIR/README" "$DEVICE_ROOT/README" >/dev/null
"$ADB" push "$STAGE_DIR/packages.userdata.list" "$DEVICE_ROOT/packages.userdata.list" >/dev/null
if [ "$n_clicks" -gt 0 ]; then
    "$ADB" push "$STAGE_DIR/clicks/." "$DEVICE_ROOT/clicks/" >/dev/null
fi
if [ "$n_debs" -gt 0 ]; then
    "$ADB" push "$STAGE_DIR/debs/." "$DEVICE_ROOT/debs/" >/dev/null
fi

info "Installing clicks on device (pkcon / click)"
"$ADB" shell "sh -s" <<'REMOTE'
set -e
MARKER=/data/uhl_overlay/.user_clicks_provisioned
mkdir -p /data/uhl_overlay
CLICK_DIR=/data/ubuntu-gsi/user-packages/clicks
[ -d "$CLICK_DIR" ] || exit 0
for c in "$CLICK_DIR"/*.click; do
    [ -f "$c" ] || continue
    echo "Installing $c"
    if command -v pkcon >/dev/null 2>&1; then
        pkcon install-local --allow-untrusted "$c" || true
    elif command -v click >/dev/null 2>&1; then
        click install --allow-unauthenticated "$c" || \
            su - ubuntu -c "click install --allow-unauthenticated '$c'" || true
    else
        echo "WARN: neither pkcon nor click found"
    fi
done
date -Iseconds > "$MARKER"
REMOTE

success "Provision complete"
