#!/system/bin/sh
# Toggle lcd-backlight on KEY_POWER. Single-instance via mkdir lock
# (toybox flock fails with "Bad file descriptor" under adb background).
BL=/sys/class/leds/lcd-backlight/brightness
MAXF=/sys/class/leds/lcd-backlight/max_brightness
DEV=/dev/input/event1
LOG=/data/local/tmp/powerkey_blank.log
LOCKDIR=/data/local/tmp/powerkey_blank.d
LAST=/data/local/tmp/powerkey_last_cs
PIDF=/data/local/tmp/powerkey_blank.pid

if [ "${1:-}" = "--stop" ]; then
  pid=$(cat "$PIDF" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  killall getevent 2>/dev/null || true
  rm -rf "$LOCKDIR"
  rm -f "$PIDF" /data/local/tmp/powerkey_blank.lock
  echo "powerkey_blank stopped $(date)" >>"$LOG"
  exit 0
fi

# Exclusive: atomic mkdir. Clear stale lock if pid is dead.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  old=$(cat "$PIDF" 2>/dev/null || true)
  if [ -n "$old" ] && [ -d "/proc/$old" ]; then
    echo "powerkey_blank already running pid=$old" >>"$LOG"
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || exit 1
fi

echo $$ >"$PIDF"
echo "powerkey_blank start $(date) pid=$$" >"$LOG"

MAX=$(cat "$MAXF" 2>/dev/null || echo 2047)
ON=$((MAX / 2))
[ "$ON" -lt 4 ] && ON=4

uptime_cs() { awk '{printf "%d", $1 * 100}' /proc/uptime; }

# Cleanup lock on exit (killed by --stop).
trap 'rm -rf "$LOCKDIR"; rm -f "$PIDF"' EXIT INT TERM

getevent -q "$DEV" 2>>"$LOG" | while IFS= read -r line; do
  set -- $line
  type=$1
  code=$2
  val=$3
  if [ "$1" != "0001" ] && [ "$#" -ge 4 ]; then
    type=$2
    code=$3
    val=$4
  fi
  [ "$type" = "0001" ] && [ "$code" = "0074" ] && [ "$val" = "00000001" ] || continue
  now=$(uptime_cs)
  last=$(cat "$LAST" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt 50 ]; then
    echo "$(date) debounce skip" >>"$LOG"
    continue
  fi
  echo "$now" >"$LAST"
  cur=$(cat "$BL" 2>/dev/null || echo 0)
  if [ "$cur" -gt 0 ] 2>/dev/null; then
    echo 0 >"$BL"
    echo "$(date) power->off cur=$cur" >>"$LOG"
  else
    echo "$ON" >"$BL"
    echo "$(date) power->on want=$ON" >>"$LOG"
  fi
done
