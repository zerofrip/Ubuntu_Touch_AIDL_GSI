#!/bin/bash
# Probe Mir nested Wayland host health (XDG_RUNTIME_DIR + wayland-0 + hello).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$REPO/scripts/probe_wayland_hello.py"

adb push "$PROBE" /data/local/tmp/probe_wayland_hello.py >/dev/null

adb shell "su -c '
LOM=\$(pidof lomiri | awk \"{print \\\$1}\")
echo lomiri=\${LOM:-none}
XDG=/run/user/0
if [ -n \"\$LOM\" ]; then
  XDG=\$(tr \"\\0\" \"\\n\" </proc/\$LOM/environ | sed -n \"s/^XDG_RUNTIME_DIR=//p\")
  XDG=\${XDG:-/run/user/0}
fi
echo xdg=\$XDG
ROOT=
[ -n \"\$LOM\" ] && ROOT=/proc/\$LOM/root
if [ -d \"\${ROOT}\${XDG}\" ]; then
  echo xdg_mode=\$(stat -c %a \"\${ROOT}\${XDG}\")
else
  echo xdg_mode=missing
fi
WL=\"\${ROOT}\${XDG}/wayland-0\"
if [ -S \"\$WL\" ] || [ -e \"\$WL\" ]; then
  echo wayland0=yes
  echo wayland0_mode=\$(stat -c %a \"\$WL\" 2>/dev/null || echo ?)
else
  echo wayland0=no
fi
if [ -z \"\$LOM\" ]; then
  echo probe_rc=skip
  exit 1
fi
cp -f /data/local/tmp/probe_wayland_hello.py /proc/\$LOM/root/tmp/probe_wayland_hello.py
# desktop_file_hint must be on argv for qtmir SessionAuthorizer
chroot /proc/\$LOM/root /usr/bin/python3 /tmp/probe_wayland_hello.py \
  --desktop_file_hint=/usr/share/applications/lomiri-system-settings.desktop \
  \"\$XDG/wayland-0\"
echo probe_rc=\$?
'" 2>&1 | tr -d '\r'
