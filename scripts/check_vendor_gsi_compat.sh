#!/bin/bash
# scripts/check_vendor_gsi_compat.sh — Compare OEM vendor vs GSI SDK/Treble
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Prefer AIDL repo log; also mirror to HIDL workspace debug path if present
RUN_ID="${RUN_ID:-vendor-compat}"

ROM_DIR="${1:-/home/zero/F8_V2.0_20260313/F8_V2.0_20260313}"
CONFIG_FILE="$REPO_ROOT/config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

GSI_IMG="${2:-$REPO_ROOT/builder/out/${RELEASE_SYSTEM_IMG:-system.img}}"
PHH_IMG="${3:-$REPO_ROOT/builder/cache/phh-gsi.img}"


prop_file() { rg -m1 "^${2}=" "$1" 2>/dev/null | cut -d= -f2- || true; }
prop_img() {
    local img="$1" path="$2" key="$3" v=""
    v=$(debugfs -R "cat ${path}" "$img" 2>/dev/null | rg -m1 "^${key}=" | cut -d= -f2- || true)
    echo "$v"
}

OEM_SDK=$(prop_file "$ROM_DIR/build.prop" ro.system.build.version.sdk)
OEM_REL=$(prop_file "$ROM_DIR/build.prop" ro.system.build.version.release)
OEM_TREBLE=$(prop_file "$ROM_DIR/build.prop" ro.treble.enabled)

VBMETA_VENDOR_OS=$(python3 - "$ROM_DIR/vbmeta_vendor.img" <<'PY' 2>/dev/null || true
import re,sys
d=open(sys.argv[1],"rb").read().decode("latin1","replace")
m=re.search(r"com\.android\.build\.vendor\.os_version\x00([^\x00]+)", d)
print(m.group(1) if m else "")
PY
)
VBMETA_SYS_OS=$(python3 - "$ROM_DIR/vbmeta_system.img" <<'PY' 2>/dev/null || true
import re,sys
d=open(sys.argv[1],"rb").read().decode("latin1","replace")
m=re.search(r"com\.android\.build\.system\.os_version\x00([^\x00]+)", d)
print(m.group(1) if m else "")
PY
)
VBMETA_PRODUCT_OS=$(python3 - "$ROM_DIR/vbmeta.img" <<'PY' 2>/dev/null || true
import re,sys
d=open(sys.argv[1],"rb").read().decode("latin1","replace")
m=re.search(r"com\.android\.build\.product\.os_version\x00([^\x00]+)", d)
print(m.group(1) if m else "")
PY
)

GSI_SDK=$(prop_img "$GSI_IMG" /build.prop ro.build.version.sdk)
[ -z "$GSI_SDK" ] && GSI_SDK=$(prop_img "$GSI_IMG" /build.prop ro.system.build.version.sdk)
GSI_REL=$(prop_img "$GSI_IMG" /build.prop ro.build.version.release)
[ -z "$GSI_REL" ] && GSI_REL=$(prop_img "$GSI_IMG" /build.prop ro.system.build.version.release)
GSI_FLAVOR=$(prop_img "$GSI_IMG" /build.prop ro.build.flavor)

PHH_SDK=$(prop_img "$PHH_IMG" /system/build.prop ro.build.version.sdk)
[ -z "$PHH_SDK" ] && PHH_SDK=$(prop_img "$PHH_IMG" /build.prop ro.build.version.sdk)
PHH_REL=$(prop_img "$PHH_IMG" /system/build.prop ro.build.version.release)

FB_SLOT=$(fastboot getvar current-slot 2>&1 | awk -F': ' '/current-slot/{print $2; exit}' || true)
FB_USERSPACE=$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/is-userspace/{print $2; exit}' || true)
FB_PRODUCT=$(fastboot getvar product 2>&1 | awk -F': ' '/^product:/{print $2; exit}' || true)

# Treble rule of thumb: GSI system should be >= vendor interface; product/system_ext often match OEM system
MISMATCH_OLDER_THAN_OEM=false
MISMATCH_OLDER_THAN_PRODUCT=false
if [ -n "$OEM_SDK" ] && [ -n "$GSI_SDK" ] && [ "$GSI_SDK" -lt "$OEM_SDK" ]; then
    MISMATCH_OLDER_THAN_OEM=true
fi
if [ -n "$VBMETA_PRODUCT_OS" ] && [ -n "$GSI_REL" ] && [ "$GSI_REL" -lt "$VBMETA_PRODUCT_OS" ] 2>/dev/null; then
    MISMATCH_OLDER_THAN_PRODUCT=true
fi


echo "=== Vendor / GSI compatibility ==="
echo "Device (fastboot): product=$FB_PRODUCT slot=$FB_SLOT userspace=$FB_USERSPACE"
echo "OEM system      : Android ${OEM_REL:-?} (SDK ${OEM_SDK:-?}) treble=${OEM_TREBLE:-?}"
echo "vbmeta vendor   : os_version=${VBMETA_VENDOR_OS:-?}"
echo "vbmeta system   : os_version=${VBMETA_SYS_OS:-?}"
echo "vbmeta product  : os_version=${VBMETA_PRODUCT_OS:-?}"
echo "PHH base        : Android ${PHH_REL:-?} (SDK ${PHH_SDK:-?}) ${PHH_GSI_VERSION:-}"
echo "Built GSI       : Android ${GSI_REL:-?} (SDK ${GSI_SDK:-?}) flavor=${GSI_FLAVOR:-?} ($GSI_IMG)"
echo ""
echo "GSI older than OEM system SDK? $MISMATCH_OLDER_THAN_OEM"
echo "GSI older than product os?     $MISMATCH_OLDER_THAN_PRODUCT"
if [ "$MISMATCH_OLDER_THAN_OEM" = true ]; then
    echo ""
    echo "VERDICT: Android 15 GSI (SDK 35) on Android 16 OEM (SDK 36) is a DOWNGRADE."
    echo "Treble/GSI expects system >= device generation for product/system_ext coexistence."
    echo "Switch back to android-16.0 branch / PHH ci-20250617."
fi
echo "Log: $LOG_PATH"
