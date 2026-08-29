#!/usr/bin/env bash
# =============================================================================
# diag_vendor_hal_inventory.sh — Enumerate Android vendor/kernel HALs vs Lomiri
# =============================================================================
# Host-side (adb). Read-only on device except writing report under /data/local/tmp.
#
# Usage:
#   bash scripts/diag_vendor_hal_inventory.sh
#   OUT_DIR=/tmp/hal-inv bash scripts/diag_vendor_hal_inventory.sh
#
# Outputs under builder/out/hal-inventory/:
#   inventory_<stamp>.json
#   inventory_<stamp>.md
#   inventory_latest.{json,md}  (symlinks / copies)
#
# On-device companion (same intent, boot-time):
#   /usr/lib/ubuntu-gsi/hal-enumerate.sh
#   → /run/ubuntu-gsi/hal-inventory.{json,env}
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROOT="${CHROOT:-/mnt/halium/merged}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/builder/out/hal-inventory}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEVICE_TMP="/data/local/tmp/hal_inventory_${STAMP}.sh"

mkdir -p "$OUT_DIR"

su0() { adb shell "su 0 $*" 2>/dev/null | tr -d '\r'; }

# Device-side collector (Android toybox/busybox sh)
cat > /tmp/hal_inventory_device.sh << 'DEOF'
#!/system/bin/sh
# Runs as root on device; prints KEY=value lines + sections for host parser.
CHROOT="${CHROOT:-/mnt/halium/merged}"

echo "===META==="
echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
echo "ro.hardware=$(getprop ro.hardware)"
echo "ro.board.platform=$(getprop ro.board.platform)"
echo "ro.build.version.release=$(getprop ro.build.version.release)"
echo "ro.vndk.version=$(getprop ro.vndk.version)"
echo "ro.treble.enabled=$(getprop ro.treble.enabled)"
echo "sys.boot_completed=$(getprop sys.boot_completed)"
echo "persist.ubuntu_gsi.enable=$(getprop persist.ubuntu_gsi.enable)"

echo "===VENDOR_HW==="
ls /vendor/lib64/hw 2>/dev/null | sort || true

echo "===VENDOR_EGL==="
ls /vendor/lib64/egl 2>/dev/null | sort || true

echo "===VENDOR_VULKAN==="
ls /vendor/lib64/hw/vulkan.*.so 2>/dev/null || true
ls /vendor/lib64/vulkan.*.so 2>/dev/null || true

echo "===VINTF==="
ls /vendor/etc/vintf 2>/dev/null || true
ls /vendor/etc/vintf/manifest 2>/dev/null | head -40 || true
# Keep XML scrape cheap — only top-level manifests, first matches.
for f in /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/compatibility_matrix.xml; do
  [ -f "$f" ] || continue
  echo "FILE:$f"
  grep -oE 'android\.hardware\.[a-zA-Z0-9_.]+' "$f" 2>/dev/null | sort -u | head -60
done

echo "===SERVICE_LIST==="
# service list can block on some OEM builds; hard-cap runtime.
timeout 8 service list 2>/dev/null | head -200 || echo "service_list_timeout=1"

echo "===DEV_INPUT==="
ls -la /dev/input 2>/dev/null || true

echo "===DEV_DRI==="
ls -la /dev/dri 2>/dev/null || true

echo "===DEV_SOUND==="
ls -la /dev/snd 2>/dev/null || true
ls /proc/asound/cards 2>/dev/null || true

echo "===DEV_VIDEO==="
ls -la /dev/video* /dev/media* 2>/dev/null || true

echo "===DEV_IIO==="
ls -la /dev/iio:device* 2>/dev/null || true
ls /sys/bus/iio/devices 2>/dev/null || true

