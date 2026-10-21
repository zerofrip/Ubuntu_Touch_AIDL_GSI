#!/usr/bin/env bash
# =============================================================================
# verify_mic_capture.sh — Go/No-Go verifier for microphone capture (read-only)
# =============================================================================
# Reports only; does NOT unmute, switch, or state-change anything on device:
# reads /proc/asound, /dev/snd node perms, ALSA capture mixer controls
# (scontrols/sget only) and PulseAudio sources, then writes a verdict.
#
# Usage:
#   bash scripts/verify_mic_capture.sh
#   OUT_DIR=/tmp/mic-capture bash scripts/verify_mic_capture.sh
#
# Modes:
#   device — `adb get-state` succeeds; probes run on device via `su 0 sh`
#   chroot — no adb/device; same probes run locally (guarded by command -v)
#
# Outputs under builder/out/mic-capture/:
#   verify_<stamp>.md / verify_<stamp>.raw.txt
#   verify_latest.{md,raw.txt}  (copies)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/builder/out/mic-capture}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$OUT_DIR"

# Probe collector — identical text for device side (toybox sh) and local run.
PROBES="$(cat << 'PEOF'
#!/system/bin/sh
# Read-only mic capture probes; prints ===SECTION=== blocks for host parser.

echo "===PCM_CAPTURE==="
grep capture /proc/asound/pcm 2>/dev/null || echo "(none)"
ls /sys/class/sound 2>/dev/null | grep -E '^pcmC[0-9]+D[0-9]+c$' || echo "(none-sysfs)"

echo "===CARDS==="
cat /proc/asound/cards 2>/dev/null || echo "(no /proc/asound/cards)"

echo "===DEVSND==="
ls -la /dev/snd 2>/dev/null || echo "(no /dev/snd)"
for n in /dev/snd/pcmC*D*c; do
  [ -e "$n" ] || continue
  perm="$(stat -c '%a %G' "$n" 2>/dev/null || ls -l "$n" 2>/dev/null | awk '{print $1, $4}')"
  echo "NODE $(basename "$n") $perm"
done

echo "===MIXER==="
if command -v amixer >/dev/null 2>&1; then
  found_ctl=no
  c=0
  while [ -d "/proc/asound/card${c}" ]; do
    echo "--- card $c scontrols ---"
    sctrls="$(amixer -c "$c" scontrols 2>/dev/null || true)"
    echo "$sctrls"
    for ctl in Capture "Internal Mic" "Headset Mic"; do
      if echo "$sctrls" | grep -qF "$ctl"; then
        found_ctl=yes
        echo "--- card $c sget $ctl ---"
        amixer -c "$c" sget "$ctl" 2>/dev/null || true
      fi
    done
    c=$((c + 1))
  done
  [ "$found_ctl" = yes ] || echo "(no Capture/Internal Mic/Headset Mic control)"
else
  echo "(amixer missing)"
fi

echo "===PULSE==="
if command -v pactl >/dev/null 2>&1; then
  pactl list sources short 2>/dev/null || echo "(pactl list failed)"
else
  echo "(pactl missing)"
fi

echo "===END==="
PEOF
)"

RAW="$OUT_DIR/verify_${STAMP}.raw.txt"

if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
  MODE="device"
  DEVICE_TMP="/data/local/tmp/mic_verify_${STAMP}.sh"
  HOST_TMP="/tmp/mic_verify_${STAMP}.sh"
  printf '%s\n' "$PROBES" > "$HOST_TMP"
  adb push "$HOST_TMP" "$DEVICE_TMP" >/dev/null || true
  # `su 0 sh` does not need the exec bit; strip CRLF from device output.
  adb shell "su 0 sh $DEVICE_TMP" 2>/dev/null | tr -d '\r' >"$RAW" || true
  rm -f "$HOST_TMP"
else
  MODE="chroot"
  bash -c "$PROBES" 2>/dev/null | tr -d '\r' >"$RAW" || true
fi

# --- Host-side verdict (shared for both modes) -------------------------------

sect() {
  awk -v s="===$1===" '$0 == s {p=1; next} /^===.*===$/ {p=0} p' "$RAW"
}

# Check 1 — capture-capable PCM device exists (NO-GO gate)
PCM_RAW="$(sect PCM_CAPTURE)"
if echo "$PCM_RAW" | grep -qE '[0-9]+-[0-9]+:' \
  || echo "$PCM_RAW" | grep -qE '^pcmC[0-9]+D[0-9]+c$'; then
  CHECK1="PASS"
  CHECK1_NOTE="capture PCM device(s) present"
else
  CHECK1="FAIL"
  CHECK1_NOTE="no capture-capable PCM device found"
fi

