#!/bin/bash
# diagnose_boot_failure.sh — F8 / Treble boot failure analyzer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ROM_DIR="${1:-/home/zero/F8_V2.0_20260313/F8_V2.0_20260313}"
GSI_SYSTEM="${2:-$REPO_ROOT/builder/out/system.img}"
GSI_PHH="${3:-$REPO_ROOT/builder/cache/phh-gsi.img}"
DMESG_FILE="${4:-}"
LOGCAT_FILE="${5:-}"

read_prop_file() {
    local file="$1"
    local key="$2"
    rg -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

read_prop_debugfs() {
    local img="$1"
    local path="$2"
    local key="$3"
    debugfs -R "cat ${path}" "$img" 2>/dev/null | rg -m1 "^${key}=" | cut -d= -f2- || true
}

parse_vbmeta_os() {
    local img="$1"
    python3 - "$img" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read().decode("latin1", "replace")
for m in re.finditer(r"com\.android\.build\.([a-z0-9_.]+)\.os_version", data):
    key = m.group(0)
    tail = data[m.end():m.end() + 32]
    val = tail.split("\x00")[1] if "\x00" in tail else ""
    if val:
        print(f"{key}={val}")
PY
}

BUILD_PROP="$ROM_DIR/build.prop"
if [ ! -f "$BUILD_PROP" ]; then
    BUILD_PROP="$(dirname "$ROM_DIR")/F8_V2.0_20260313/build.prop"
fi

OEM_SDK=""
OEM_RELEASE=""
OEM_DEVICE=""
OEM_TREBLE=""
if [ -f "$BUILD_PROP" ]; then
    OEM_SDK=$(read_prop_file "$BUILD_PROP" "ro.system.build.version.sdk")
    OEM_RELEASE=$(read_prop_file "$BUILD_PROP" "ro.system.build.version.release")
    OEM_DEVICE=$(read_prop_file "$BUILD_PROP" "ro.product.system.device")
    OEM_TREBLE=$(read_prop_file "$BUILD_PROP" "ro.treble.enabled")
fi

BOOT_JSON=""
if [ -f "$(dirname "$ROM_DIR")/unzip_boot/boot.json" ]; then
    BOOT_JSON="$(dirname "$ROM_DIR")/unzip_boot/boot.json"
elif [ -f "/home/zero/github/Android_boot_image_editor/build/unzip_boot/boot.json" ]; then
    BOOT_JSON="/home/zero/github/Android_boot_image_editor/build/unzip_boot/boot.json"
fi

BOOT_HDR=""
RAMDISK_SIZE=""
if [ -n "$BOOT_JSON" ] && [ -f "$BOOT_JSON" ]; then
    BOOT_HDR=$(python3 - "$BOOT_JSON" <<'PY'
import json, sys
j=json.load(open(sys.argv[1]))
print(j["info"].get("headerVersion",""))
print(j["ramdisk"].get("size",0))
PY
)
    BOOT_HDR=$(echo "$BOOT_HDR" | sed -n '1p')
    RAMDISK_SIZE=$(echo "$BOOT_HDR" | sed -n '2p' 2>/dev/null || true)
    if [ -z "$RAMDISK_SIZE" ]; then
        RAMDISK_SIZE=$(python3 - "$BOOT_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["ramdisk"].get("size",0))
PY
)
    fi
fi

VBMETA_CHAIN=""
if [ -f "$ROM_DIR/vbmeta.img" ]; then
    VBMETA_CHAIN=$(parse_vbmeta_os "$ROM_DIR/vbmeta.img" | tr '\n' ';')
fi
VBMETA_SYS=""
if [ -f "$ROM_DIR/vbmeta_system.img" ]; then
    VBMETA_SYS=$(parse_vbmeta_os "$ROM_DIR/vbmeta_system.img" | tr '\n' ';')
fi

PHH_SDK=""
PHH_RELEASE=""
if [ -f "$GSI_PHH" ]; then
    PHH_SDK=$(read_prop_debugfs "$GSI_PHH" "/system/build.prop" "ro.build.version.sdk")
    PHH_RELEASE=$(read_prop_debugfs "$GSI_PHH" "/system/build.prop" "ro.build.version.release")
fi

GSI_SDK=""
GSI_RELEASE=""
GSI_SIZE=""
if [ -f "$GSI_SYSTEM" ]; then
    GSI_SDK=$(read_prop_debugfs "$GSI_SYSTEM" "/build.prop" "ro.build.version.sdk")
    GSI_RELEASE=$(read_prop_debugfs "$GSI_SYSTEM" "/build.prop" "ro.build.version.release")
    [ -z "$GSI_SDK" ] && GSI_SDK=$(read_prop_debugfs "$GSI_SYSTEM" "/system/build.prop" "ro.build.version.sdk")
    [ -z "$GSI_RELEASE" ] && GSI_RELEASE=$(read_prop_debugfs "$GSI_SYSTEM" "/system/build.prop" "ro.build.version.release")
    GSI_SIZE=$(stat -c '%s' "$GSI_SYSTEM")
fi

CONFIG_PHH_VER=""
if [ -f "$REPO_ROOT/config.env" ]; then
    CONFIG_PHH_VER=$(rg -m1 '^PHH_GSI_VERSION=' "$REPO_ROOT/config.env" | cut -d= -f2- || true)
fi

H1_FAIL=false
if [ -n "$OEM_SDK" ] && [ -n "$PHH_SDK" ] && [ "$PHH_SDK" -lt "$OEM_SDK" ]; then
    H1_FAIL=true
fi
if [ -n "$OEM_SDK" ] && [ -n "$GSI_SDK" ] && [ "$GSI_SDK" -lt "$OEM_SDK" ]; then
    H1_FAIL=true
fi

H2_FAIL=false
[ -f "$ROM_DIR/vbmeta_system.img" ] && H2_FAIL=true

echo "=== Treble boot failure diagnosis ==="
echo "OEM Android : ${OEM_RELEASE:-?} (SDK ${OEM_SDK:-?}, device ${OEM_DEVICE:-?}, treble ${OEM_TREBLE:-?})"
echo "PHH base    : ${PHH_RELEASE:-missing} (SDK ${PHH_SDK:-?})"
echo "GSI system  : ${GSI_RELEASE:-missing} (SDK ${GSI_SDK:-?}, size ${GSI_SIZE:-?} bytes)"
echo "PHH config  : ${CONFIG_PHH_VER:-unset}"
echo "Boot chain  : header v${BOOT_HDR:-?}, ramdisk ${RAMDISK_SIZE:-?} bytes"
echo "vbmeta chain: ${VBMETA_CHAIN:-none}"
echo "vbmeta_sys  : ${VBMETA_SYS:-none}"
echo "H1 API mismatch likely : $H1_FAIL"
echo "H2 chained vbmeta_system present: $H2_FAIL"

if [ -n "$DMESG_FILE" ] && [ -f "$DMESG_FILE" ]; then
    DM_VERITY=$(rg -c 'dm-verity|verity.*enforcing|Verified boot failed|avb.*fail' "$DMESG_FILE" 2>/dev/null || echo 0)
    VINTF=$(rg -c 'vintf|hwservicemanager|servicemanager.*fail|Cannot find.*HAL' "$DMESG_FILE" 2>/dev/null || echo 0)
    echo "dmesg hits  : dm-verity/avb=$DM_VERITY, vintf/HAL=$VINTF ($DMESG_FILE)"
fi

if [ -n "$LOGCAT_FILE" ] && [ -f "$LOGCAT_FILE" ]; then
    INIT_FAIL=$(rg -c 'init.*(fatal|FATAL|reboot|panic)|vold.*fail|zygote.*fail|FATAL EXCEPTION' "$LOGCAT_FILE" 2>/dev/null || echo 0)
    echo "logcat hits : init/framework=$INIT_FAIL ($LOGCAT_FILE)"
fi