echo "===DEV_BACKLIGHT==="
ls /sys/class/backlight 2>/dev/null || true
for b in /sys/class/backlight/*; do
  [ -d "$b" ] || continue
  echo "$(basename "$b") max=$(cat "$b/max_brightness" 2>/dev/null) cur=$(cat "$b/brightness" 2>/dev/null)"
done

echo "===DEV_POWER==="
ls /sys/class/power_supply 2>/dev/null || true

echo "===DEV_WIFI==="
ls -la /dev/wmtWifi /dev/wmtWifi* 2>/dev/null || true
ls /sys/class/net 2>/dev/null || true
ls /sys/class/rfkill 2>/dev/null || true

echo "===DEV_BT==="
ls -la /dev/ttyBT* /dev/stpbt* /dev/bt* 2>/dev/null || true
ls /sys/class/bluetooth 2>/dev/null || true

echo "===DEV_MODEM==="
ls -la /dev/ccci* /dev/ttyC* /dev/gsm* /dev/md* 2>/dev/null | head -40 || true

echo "===DEV_GNSS==="
ls -la /dev/gps* /dev/gnss* /dev/stpgps* 2>/dev/null || true

echo "===DEV_FP==="
ls -la /dev/goodix* /dev/fingerprint* /dev/fpsensor* 2>/dev/null || true

echo "===CHROOT_PKGS==="
if [ -d "$CHROOT/usr/bin" ]; then
  for c in lomiri pulseaudio ofonod bluetoothctl iio-sensor-proxy cam nmcli \
           lomiri-indicator-network ayatana-indicator-common upower; do
    found=no
    for p in "$CHROOT/usr/bin/$c" "$CHROOT/usr/sbin/$c" "$CHROOT/usr/libexec/$c"; do
      [ -e "$p" ] && found=yes && break
    done
    echo "pkg_$c=$found"
  done
  ls "$CHROOT/usr/share/unity/indicators" 2>/dev/null | head -20 || true
  ls "$CHROOT/usr/lib/systemd/user/" 2>/dev/null | grep indicator | head -30 || true
  echo "chroot_mounted=yes"
else
  echo "chroot_mounted=no"
fi

echo "===END==="
DEOF

adb push /tmp/hal_inventory_device.sh "$DEVICE_TMP" >/dev/null
adb shell "su 0 chmod 755 $DEVICE_TMP" >/dev/null
RAW="$OUT_DIR/inventory_${STAMP}.raw.txt"
# `su 0 VAR=val cmd` treats VAR=val as the binary — use env.
adb shell "su 0 env CHROOT=$CHROOT sh $DEVICE_TMP" >"$RAW" 2>&1 || true

JSON="$OUT_DIR/inventory_${STAMP}.json"
MD="$OUT_DIR/inventory_${STAMP}.md"

python3 - "$RAW" "$JSON" "$MD" "$STAMP" <<'PY'
import json, re, sys
from pathlib import Path
from datetime import datetime, timezone

raw = Path(sys.argv[1]).read_text(errors="replace")
json_path, md_path, stamp = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]

sections = {}
cur = None
buf = []
for line in raw.splitlines():
    if line.startswith("===") and line.endswith("==="):
        if cur is not None:
            sections[cur] = buf
        cur = line.strip("=")
        buf = []
    else:
        if cur is not None:
            buf.append(line)
if cur is not None:
    sections[cur] = buf

def sect(name):
    return sections.get(name, [])

meta = {}
for line in sect("META"):
    if "=" in line:
        k, _, v = line.partition("=")
        meta[k.strip()] = v.strip()

hw = [l.strip() for l in sect("VENDOR_HW") if l.strip()]
egl = [l.strip() for l in sect("VENDOR_EGL") if l.strip()]
vulkan = [l.strip() for l in sect("VENDOR_VULKAN") if l.strip()]
services = [l.strip() for l in sect("SERVICE_LIST") if l.strip()]
svc_names = []
for l in services:
    # "42	android.hardware.foo.IBar/default: [...]"
    m = re.match(r"\d+\s+(\S+):", l)
    if m:
        svc_names.append(m.group(1))

def has_hw(patterns):
    return [h for h in hw if any(p in h.lower() for p in patterns)]

def has_svc(patterns):
    return [s for s in svc_names if any(p in s.lower() for p in patterns)]

def chroot_pkg(name):
    for l in sect("CHROOT_PKGS"):
        if l.startswith(f"pkg_{name}="):
            return l.split("=", 1)[1].strip() == "yes"
    return False

def nonempty_sect(name):
    lines = [l for l in sect(name) if l.strip() and "No such" not in l and "can't open" not in l]
    return len(lines) > 0, lines[:20]

def status(android_ok, linux_dev, pkg, bridged_hint):
    if bridged_hint:
        return "bridged"
    if android_ok and linux_dev and pkg:
        return "kernel_only"
    if pkg and not linux_dev and not android_ok:
        return "pkg_only"
    if android_ok and not pkg:
        return "missing_linux"
    if linux_dev and not pkg:
        return "kernel_only"
    if not android_ok and not linux_dev:
        return "missing"
    return "pkg_only"

subsystems = []

# display / gpu
gpu_hw = has_hw(["hwcomposer", "gralloc", "allocator", "composer"])
gpu_svc = has_svc(["composer", "graphics.allocator", "hwcomposer"])
dri_ok, dri_lines = nonempty_sect("DEV_DRI")
subsystems.append({
    "id": "display_gpu",
    "android": {"hw": gpu_hw[:15], "services": gpu_svc[:10], "egl": egl[:10], "vulkan": vulkan[:5]},
    "linux": {"dri": dri_lines, "chroot_lomiri": chroot_pkg("lomiri")},
    "status": status(bool(gpu_hw or gpu_svc), dri_ok, chroot_pkg("lomiri"), True),
    "notes": "Mir android2 + libhybris HWC/EGL (production path)",
})

# input
inp_ok, inp_lines = nonempty_sect("DEV_INPUT")
subsystems.append({
    "id": "input",
    "android": {"services": has_svc(["input"])},
    "linux": {"devices": inp_lines},
    "status": status(True, inp_ok, True, True),
    "notes": "evdev + udev + Mir input-evdev",
})

# wifi
wifi_ok, wifi_lines = nonempty_sect("DEV_WIFI")
wifi_svc = has_svc(["wifi", "wifinl80211"])
subsystems.append({
    "id": "wifi",
    "android": {"hw": has_hw(["wifi"]), "services": wifi_svc[:8]},
    "linux": {"net_rfkill": wifi_lines, "nmcli": chroot_pkg("nmcli")},
    "status": status(bool(wifi_svc or has_hw(["wifi"])), wifi_ok, chroot_pkg("nmcli"), True),
    "notes": "Kernel wmtWifi + NetworkManager (wifi-bringup.sh)",
})

# audio
snd_ok, snd_lines = nonempty_sect("DEV_SOUND")
audio_hw = has_hw(["audio"])
audio_svc = has_svc(["audio"])
subsystems.append({
    "id": "audio",
    "android": {"hw": audio_hw[:10], "services": audio_svc[:8]},
    "linux": {"snd": snd_lines, "pulse": chroot_pkg("pulseaudio")},
    "status": status(bool(audio_hw or audio_svc), snd_ok, chroot_pkg("pulseaudio"), False),
    "notes": "ALSA/Pulse kernel path; AIDL audio HAL client Phase 2",
})

# bluetooth
bt_ok, bt_lines = nonempty_sect("DEV_BT")
bt_hw = has_hw(["bluetooth"])
bt_svc = has_svc(["bluetooth"])
subsystems.append({
    "id": "bluetooth",
    "android": {"hw": bt_hw[:8], "services": bt_svc[:8]},
    "linux": {"devices": bt_lines, "bluez": chroot_pkg("bluetoothctl")},
    "status": status(bool(bt_hw or bt_svc), bt_ok, chroot_pkg("bluetoothctl"), False),
    "notes": "BlueZ + rfkill; Android BT HAL Phase 2 if needed",
})

# sensors
iio_ok, iio_lines = nonempty_sect("DEV_IIO")
sens_hw = has_hw(["sensors"])
sens_svc = has_svc(["sensors"])
subsystems.append({
    "id": "sensors",
    "android": {"hw": sens_hw[:8], "services": sens_svc[:8]},
    "linux": {"iio": iio_lines, "iio_proxy": chroot_pkg("iio-sensor-proxy")},
    "status": status(bool(sens_hw or sens_svc), iio_ok, chroot_pkg("iio-sensor-proxy"), False),
    "notes": "iio-sensor-proxy when IIO present; else Sensors AIDL Phase 2",
})

# camera
cam_ok, cam_lines = nonempty_sect("DEV_VIDEO")
cam_hw = has_hw(["camera"])
cam_svc = has_svc(["camera"])
subsystems.append({
    "id": "camera",
    "android": {"hw": cam_hw[:8], "services": cam_svc[:8]},
    "linux": {"v4l2": cam_lines, "libcamera": chroot_pkg("cam")},
    "status": status(bool(cam_hw or cam_svc), cam_ok, chroot_pkg("cam"), False),
    "notes": "V4L2/libcamera permissions; Camera HAL Phase 2 if empty",
})

# gnss
gnss_ok, gnss_lines = nonempty_sect("DEV_GNSS")
gnss_hw = has_hw(["gps", "gnss"])
gnss_svc = has_svc(["gnss", "gps"])
subsystems.append({
    "id": "gnss",
    "android": {"hw": gnss_hw[:8], "services": gnss_svc[:8]},
    "linux": {"devices": gnss_lines},
    "status": status(bool(gnss_hw or gnss_svc), gnss_ok, True, False),
    "notes": "GNSS AIDL / location-service Phase 2",
})

# telephony / ril
modem_ok, modem_lines = nonempty_sect("DEV_MODEM")
ril_hw = has_hw(["radio", "ril"])
ril_svc = has_svc(["radio", "iradio", "telephony"])
subsystems.append({
    "id": "telephony",
    "android": {"hw": ril_hw[:8], "services": ril_svc[:12]},
    "linux": {"modem_nodes": modem_lines, "ofono": chroot_pkg("ofonod")},
    "status": status(bool(ril_hw or ril_svc), modem_ok, chroot_pkg("ofonod"), False),
    "notes": "ofono + ccci nodes; IRadio binder Phase 2",
})

# power / backlight
bl_ok, bl_lines = nonempty_sect("DEV_BACKLIGHT")
ps_ok, ps_lines = nonempty_sect("DEV_POWER")
pwr_svc = has_svc(["power", "vibrator", "lights", "health"])
subsystems.append({
    "id": "power",
    "android": {"services": pwr_svc[:10], "hw": has_hw(["power", "vibrator", "lights", "health"])[:10]},
    "linux": {"backlight": bl_lines, "power_supply": ps_lines, "upower": chroot_pkg("upower")},
    "status": status(True, bl_ok or ps_ok, chroot_pkg("upower"), True),
    "notes": "sysfs backlight + power_supply + upower / indicator-power",
})

# fingerprint
fp_ok, fp_lines = nonempty_sect("DEV_FP")
fp_svc = has_svc(["fingerprint", "biometrics"])
subsystems.append({
    "id": "fingerprint",
    "android": {"services": fp_svc[:8], "hw": has_hw(["fingerprint"])[:8]},
    "linux": {"devices": fp_lines},
    "status": status(bool(fp_svc or has_hw(["fingerprint"])), fp_ok, True, False),
    "notes": "biometryd / Fingerprint AIDL later",
})

# indicators (lomiri UI chrome)
ind_lines = [l for l in sect("CHROOT_PKGS") if "indicator" in l.lower()]
subsystems.append({
    "id": "indicators",
    "android": {},
    "linux": {
        "lomiri_indicator_network": chroot_pkg("lomiri-indicator-network"),
        "ayatana_common": chroot_pkg("ayatana-indicator-common"),
        "units_or_share": ind_lines[:20],
    },
    "status": "bridged" if chroot_pkg("lomiri-indicator-network") else "pkg_only",
    "notes": "Need full lomiri-indicator-* set + user session activation",
})

doc = {
    "session": "hal-inventory",
    "stamp": stamp,
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "meta": meta,
    "vendor_hw_count": len(hw),
    "service_count": len(svc_names),
    "subsystems": subsystems,
    "raw_sections_present": sorted(sections.keys()),
}

json_path.write_text(json.dumps(doc, indent=2) + "\n")

lines = [
    f"# HAL bridge inventory ({stamp})",
    "",
    f"Generated: `{doc['generated_at']}`",
    "",
    "## Device",
    "",
]
for k, v in meta.items():
    lines.append(f"- `{k}`: `{v}`")
lines += [
    "",
    f"- Vendor `lib64/hw` entries: **{len(hw)}**",
    f"- Binder services listed: **{len(svc_names)}**",
    "",
    "## Subsystem matrix",
    "",
    "| Subsystem | Status | Android | Linux | Notes |",
    "|-----------|--------|---------|-------|-------|",
]
for s in subsystems:
    and_bits = []
    a = s.get("android") or {}
    if a.get("hw"):
        and_bits.append("hw:" + ",".join(a["hw"][:3]))
    if a.get("services"):
        and_bits.append("svc:" + ",".join(a["services"][:2]))
    linux_bits = []
    for k, v in (s.get("linux") or {}).items():
        if isinstance(v, bool):
            linux_bits.append(f"{k}={v}")
        elif isinstance(v, list) and v:
            linux_bits.append(f"{k}({len(v)})")
        elif v:
            linux_bits.append(str(k))
    lines.append(
        f"| `{s['id']}` | **{s['status']}** | {'; '.join(and_bits) or '—'} | "
        f"{'; '.join(linux_bits) or '—'} | {s.get('notes', '')} |"
    )

lines += [
    "",
    "## Status legend",
    "",
    "- `bridged` — Lomiri path exists and is intended for production use",
    "- `kernel_only` — kernel/sysfs/dev path usable; no AIDL client yet",
    "- `pkg_only` — Ubuntu package present but no device/HAL evidence",
    "- `missing_linux` — Android HAL present; Ubuntu side incomplete",
    "- `missing` — neither side usable yet",
    "",
    "## Vendor hw (sample)",
    "",
    "```",
    "\n".join(hw[:60]) or "(empty)",
    "```",
    "",
    "## Binder services (sample)",
    "",
    "```",
    "\n".join(svc_names[:80]) or "(empty)",
    "```",
    "",
]
md_path.write_text("\n".join(lines) + "\n")
print(f"Wrote {json_path}")
print(f"Wrote {md_path}")
PY

cp -f "$JSON" "$OUT_DIR/inventory_latest.json"
cp -f "$MD" "$OUT_DIR/inventory_latest.md"
cp -f "$RAW" "$OUT_DIR/inventory_latest.raw.txt"

echo ""
echo "Inventory complete:"
echo "  $JSON"
echo "  $MD"
echo "  $OUT_DIR/inventory_latest.md"

