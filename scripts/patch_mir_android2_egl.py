#!/usr/bin/env python3
"""Patch Mir android2 EGL choose attribs.

- Keep display format preference 2,3,1,4,5 (format 1 first → allocate 16666666x1600 → black)
- Reclaim 0x3147 slot for EGL_ALPHA_SIZE=8 (Qt had R/G/B/A=8/8/8/0)
- RECORDABLE → EGL_DONT_CARE
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
IN_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/graphics-android2.so.15")
OUT_DIR = REPO / "builder/out/mir-patches"
OUT_PATH = OUT_DIR / "graphics-android2.so.15"
ATTRIB_OFF = 0x491B8
ALPHA_ATTR_OFF = ATTRIB_OFF + 0x10
ALPHA_VAL_OFF = ATTRIB_OFF + 0x14
RECORDABLE_ATTR_OFF = ATTRIB_OFF + 0x18
RECORDABLE_VAL_OFF = ATTRIB_OFF + 0x1C
EGL_DONT_CARE = -1
EGL_ALPHA_SIZE = 0x3021
EGL_RECORDABLE_ANDROID = 0x3142
FMT_PREF_OFF = 0x491A0
# Proven-working order (format 1 first REJECTED: bad_dims 16666666x1600).
FMT_PREF_SAFE = (2, 3, 1, 4, 5, 0)


def main() -> int:
    data = bytearray(IN_PATH.read_bytes())
    for rel, w in (
        (0x00, 0x3033),
        (0x08, 0x3040),
        (0x20, 0x3024),
        (0x24, 8),
        (0x28, 0x3023),
        (0x2C, 8),
        (0x30, 0x3022),
        (0x34, 8),
        (0x38, 0x3038),
    ):
        got = struct.unpack_from("<i", data, ATTRIB_OFF + rel)[0]
        if got != w:
            raise SystemExit(f"attrib @{ATTRIB_OFF + rel:#x}: expected {w}, got {got}")

    struct.pack_into("<i", data, ALPHA_ATTR_OFF, EGL_ALPHA_SIZE)
    struct.pack_into("<i", data, ALPHA_VAL_OFF, 8)
    struct.pack_into("<i", data, RECORDABLE_ATTR_OFF, EGL_RECORDABLE_ANDROID)
    struct.pack_into("<i", data, RECORDABLE_VAL_OFF, EGL_DONT_CARE)
    struct.pack_into("<6i", data, FMT_PREF_OFF, *FMT_PREF_SAFE)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_bytes(data)
    print(f"wrote {OUT_PATH} md5={hashlib.md5(data).hexdigest()}")
    print("egl_alpha_size=8 fmt_pref=2,3,1,4,5 recordable=DONT_CARE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
