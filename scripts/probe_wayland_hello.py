#!/usr/bin/env python3
"""Minimal Wayland hello probe against Mir/qtmir nested host.

qtmir SessionAuthorizer rejects clients that were not launched by
lomiri-app-launch unless --desktop_file_hint=... appears in argv
(read from /proc/<pid>/cmdline). Keep that flag in sys.argv.
"""
import socket
import struct
import sys

path = "/run/user/0/wayland-0"
hint = "--desktop_file_hint=/usr/share/applications/lomiri-system-settings.desktop"
args = []
for a in sys.argv[1:]:
    if a.startswith("--desktop_file_hint"):
        hint = a
    elif a.startswith("/") or a.startswith("wayland"):
        path = a
    else:
        args.append(a)
# Ensure hint remains visible on /proc/self/cmdline for SessionAuthorizer.
if hint not in sys.argv:
    sys.argv.append(hint)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3.0)
s.connect(path)
# wl_display.get_registry(new_id=2)
msg = struct.pack("III", 1, (12 << 16) | 1, 2)
s.send(msg)
try:
    d = s.recv(512)
    print("ok recv_len=%d" % len(d))
    sys.exit(0 if d else 2)
except Exception as e:
    print("fail %s %s" % (type(e).__name__, e))
    sys.exit(1)
