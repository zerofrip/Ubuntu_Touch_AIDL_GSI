#!/bin/bash
# scripts/check_chroot_apt.sh — chroot apt via host HTTP proxy + adb reverse.
# Device often has no Wi‑Fi framework service; apt uses 127.0.0.1:3128 → host.
# Also adds a non-loopback IPv4 on dummy0 so glibc AI_ADDRCONFIG can resolve
# 127.0.0.1 (otherwise apt fails with "Could not resolve '127.0.0.1'").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROOT="${CHROOT:-/mnt/halium/merged}"
PROXY_PORT="${APT_PROXY_PORT:-3128}"
PROXY_PID_FILE="$REPO/builder/out/apt_http_proxy.pid"
PROXY_LOG="$REPO/builder/out/apt_http_proxy.log"
INNER="$SCRIPT_DIR/chroot_apt_update.sh"

mkdir -p "$REPO/builder/out"

if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
    echo "apt proxy already running pid=$(cat "$PROXY_PID_FILE")"
else
    : >"$PROXY_LOG"
    python3 "$SCRIPT_DIR/apt_http_proxy.py" "$PROXY_PORT" >>"$PROXY_LOG" 2>&1 &
    echo $! >"$PROXY_PID_FILE"
    sleep 0.5
    echo "apt proxy started pid=$(cat "$PROXY_PID_FILE") port=$PROXY_PORT"
fi

adb reverse "tcp:${PROXY_PORT}" "tcp:${PROXY_PORT}"
echo "adb reverse tcp:${PROXY_PORT} ok"

# AI_ADDRCONFIG needs a non-loopback IPv4 somewhere on the device.
adb shell su 0 ip link set dummy0 up >/dev/null 2>&1 || true
adb shell su 0 ip addr add 10.255.255.1/32 dev dummy0 >/dev/null 2>&1 || true

adb push "$INNER" /data/local/tmp/chroot_apt_update.sh >/dev/null
adb shell su 0 cp /data/local/tmp/chroot_apt_update.sh "$CHROOT/tmp/chroot_apt_update.sh"
adb shell su 0 chmod 755 "$CHROOT/tmp/chroot_apt_update.sh"

adb shell su 0 chroot "$CHROOT" /bin/bash /tmp/chroot_apt_update.sh
echo "OK: chroot apt-get update + dry-run hello succeeded"
