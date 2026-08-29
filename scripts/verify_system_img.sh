#!/bin/bash
# =============================================================================
# scripts/verify_system_img.sh — Validate system.img before flash
# =============================================================================
# ext4 superblock lives at byte offset 0x400; the first 1KB is normally zero.
# Do NOT use `xxd | head -1` alone — that always looks "empty" for valid ext4.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="${RUN_ID:-verify}"

CONFIG_FILE="$REPO_ROOT/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi
DEFAULT_IMG="$REPO_ROOT/builder/out/${RELEASE_SYSTEM_IMG:-system.img}"
IMG="${1:-$DEFAULT_IMG}"
MIN_BYTES="${MIN_SYSTEM_BYTES:-536870912}"  # 512 MiB


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

fail() { echo -e "${RED}[verify]${NC} FAIL: $1"; exit 1; }
pass() { echo -e "${GREEN}[verify]${NC} OK: $1"; }
warn() { echo -e "${YELLOW}[verify]${NC} WARN: $1"; }
info() { echo -e "${CYAN}[verify]${NC} $1"; }

if [ ! -f "$IMG" ]; then
    fail "Image not found: $IMG"
fi

read_json=$(python3 - "$IMG" "$MIN_BYTES" <<'PY'
import json, os, struct, sys
path, min_bytes = sys.argv[1], int(sys.argv[2])
size = os.path.getsize(path)
with open(path, "rb") as f:
    f.seek(0x400)
    sb = f.read(64)
ext4_magic = len(sb) >= 0x3A and sb[0x38:0x3A] == b"\x53\xef"
head16 = open(path, "rb").read(16).hex()
sdk = release = launcher = rc = None
if ext4_magic and size >= min_bytes:
    import subprocess
    for prop_cmd in (
        ["debugfs", "-R", "cat /build.prop", path],
        ["debugfs", "-R", "cat /system/build.prop", path],
    ):
        try:
            out = subprocess.check_output(prop_cmd, stderr=subprocess.DEVNULL, text=True)
        except subprocess.CalledProcessError:
            continue
        for line in out.splitlines():
            if line.startswith("ro.build.version.sdk=") and sdk is None:
                sdk = line.split("=", 1)[1]
            if line.startswith("ro.build.version.release=") and release is None:
                release = line.split("=", 1)[1]
        if sdk:
            break
    for target in ("/bin/ubuntu-gsi-launcher", "/system/bin/ubuntu-gsi-launcher"):
        try:
            subprocess.check_output(["debugfs", "-R", f"ls -l {target}", path], stderr=subprocess.DEVNULL, text=True)
            launcher = target
            break
        except subprocess.CalledProcessError:
            pass
    for target in ("/etc/init/ubuntu-gsi.rc", "/system/etc/init/ubuntu-gsi.rc"):
        try:
            subprocess.check_output(["debugfs", "-R", f"ls -l {target}", path], stderr=subprocess.DEVNULL, text=True)
            rc = target
            break
        except subprocess.CalledProcessError:
            pass

valid = ext4_magic and size >= min_bytes and sdk is not None
print(json.dumps({
    "path": path,
    "sizeBytes": size,
    "ext4MagicAt0x438": ext4_magic,
    "head16Hex": head16,
    "sdk": sdk,
    "release": release,
    "launcher": launcher,
    "initRc": rc,
    "valid": valid,
    "note": "ext4 superblock is at 0x400; head16Hex all-zero is normal",
}))
PY
)


valid=$(python3 -c "import json,sys; print(json.load(sys.stdin)['valid'])" <<<"$read_json")
size_bytes=$(python3 -c "import json,sys; print(json.load(sys.stdin)['sizeBytes'])" <<<"$read_json")
sdk=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('sdk'))" <<<"$read_json")
release=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('release'))" <<<"$read_json")
ext4=$(python3 -c "import json,sys; print(json.load(sys.stdin)['ext4MagicAt0x438'])" <<<"$read_json")

info "Image: $IMG"
info "Size : $(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes} bytes")"
info "ext4 magic @0x438: $ext4"
info "Android SDK/Release: ${sdk:-?} / ${release:-?}"
warn "First 16 bytes are often 0000.. on valid ext4; check offset 0x438 instead."

if [ "$valid" != "True" ]; then
    if [ "$ext4" != "True" ]; then
        fail "No ext4 superblock at 0x438 — image is corrupt or truncated (old 10MB zero stub?)"
    fi
    if [ "$size_bytes" -lt "$MIN_BYTES" ]; then
        fail "Image too small (${size_bytes} bytes). Expected >= ${MIN_BYTES}."
    fi
    fail "build.prop unreadable — PHH base likely missing from image"
fi

pass "system image looks flashable"
echo ""
echo -e "${BOLD}Correct quick check:${NC}"
echo "  xxd -s 0x438 -l 2 $IMG    # should show: 53ef"
echo "  file $IMG                 # should show: ext4 filesystem data"