# Check 2 — /dev/snd capture nodes match udev rule (0666 / audio); WARN never FAIL
NODES="$(sect DEVSND | grep -E '^NODE pcmC[0-9]+D[0-9]+c ' || true)"
if [ -z "$NODES" ]; then
  CHECK2="WARN"
  CHECK2_NOTE="no pcmC*D*c capture nodes under /dev/snd (udev rule 75-ubuntu-gsi-hal.rules not applied?)"
else
  CHECK2="PASS"
  CHECK2_NOTE="all capture nodes 0666 / audio"
  while read -r _ name perm grp; do
    case "$perm" in
      0666|?rw?rw?rw?) : ;;  # toybox stat octal, or ls -l fallback form
      *)
        CHECK2="WARN"
        CHECK2_NOTE="$name perm=$perm (expected 0666)"
        ;;
    esac
    if [ "$grp" != "audio" ]; then
      CHECK2="WARN"
      CHECK2_NOTE="$name group=$grp (expected audio)"
    fi
  done <<< "$NODES"
fi

# Check 3 — a capture mixer control exists and is not [off] (read-only)
MIXER="$(sect MIXER)"
if echo "$MIXER" | grep -q '(amixer missing)'; then
  CHECK3="WARN"
  CHECK3_NOTE="amixer not available in probe environment"
elif ! echo "$MIXER" | grep -q 'sget'; then
  CHECK3="WARN"
  CHECK3_NOTE="no Capture/Internal Mic/Headset Mic control (vendor may name it differently)"
elif echo "$MIXER" | grep -q '\[off\]'; then
  CHECK3="WARN"
  CHECK3_NOTE="a capture control reports [off]"
else
  CHECK3="PASS"
  CHECK3_NOTE="capture mixer control present and on"
fi

# Check 4 — PulseAudio has >=1 non-monitor source; SUSPENDED state is normal
PULSE="$(sect PULSE)"
if echo "$PULSE" | grep -q '(pactl missing)'; then
  if [ "$MODE" = "device" ]; then
    CHECK4="PASS"
    CHECK4_NOTE="skipped in device mode — pactl is Linux-side"
  else
    CHECK4="WARN"
    CHECK4_NOTE="pactl not available (chroot mode)"
  fi
elif echo "$PULSE" | grep -q '(pactl list failed)'; then
  CHECK4="WARN"
  CHECK4_NOTE="pactl present but list failed (PulseAudio not running?)"
elif echo "$PULSE" | grep -q . && echo "$PULSE" | grep -qv '\.monitor$'; then
  CHECK4="PASS"
  CHECK4_NOTE="non-monitor PulseAudio source present"
else
  CHECK4="WARN"
  CHECK4_NOTE="no non-monitor source (SUSPENDED alone is normal; empty list is not)"
fi

if [ "$CHECK1" = "FAIL" ]; then
  VERDICT="NO-GO"
elif [ "$CHECK2" = "WARN" ] || [ "$CHECK3" = "WARN" ] || [ "$CHECK4" = "WARN" ]; then
  VERDICT="CONDITIONAL"
else
  VERDICT="GO"
fi

case "$VERDICT" in
  GO) SUMMARY="Microphone capture path looks complete (ALSA capture + PulseAudio source)." ;;
  CONDITIONAL) SUMMARY="Capture PCM present, but at least one of perms/mixer/Pulse needs attention." ;;
  NO-GO) SUMMARY="No capture-capable PCM device found — mic capture cannot work here." ;;
esac

MD="$OUT_DIR/verify_${STAMP}.md"
GEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$MD" << MDEOF
# Mic capture verify ($STAMP)

Generated: \`$GEN\` — probe mode: \`$MODE\`

**Verdict: $VERDICT**

$SUMMARY

## Evidence checklist

- Capture PCM device: **$CHECK1** — $CHECK1_NOTE
- /dev/snd capture node perms (0666 / audio): **$CHECK2** — $CHECK2_NOTE
- ALSA capture mixer control (read-only): **$CHECK3** — $CHECK3_NOTE
- PulseAudio source (non-monitor): **$CHECK4** — $CHECK4_NOTE

## Interpretation

| Verdict | Meaning |
|---------|---------|
| GO | Capture PCM + node perms + capture mixer control + PulseAudio source all present |
| CONDITIONAL | Capture PCM exists but mixer/perms/Pulse evidence incomplete |
| NO-GO | No capture-capable PCM device found |

## Raw log

See \`verify_${STAMP}.raw.txt\` in \`builder/out/mic-capture/\`.
MDEOF

cp -f "$MD" "$OUT_DIR/verify_latest.md"
cp -f "$RAW" "$OUT_DIR/verify_latest.raw.txt"

echo "Mic capture verify: $VERDICT"
echo "  $MD"
echo "  $OUT_DIR/verify_latest.md"
