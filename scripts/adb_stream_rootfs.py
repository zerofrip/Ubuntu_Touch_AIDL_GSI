#!/usr/bin/env python3
"""Stream linux_rootfs.erofs to device via adb shell dd (avoids adb push hangs)."""
from __future__ import annotations

import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "builder", "out", "linux_rootfs.erofs")
ROOTFS = os.path.join(REPO, "builder", "out", "ubuntu-rootfs")
REMOTE = "/data/ubuntu-gsi/rootfs.erofs"
CHUNK = 4 * 1024 * 1024
MIN_BYTES = 64 * 1024 * 1024  # reject stub/empty images


def _adb_devices() -> str:
    p = subprocess.run(
        ["adb", "devices", "-l"],
        capture_output=True,
        text=True,
        check=False,
    )
    return (p.stdout or "") + (p.stderr or "")


def wait_for_adb_device(timeout_s: int = 20) -> bool:
    listing = _adb_devices()
    if "\tdevice" in listing:
        return True
    print("No adb device yet — waiting (enable USB debugging / authorize this PC)...", flush=True)
    try:
        subprocess.run(
            ["adb", "wait-for-device"],
            timeout=timeout_s,
            check=False,
        )
    except subprocess.TimeoutExpired:
        pass
    listing = _adb_devices()
    return "\tdevice" in listing


def main() -> int:
    if not os.path.isfile(SRC):
        print(f"missing {SRC}", file=sys.stderr)
        print("  run: sudo GSI_ROOTFS_PROFILE=minimal bash scripts/build_rootfs.sh", file=sys.stderr)
        print("  then: bash scripts/build_rootfs_erofs.sh", file=sys.stderr)
        return 1
    size = os.path.getsize(SRC)
    if size < MIN_BYTES:
        print(f"refusing to stream tiny erofs ({size} bytes): {SRC}", file=sys.stderr)
        print("  rebuild rootfs + erofs first (see above commands)", file=sys.stderr)
        return 1
    if not os.path.isfile(os.path.join(ROOTFS, "etc", "os-release")):
        print(f"warning: rootfs missing at {ROOTFS} — erofs may be stale", file=sys.stderr)
    print(f"streaming {size} bytes -> {REMOTE}", flush=True)
    if not wait_for_adb_device():
        print("adb: no devices/emulators found", file=sys.stderr)
        print("  Connect the F8 over USB, authorize debugging, then re-run.", file=sys.stderr)
        print("  Check: adb devices", file=sys.stderr)
        return 1
    subprocess.check_call(["adb", "shell", "su 0 mkdir -p /data/ubuntu-gsi"])
    proc = subprocess.Popen(
        ["adb", "shell", f"su 0 dd of={REMOTE} bs=4M status=none"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdin is not None
    sent = 0
    t0 = time.time()
    with open(SRC, "rb") as fh:
        while True:
            chunk = fh.read(CHUNK)
            if not chunk:
                break
            proc.stdin.write(chunk)
            proc.stdin.flush()
            sent += len(chunk)
            if sent % (64 * 1024 * 1024) < CHUNK or sent == size:
                elapsed = time.time() - t0 + 1e-6
                print(
                    f"sent={sent}/{size} ({100 * sent / size:.1f}%) "
                    f"{sent / elapsed / 1024 / 1024:.1f}MB/s",
                    flush=True,
                )
    proc.stdin.close()
    rc = proc.wait(timeout=1200)
    out = proc.stdout.read() if proc.stdout else b""
    err = proc.stderr.read() if proc.stderr else b""
    print("rc", rc, flush=True)
    if out:
        print("stdout", out[:500], flush=True)
    if err:
        print("stderr", err[:500], flush=True)
    # verify remote size
    remote = subprocess.check_output(
        ["adb", "shell", f"su 0 stat -c %s {REMOTE}"], text=True
    ).strip().replace("\r", "")
    print(f"remote_size={remote} expected={size}", flush=True)
    if remote == str(size) and rc == 0:
        subprocess.check_call(
            [
                "adb",
                "shell",
                "su 0 sh -c '"
                "cd /data/ubuntu-gsi && "
                "(sha256sum rootfs.erofs 2>/dev/null || toybox sha256sum rootfs.erofs) "
                "> rootfs.erofs.sha256'",
            ]
        )
        print("wrote remote sha256", flush=True)
    return 0 if remote == str(size) and rc == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
