#!/usr/bin/env bash
# Diagnose MTK DRM card0 properties vs HWC checkProperty expectations.
# Writes builder/out/hwc-patches/DRM_DIAG.md
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/builder/out/hwc-patches"
COMPAT="$REPO/builder/out/halium13-compat"
NDK="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/28.2.13676358}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android34-clang"
SRC="$REPO/builder/cache/hwc2-stub/drm_prop_dump.c"
DUMP_BIN="$COMPAT/drm_prop_dump"
DUMP_LOG="$OUT/drm_prop_dump.txt"
MD="$OUT/DRM_DIAG.md"

mkdir -p "$OUT" "$COMPAT"

echo "== build drm_prop_dump =="
"$CC" -O2 -Wall -I"$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include" \
  -o "$DUMP_BIN" "$SRC"
adb push "$DUMP_BIN" /data/local/tmp/drm_prop_dump >/dev/null
adb shell 'su 0 chmod 755 /data/local/tmp/drm_prop_dump'

echo "== sysfs / debugfs snapshot =="
SYSFS_LOG="$OUT/drm_sysfs.txt"
adb shell 'su 0 sh -c "
echo === /sys/class/drm ===
ls -la /sys/class/drm/
for d in /sys/class/drm/card0-*; do
  echo --- \$d ---
  for f in status enabled modes power dpms; do
    [ -e \$d/\$f ] && echo \$f=\$(cat \$d/\$f 2>/dev/null | tr \"\\n\" \" \")
  done
done
echo === clients ===
cat /sys/kernel/debug/dri/0/clients 2>/dev/null || true
echo === state connectors/crtcs ===
grep -E \"^(connector|crtc)\\[\" -A6 /sys/kernel/debug/dri/0/state 2>/dev/null | head -80
"' >"$SYSFS_LOG" || true

echo "== drm_prop_dump on device =="
# Prefer free card; if Mir holds master, dump still works as non-master for GET*
adb shell 'su 0 /data/local/tmp/drm_prop_dump /dev/dri/card0' >"$DUMP_LOG" 2>&1 || {
  echo "drm_prop_dump failed; see $DUMP_LOG" >&2
}

# Expected property names referenced by HWC log / strings (best-effort)
EXPECTED_CONN="CRTC_ID DPMS EDID PATH TILE link-status non-desktop HDR_SOURCE_METADATA"
EXPECTED_PLANE="type CRTC_ID FB_ID CRTC_X CRTC_Y CRTC_W CRTC_H SRC_X SRC_Y SRC_W SRC_H IN_FENCE_FD"

python3 - "$DUMP_LOG" "$SYSFS_LOG" "$MD" <<'PY'
import re, sys
from pathlib import Path
from datetime import datetime, timezone

dump = Path(sys.argv[1]).read_text(errors="replace")
sysfs = Path(sys.argv[2]).read_text(errors="replace")
md_path = Path(sys.argv[3])

# Collect props per object
objs = {}
cur = None
for line in dump.splitlines():
    m = re.match(r"=== (connector|plane|crtc) id=(\d+)", line)
    if m:
        cur = (m.group(1), int(m.group(2)))
        objs.setdefault(cur, set())
        continue
    m = re.match(r"  (connector|plane|crtc) id=(\d+) props=", line)
    if m:
        cur = (m.group(1), int(m.group(2)))
        objs.setdefault(cur, set())
        continue
    m = re.match(r"\s+prop\[\d+\] id=\d+ name=(\S+)", line)
    if m and cur:
        objs[cur].add(m.group(1))

conn_props = {oid: names for (kind, oid), names in objs.items() if kind == "connector"}
plane_props = {oid: names for (kind, oid), names in objs.items() if kind == "plane"}

# HWC historically fails connectors 31/162 and many planes; primary DSI is 34
primary = 34
fail_conns = [c for c in sorted(conn_props) if c != primary]

# Common atomic KMS props HWC typically requires
must_plane = {"type", "CRTC_ID", "FB_ID", "CRTC_X", "CRTC_Y", "CRTC_W", "CRTC_H",
              "SRC_X", "SRC_Y", "SRC_W", "SRC_H"}
must_conn = {"CRTC_ID", "DPMS"}

missing_planes = []
for oid, names in sorted(plane_props.items()):
    miss = sorted(must_plane - names)
    if miss:
        missing_planes.append((oid, miss, sorted(names)))

missing_conns = []
for oid, names in sorted(conn_props.items()):
    miss = sorted(must_conn - names)
    if miss:
        missing_conns.append((oid, miss, sorted(names)))

lines = []
lines.append("# MTK DRM Diagnostics (F8 / card0)")
lines.append("")
lines.append(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')}")
lines.append("")
lines.append("## Summary")
lines.append("")
lines.append("- Device: `/dev/dri/card0` with UNIVERSAL_PLANES + ATOMIC client caps")
lines.append(f"- Connectors seen: {sorted(conn_props.keys())}")
lines.append(f"- Planes seen: {len(plane_props)}")
if missing_conns:
    lines.append("- **Missing common connector props:**")
    for oid, miss, _ in missing_conns:
        lines.append(f"  - connector {oid}: missing `{miss}`")
else:
    lines.append("- Common connector props (CRTC_ID, DPMS): present on all connectors")
if missing_planes:
    lines.append(f"- **Planes missing common atomic props:** {len(missing_planes)}/{len(plane_props)}")
    for oid, miss, _ in missing_planes[:8]:
        lines.append(f"  - plane {oid}: missing `{miss}`")
    if len(missing_planes) > 8:
        lines.append(f"  - ... and {len(missing_planes)-8} more")
else:
    lines.append("- Common plane atomic props: present on all planes")
lines.append("")
lines.append("HWC `checkProperty` returns hardcoded `-22` when a *named* property")
lines.append("lookup fails in userspace (not necessarily kernel EINVAL). Soft-fail")
lines.append("patches at `0x18e57c` (connector) and `0x1917d0` (DrmObject/plane)")
lines.append("treat missing props as success so primary DSI modeset can proceed.")
lines.append("")
lines.append("## Sysfs / debugfs")
lines.append("")
lines.append("```")
lines.append(sysfs.strip()[:4000] or "(empty)")
lines.append("```")
lines.append("")
lines.append("## Per-connector property names")
lines.append("")
for oid in sorted(conn_props):
    names = ", ".join(sorted(conn_props[oid])) or "(none)"
    lines.append(f"- **connector {oid}**: {names}")
lines.append("")
lines.append("## Per-plane property names (compact)")
lines.append("")
# Group by identical prop sets
groups = {}
for oid, names in plane_props.items():
    key = tuple(sorted(names))
    groups.setdefault(key, []).append(oid)
for key, ids in groups.items():
    lines.append(f"- planes {ids}: `{', '.join(key) if key else '(none)'}`")
lines.append("")
lines.append("## Raw dump")
lines.append("")
lines.append(f"Full dump: `builder/out/hwc-patches/drm_prop_dump.txt` ({len(dump)} bytes)")
lines.append("")
lines.append("## Soft-fail decision")
lines.append("")
if missing_planes or any(c != primary for c in conn_props):
    lines.append("- Proceed with Patch-D soft-fail on connector+plane `checkProperty` `-22`.")
    lines.append("- Primary DSI connector **34** remains the modeset target; DP/Writeback")
    lines.append("  and incomplete planes should no longer abort DRM resource init.")
else:
    lines.append("- Kernel exposes expected props; soft-fail still applied as defense in depth")
    lines.append("  against HWC-specific required name lists.")
lines.append("")

md_path.write_text("\n".join(lines) + "\n")
print(f"wrote {md_path}")
print(f"connectors={sorted(conn_props)} planes={len(plane_props)} "
      f"missing_conn={len(missing_conns)} missing_plane={len(missing_planes)}")
PY

echo "done: $MD"
