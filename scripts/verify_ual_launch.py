#!/usr/bin/env python3
"""Launch an app via ual_systemd_stub StartTransientUnit (session bus)."""
import sys

import dbus

def main():
    if len(sys.argv) < 2:
        print("usage: verify_ual_launch.py /path/to/binary [args...]", file=sys.stderr)
        sys.exit(2)
    exe = sys.argv[1]
    argv = list(sys.argv[1:])
    bus = dbus.SessionBus()
    mgr = dbus.Interface(
        bus.get_object("org.freedesktop.systemd1", "/org/freedesktop/systemd1"),
        "org.freedesktop.systemd1.Manager",
    )
    one = dbus.Struct(
        (dbus.String(exe), dbus.Array(argv, signature="s"), dbus.Boolean(False)),
        signature="(sasb)",
    )
    props = [("ExecStart", dbus.Array([one], signature="(sasb)"))]
    unit = "verify-%s.service" % (exe.rsplit("/", 1)[-1].replace(".", "_"))
    path = mgr.StartTransientUnit(unit, "fail", props, [])
    print("started", unit, path)


if __name__ == "__main__":
    main()
