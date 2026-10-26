#!/bin/sh
HINT=--desktop_file_hint=/usr/share/applications/firefox.desktop
for a in "$@"; do
  case "$a" in --desktop_file_hint=*) HINT=; break;; esac
done
if [ -n "$HINT" ]; then
  exec /usr/lib/firefox/firefox.bin "$HINT" "$@"
else
  exec /usr/lib/firefox/firefox.bin "$@"
fi
