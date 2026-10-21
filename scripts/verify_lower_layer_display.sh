#!/usr/bin/env bash
# =============================================================================
# verify_lower_layer_display.sh — DRM/KMS lower-layer Go/No-Go (does NOT switch
# production Lomiri off HWC). See docs/lower-layer-display.md.
# =============================================================================
# Steps:
#   1) DRM node + connector/crtc snapshot
#   2) Optional drm_prop_dump (if NDK binary built)
#   3) Probe whether Mir android2 can be disabled (flag file only — no restart
#      unless VERIFY_LOWER_LAYER_TRY_MIR=1)
#   4) Record HWC path still present as control
#
# Usage:
#   bash scripts/verify_lower_layer_display.sh
#   VERIFY_LOWER_LAYER_TRY_MIR=1 bash scripts/verify_lower_layer_display.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO/builder/out/lower-layer-display}"
COMPAT="$REPO/builder/out/halium13-compat"
DUMP_BIN="$COMPAT/drm_prop_dump"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR"

RAW="$OUT_DIR/verify_${STAMP}.raw.txt"
MD="$OUT_DIR/verify_${STAMP}.md"
DOC="$REPO/docs/lower-layer-display.md"

su0() { adb shell "su 0 $*" 2>/dev/null | tr -d '\r'; }

