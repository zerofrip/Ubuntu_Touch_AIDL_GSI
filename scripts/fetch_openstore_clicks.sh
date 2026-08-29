#!/bin/bash
# =============================================================================
# scripts/fetch_openstore_clicks.sh — Download Core Apps Click packages
# =============================================================================
# Reads rootfs/clicks.core-apps.list (and optional argv list path).
# Downloads arm64 clicks from OpenStore API v4 into builder/cache/openstore-clicks/.
# Channel preference: focal, then xenial. Missing apps are listed but do not abort.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LIST_FILE="${1:-$REPO_ROOT/rootfs/clicks.core-apps.list}"
OUT_DIR="${GSI_CLICK_CACHE:-$REPO_ROOT/builder/cache/openstore-clicks}"
MISSING_FILE="${GSI_CLICK_MISSING:-$REPO_ROOT/builder/out/core-apps-missing.txt}"
ARCH="${CLICK_ARCH:-arm64}"
CHANNEL_PRIMARY="${CLICK_CHANNEL:-focal}"
CHANNEL_FALLBACK="${CLICK_CHANNEL_FALLBACK:-xenial}"
API_BASE="${OPENSTORE_API:-https://open-store.io/api/v4/apps}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[$(date -Iseconds)]${NC} ${BOLD}[OpenStore]${NC} $1"; }
success() { echo -e "${GREEN}[$(date -Iseconds)]${NC} ${BOLD}[OpenStore]${NC} $1"; }
warn()    { echo -e "${RED}[$(date -Iseconds)]${NC} ${BOLD}[OpenStore]${NC} $1"; }

if [ ! -f "$LIST_FILE" ]; then
    warn "FATAL: click list not found: $LIST_FILE"
    exit 1
fi

mkdir -p "$OUT_DIR" "$(dirname "$MISSING_FILE")"
: > "$MISSING_FILE"

mapfile -t APPS < <(grep -vE '^\s*(#|$)' "$LIST_FILE" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)

if [ "${#APPS[@]}" -eq 0 ]; then
    warn "No click IDs in $LIST_FILE"
    exit 0
fi

info "Fetching ${#APPS[@]} apps → $OUT_DIR (arch=$ARCH, channel=$CHANNEL_PRIMARY|$CHANNEL_FALLBACK)"

pick_download() {
    python3 - "$1" "$ARCH" "$CHANNEL_PRIMARY" "$CHANNEL_FALLBACK" <<'PY'
import json, sys
path, arch, ch_pri, ch_fb = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    payload = json.load(f)
data = payload.get("data", payload)
downloads = data.get("downloads") or []

def match(channel):
    for d in downloads:
        if d.get("architecture") == arch and d.get("channel") == channel:
            url = d.get("download_url") or d.get("downloadUrl")
            ver = d.get("version") or "unknown"
            if url:
                return url, ver, channel
    return None

for ch in (ch_pri, ch_fb):
    hit = match(ch)
    if hit:
        print(f"{hit[0]}\t{hit[1]}\t{hit[2]}")
        sys.exit(0)
# any channel for arch
for d in downloads:
    if d.get("architecture") == arch:
        url = d.get("download_url") or d.get("downloadUrl")
        ver = d.get("version") or "unknown"
        ch = d.get("channel") or "unknown"
        if url:
            print(f"{url}\t{ver}\t{ch}")
            sys.exit(0)
sys.exit(2)
PY
}

ok=0
fail=0
for app in "${APPS[@]}"; do
    meta="$OUT_DIR/${app}.json"
    dest="$OUT_DIR/${app}_${ARCH}.click"
    info "Resolving $app"
    if ! curl -fsSL --retry 3 --retry-delay 1 "${API_BASE}/${app}" -o "$meta"; then
        warn "API miss: $app"
        echo "click:$app  reason=api_fetch_failed" >> "$MISSING_FILE"
        fail=$((fail + 1))
        continue
    fi
    if ! sel=$(pick_download "$meta"); then
        warn "No $ARCH download for $app"
        echo "click:$app  reason=no_${ARCH}_download" >> "$MISSING_FILE"
        fail=$((fail + 1))
        continue
    fi
    url=$(printf '%s' "$sel" | cut -f1)
    ver=$(printf '%s' "$sel" | cut -f2)
    ch=$(printf '%s' "$sel" | cut -f3)
    info "Downloading $app ($ch/$ver) → $(basename "$dest")"
    if curl -fsSL --retry 3 --retry-delay 1 -L "$url" -o "$dest.tmp"; then
        # basic sanity: click/ar archive or zip-like
        if [ ! -s "$dest.tmp" ]; then
            warn "Empty download: $app"
            rm -f "$dest.tmp"
            echo "click:$app  reason=empty_download" >> "$MISSING_FILE"
            fail=$((fail + 1))
            continue
        fi
        mv -f "$dest.tmp" "$dest"
        ok=$((ok + 1))
        success "OK $app → $dest"
    else
        warn "Download failed: $app"
        rm -f "$dest.tmp"
        echo "click:$app  reason=download_failed url=$url" >> "$MISSING_FILE"
        fail=$((fail + 1))
    fi
done

info "Done: $ok fetched, $fail missing (see $MISSING_FILE)"
if [ "$fail" -gt 0 ]; then
    warn "Missing entries:"
    cat "$MISSING_FILE" || true
fi
exit 0