{
  echo "=== lower-layer verify $STAMP ==="
  echo "=== props ==="
  for p in ro.hardware ro.board.platform sys.boot_completed; do
    echo -n "$p="; adb shell getprop "$p" | tr -d '\r'
  done

  echo "=== DRM nodes ==="
  su0 "ls -la /dev/dri 2>&1" || true
  su0 "ls -la /sys/class/drm 2>&1" || true

  echo "=== connectors ==="
  su0 "sh -c '
    for d in /sys/class/drm/card*-*; do
      [ -d \"\$d\" ] || continue
      echo --- \$(basename \$d) ---
      for f in status enabled modes dpms power; do
        [ -e \"\$d/\$f\" ] && echo \$f=\$(cat \"\$d/\$f\" 2>/dev/null | tr \"\\n\" \" \")
      done
    done
  '" || true

  echo "=== HWC / android2 control ==="
  su0 "ls /vendor/lib64/hw/hwcomposer*.so 2>&1" || true
  su0 "pidof lomiri surfaceflinger 2>&1" || true
  su0 "ls /data/local/tmp/lomiri_disable_android2 /data/uhl_overlay/lomiri_disable_android2 2>&1" || true

  echo "=== DRM master clients (debugfs) ==="
  su0 "cat /sys/kernel/debug/dri/0/clients 2>&1 | head -40" || true

  if [ -x "$DUMP_BIN" ]; then
    echo "=== drm_prop_dump ==="
    adb push "$DUMP_BIN" /data/local/tmp/drm_prop_dump >/dev/null
    su0 "chmod 755 /data/local/tmp/drm_prop_dump"
    su0 "/data/local/tmp/drm_prop_dump /dev/dri/card0 2>&1" | head -120 || true
  else
    echo "=== drm_prop_dump SKIP (build via scripts/diag_mtk_drm.sh) ==="
  fi

  if [ "${VERIFY_LOWER_LAYER_TRY_MIR:-0}" = "1" ]; then
    echo "=== TRY_MIR: set disable_android2 flag (does not kill running lomiri) ==="
    su0 "touch /data/local/tmp/lomiri_disable_android2; ls -la /data/local/tmp/lomiri_disable_android2"
  fi
} | tee "$RAW"

python3 - "$RAW" "$MD" "$STAMP" <<'PY'
import re, sys
from pathlib import Path
from datetime import datetime, timezone

raw = Path(sys.argv[1]).read_text(errors="replace")
md_path = Path(sys.argv[2])
stamp = sys.argv[3]

has_card = bool(re.search(r"/dev/dri/card\d+", raw)) or "card0" in raw
# DRM connection: 1=connected in drmMode; sysfs often "connected"
has_conn = (
    "status=connected" in raw
    or re.search(r"connection=1\b", raw) is not None
    or re.search(r"card0-DSI|card0-DPI|card0-HDMI", raw) is not None
)
has_hwc = "hwcomposer" in raw
lomiri = re.search(r"pidof.*\n([0-9 ]+)", raw)
drm_dump = "=== drm_prop_dump ===" in raw and "prop[" in raw
clients_blocked = "master" in raw.lower() and "lomiri" in raw.lower()

# Decision heuristics
blockers = []
if not has_card:
    blockers.append("No /dev/dri/card* — cannot modeset")
if not has_conn and has_card:
    blockers.append("No connected DRM connector reported in sysfs snapshot")
if not has_hwc:
    blockers.append("Vendor HWC missing (unexpected on this project)")

# Go only if DRM card+connector exist AND we have evidence modeset tooling works.
# Stock MTK often keeps DRM master in HWC — treat as CONDITIONAL / No-Go for Mir GBM.
if has_card and has_conn and not blockers:
    verdict = "CONDITIONAL"
    summary = (
        "DRM nodes and connector sysfs look present. Production stays on HWC. "
        "Mir GBM/android2-off is not enabled by default; requires exclusive DRM master "
        "which MTK HWC typically holds — treat as experiment-only until a present probe succeeds."
    )
else:
    verdict = "NO-GO"
    summary = "Lower-layer DRM/GBM path not viable yet: " + ("; ".join(blockers) or "incomplete evidence")

if has_card and has_conn:
    # Prefer CONDITIONAL over hard GO without atomic present proof
    verdict = "CONDITIONAL"

lines = [
    f"# Lower-layer display verify ({stamp})",
    "",
    f"Generated: `{datetime.now(timezone.utc).isoformat()}`",
    "",
    f"**Verdict: {verdict}**",
    "",
    summary,
    "",
    "## Evidence checklist",
    "",
    f"- DRM card node: {'yes' if has_card else 'no'}",
    f"- Connector sysfs: {'yes' if has_conn else 'no/unknown'}",
    f"- Vendor HWC present: {'yes' if has_hwc else 'no'}",
    f"- drm_prop_dump props: {'yes' if drm_dump else 'no/skipped'}",
    "",
    "## Interpretation",
    "",
    "| Verdict | Meaning |",
    "|---------|---------|",
    "| GO | Exclusive DRM master + Mesa/GBM Mir path proven; optional flag may switch |",
    "| CONDITIONAL | DRM visible but HWC still required for reliable present |",
    "| NO-GO | Missing DRM/connector or hard blockers |",
    "",
    "## Raw log",
    "",
    f"See `{Path(sys.argv[1]).name}` in `builder/out/lower-layer-display/`.",
    "",
]
md_path.write_text("\n".join(lines) + "\n")
print(f"Verdict={verdict}")
print(f"Wrote {md_path}")
# expose for shell
Path(sys.argv[1] + ".verdict").write_text(verdict + "\n")
PY

VERDICT=$(cat "${RAW}.verdict" 2>/dev/null || echo CONDITIONAL)
cp -f "$MD" "$OUT_DIR/verify_latest.md"
cp -f "$RAW" "$OUT_DIR/verify_latest.raw.txt"

# Refresh docs/lower-layer-display.md with latest verdict (keep procedure stable)
cat > "$DOC" << EOF
# Lower-layer display verification (DRM/KMS vs HWC)

## Recommendation (2-D)

| Candidate | Role |
|-----------|------|
| **DRM/KMS + Mesa GBM** (Mir without android2) | Primary experiment — true layer below HWC |
| fbdev | Diagnostics only |
| Current HWC + libhybris | **Production default** |

## Latest automated verdict

- **Stamp:** \`${STAMP}\`
- **Verdict:** **${VERDICT}**
- **Artifact:** \`builder/out/lower-layer-display/verify_latest.md\`

Regenerate:

\`\`\`bash
bash scripts/verify_lower_layer_display.sh
# optional: also build prop dump
# bash scripts/diag_mtk_drm.sh
\`\`\`

## Procedure

1. Confirm \`/dev/dri/card*\` and connected connector under \`/sys/class/drm\`.
2. Run \`drm_prop_dump\` (via \`diag_mtk_drm.sh\`) for connector/crtc/plane props.
3. Keep SurfaceFlinger stopped (Halium hand-off). Do **not** unbind NVT or rebind HWC carelessly.
4. Optional experiment: \`VERIFY_LOWER_LAYER_TRY_MIR=1\` creates
   \`/data/local/tmp/lomiri_disable_android2\` (start-lomiri / device_prep honour this when wired).
5. Production path remains Mir android2 → libhybris → vendor HWC until verdict is **GO**
   with a successful exclusive modeset/present.

## Go criteria

- Exclusive DRM master obtainable without vendor HWC process
- Atomic modeset + frame present without HWC
- Mir (or a Mesa GBM test client) displays a frame for ≥30s without crash
- Touch/input still works under the same session

## Current project default

**Do not switch** \`start-lomiri.sh\` off HWC based on CONDITIONAL results.
EOF

echo ""
echo "Lower-layer verify done: verdict=$VERDICT"
echo "  $MD"
echo "  $DOC"
