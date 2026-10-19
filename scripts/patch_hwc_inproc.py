#!/usr/bin/env python3
"""Apply in-process HWC gate patches on top of PQ-patched hwcomposer.

Input:  builder/out/hwc-patches/hwcomposer.mtk_common.patched.so
Output: builder/out/hwc-patches/hwcomposer.mtk_common.inproc.so

Patches:
  A) CREATE_LAYER jump table → existing ae850 thunk; rewrite thunk for HWC2 3-arg
  A2) SET_CLIENT_TARGET jump table → aed30; rewrite for HWC2 + slot=0
  B) NOP connected-flag cbz in setPower / createLayer / setClientTarget
  D) checkProperty soft-fail: missing DRM prop → 0 instead of -22
  F) setActiveConfig: force updateActiveConfig (skip same-config / count gates)
  G) empty connector modes → getNumConfigs=1, getModeWidth/Height=1600/2560
  H) ValidateDisplay thunk ABI; force isValidated; PresentValiState=3 + isConnected;
     onPlugIn past already-connected
  H3) AbortMessager::abort → ret (no process kill); keep isNoDispatchThread stock
     (async OverlayEngine — sync+thread raced → destroyed mutex / SIGABRT)
  (Patch-E setDamage NOP removed: full-frame damage vector + valid MTK handle)
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
IN_PATH = REPO / "builder/out/hwc-patches/hwcomposer.mtk_common.patched.so"
OUT_PATH = REPO / "builder/out/hwc-patches/hwcomposer.mtk_common.inproc.so"

NOP = 0xD503201F
# ldr x8,[x8,#0xf98] after adrp x8 → singleton cell (same as stock stubs)
ADRP_X8_1D0000 = 0xD0000908
# Validate thunk lives at 0xaf120; adrp encoding differs from ae850 (PC-relative)
ADRP_X8_1D0000_AF120 = 0xB0000908
LDR_X8_X8_F98 = 0xF947CD08
# mov wN, wzr
MOV_W23_WZR = 0x2A1F03F7
MOV_W0_WZR = 0x2A1F03E0
# movn wN, #0x15  →  wN = -22
MOVN_W23_M22 = 0x128002B7
MOVN_W0_M22 = 0x128002A0
# Patch-G immediates (AArch64 MOVZ wd, #imm)
MOV_W0_1 = 0x52800020  # mov w0, #1
MOV_W0_1600 = 0x5280C800  # mov w0, #0x640 (1600)
MOV_W0_2560 = 0x52814000  # mov w0, #0xa00 (2560)

# Jump table halfwords (descriptor-1) → stock dispatcher that returns stub addr
JT_CREATE_LAYER = 0x63992  # was 4 (NULL); 290 → returns 0xae850
JT_SET_CLIENT_TARGET = 0x639BC  # was 4; 310 → returns 0xaed30
HALF_CREATE = 290
HALF_SET_CT = 310

# Explicit high-value connected-flag fail branches (verified opcodes).
CONNECTED_CBZ = (
    (0xC1794, 0x34001168),  # displaySetPowerMode
    (0xBAD2C, 0x34000768),  # displayCreateLayerWithCacheSize
    (0xC0934, 0x34000FE8),  # displaySetClientTargetWithSlot
    (0xBCF48, 0x340006E8),  # displayGetType
    (0xBB1C8, 0x34000868),  # displayGetActiveConfig
)

# When True, NOP every ldrb [*,#0x21] + cbz pair in HWCMediator display API range
# so present/validate/composition paths also skip "not connected".
NOP_ALL_CONNECTED_IN_MEDIATOR = True
MEDIATOR_CONN_RANGE = (0xB7000, 0xCB000)

# Patch-D: DrmModeConnector::checkProperty / DrmObject::checkProperty hard -22
CHECKPROP_SOFTFAIL = (
    (0x18E57C, MOVN_W23_M22, MOV_W23_WZR),  # connector: mov w23,#-22 → wzr
    (0x1917D0, MOVN_W0_M22, MOV_W0_WZR),  # plane/DrmObject: mov w0,#-22 → wzr
)

# Former Patch-E sites (keep stock setDamage).
SETDAMAGE_CALL = (
    (0xC09A4, 0xAA1403E1),  # mov x1, x20
    (0xC09A8, 0x94040E8E),  # bl setDamage@plt
)

# Patch-F: force setActiveConfig through mediator + HWCDisplay gates.
# Mediator: getNumConfigs() <= config_id → fail (@0xc0168)
# HWCDisplay: flag/count/same-config gates (see SET_ACTIVE_* below)
SET_ACTIVE_MEDIATOR_BLS = (0xC0168, 0x54000D09)  # b.ls fail after getNumConfigs
SET_ACTIVE_FLAG_CBZ = (0x13BE3C, 0x34000328)  # cbz w8, fail
SET_ACTIVE_COUNT_BLS = (0x13BE90, 0x54000089)  # b.ls fail
SET_ACTIVE_SAME_BNE = (0x13BE9C, 0x540003E1)  # b.ne update
# b 0x13bf18 from 0x13be9c: imm26 = 0x1f
B_TO_UPDATE = 0x1400001F

# Patch-G: empty userspace modes vec → force CRTC-known 1600x2560 config.
# DrmModeResource::getNumConfigs success: mul size → mov w0,#1
GET_NUM_CONFIGS_MUL = (0x186C2C, 0x1B097D00)  # mul w0, w8, w9
# DrmModeConnector::getModeWidth/Height empty/OOB: mov w0,wzr → constants
GET_MODE_WIDTH_ZERO = (0x18CEE0, MOV_W0_WZR)
GET_MODE_HEIGHT_ZERO = (0x18CF40, MOV_W0_WZR)
# DisplayManager::setDisplayDataForPhy: SessionInfo WH → DisplayData (two paths)
# Path A (enabled): ldr w8,[sp,#0x7c/#0x80] before str to DisplayData
SDDP_W_A = (0xE5E08, 0xB9407FE8)  # ldr w8, [sp, #0x7c]
SDDP_H_A = (0xE5E14, 0xB94083E8)  # ldr w8, [sp, #0x80]
# Path B (fallback getOverlaySessionInfo):
SDDP_W_B = (0xE5EEC, 0xB9407FE8)
SDDP_H_B = (0xE5EF8, 0xB94083E8)
# HWCDisplay::getWidth / getHeight — Attribute path reads DisplayData; force constants
# stock: stp x29,x30,[sp,#-0x20]!
HWC_GET_WIDTH = 0x1347A0
HWC_GET_HEIGHT = 0x1347E0
STP_X29_X30_M20 = 0xA9BE7BFD
# ret
RET = 0xD65F03C0

# Patch-H: ValidateDisplay thunk @0xaf120
# Stock truncates outTypes* (mov w3,w2) and loads method into x4 (clobbers outReqs*).
VALIDATE_THUNK = 0xAF120
VALIDATE_STOCK_MOV_W3_W2 = 0x2A0203E3
# Patched sequence (method ptr in x5 so x3/x4 stay outTypes*/outReqs*):
VALIDATE_PATCHED = (
    0xAA0303E4,  # mov x4, x3   // outReqs*
    0xAA0203E3,  # mov x3, x2   // outTypes*
    0xAA0103E2,  # mov x2, x1   // display
    0xAA0003E1,  # mov x1, x0   // device
    ADRP_X8_1D0000_AF120,
    LDR_X8_X8_F98,
    0xF9400108,  # ldr x8, [x8]       // this
    0xF9400109,  # ldr x9, [x8]       // vtable
    0xAA0803E0,  # mov x0, x8
    0xF9409D25,  # ldr x5, [x9, #0x138]
    0xD61F00A0,  # br x5
)
# HWCDisplay::validate: skip DisplayData+0x21 connected gate (else never sets +0xd0)
VALIDATE_CONNECTED_CBZ = (0x133B64, 0x34000988)  # cbz w8, not-connected
# Force isValidated / skip getChanged gate (validate path may not set +0xd0)
IS_VALIDATED = 0x139F80
IS_VALIDATED_STOCK = (0x39434000, RET)  # ldrb w0,[x0,#0xd0]; ret
GET_CHANGED_VALIDATED_TBZ = (0xBB578, 0x36000F80)  # tbz w0,#0, fail
# presentImpl: force PresentValiState=VALIDATE(3) and branch to beforePresent path.
# Stock: ldr w8,[x23,#0x3a8]; cmp #5; b.eq err7; cmp #3; b.eq be324
# Must replace b.eq-err7 too — leftover Z from type==4 scan falsely returns NOT_VALIDATED.
PRESENT_VALI_LDR = (0xBDDEC, 0xB943AAE8)  # ldr w8,[x23,#0x3a8]
PRESENT_VALI_CMP5 = (0xBDDF0, 0x7100151F)  # cmp w8,#5
PRESENT_VALI_BEQ5 = (0xBDDF4, 0x54004BE0)  # b.eq be770
PRESENT_VALI_CMP3 = (0xBDDF8, 0x71000D1F)  # cmp w8,#3
PRESENT_VALI_BEQ3 = (0xBDDFC, 0x54002940)  # b.eq be324
MOV_W8_3 = 0x52800068  # mov w8,#3
STR_W8_X23_3A8 = 0xB903AAE8  # str w8,[x23,#0x3a8]
# b be324 from 0xbddf4: imm26 = (0xbe324-0xbddf4)/4 = 0x14c
B_BDDF4_TO_BE324 = 0x1400014C
# be324 re-check state!=3 → fence-only bypass; NOP so createFb path runs
PRESENT_STATE_BNE = (0xBE338, 0x54001421)  # b.ne be5bc
# DisplayData+0x21 may be 0 → isConnected false → present fence-only @be5bc
IS_CONNECTED = 0x1343B0
PRESENT_ISCONN_TBZ = (0xBE400, 0x36000DE0)  # tbz w0,#0, be5bc
# onPlugIn: "already connected" skips +0x170 enable → setJob no-ops
ONPLUGIN_ALREADY_TBZ = (0xD8C1C, 0x360002C8)  # tbz w8,#0, d8c74
# b d8c74 from d8c1c: imm26 = 0x16
B_D8C1C_TO_D8C74 = 0x14000016
# AbortMessager::abort — flushOut then abort@plt; replace with ret for Lomiri.
ABORT_MESSAGER_ABORT = 0x19E550
ABORT_MESSAGER_ABORT_STOCK0 = 0xA9BF7BFD  # stp x29,x30,[sp,#-0x10]!


def u32(data: bytearray, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def put_u32(data: bytearray, off: int, val: int) -> None:
    struct.pack_into("<I", data, off, val)


def put_u16(data: bytearray, off: int, val: int) -> None:
    struct.pack_into("<H", data, off, val)


def expect(data: bytearray, off: int, want: int, label: str) -> None:
    got = u32(data, off)
    if got != want:
        raise SystemExit(f"{label}: expected {want:#010x} at {off:#x}, got {got:#010x}")


def patch_create_layer_thunk(data: bytearray) -> None:
    """Rewrite 0xae850 for HWC2 createLayer(device, display, outLayer).

    Stock thunk expects (device, display, cacheSize, outLayer).
    New:
      mov x4, x2 ; mov x2, x1 ; mov x1, x0 ; mov w3, #1
      adrp/ldr singleton ; ldr this ; ldr vtable ; ldr [vt,#0x70] ; br
    """
    off = 0xAE850
    # Sanity: stock starts with adrp x8
    expect(data, off, ADRP_X8_1D0000, "ae850 adrp")
    words = [
        0xAA0203E4,  # mov x4, x2   // outLayer
        0xAA0103E2,  # mov x2, x1   // display
        0xAA0003E1,  # mov x1, x0   // device
        0x52800023,  # mov w3, #1   // cacheSize
        ADRP_X8_1D0000,
        LDR_X8_X8_F98,
        0xF9400108,  # ldr x8, [x8]
        0xF9400109,  # ldr x9, [x8]
        0xAA0803E0,  # mov x0, x8
        0xF9403925,  # ldr x5, [x9, #0x70]
        0xD61F00A0,  # br x5
        NOP,         # pad former trailing insn
    ]
    for i, w in enumerate(words):
        put_u32(data, off + i * 4, w)


def patch_set_client_target_thunk(data: bytearray) -> None:
    """Rewrite 0xaed30 as HWC2 setClientTarget → WithSlot(slot=0, flag=0).

    HWC2: (device, display, handle, fence, dataspace, damage)
    Method: (this, device, display, slot, bool, handle, fence, dataspace, vec*)

    Pass libc++ vector with one full-screen Rect {0,0,1600,2560} so setDamage
    marks the client target dirty (empty vec skipped FB commit).
    """
    off = 0xAED30
    got = u32(data, off)
    if got not in (0xD10083FF, 0xD10103FF, 0xD10143FF):  # #0x20/#0x40/#0x50
        raise SystemExit(f"aed30 sub sp unexpected: {got:#010x}")
    words = [
        0xD10143FF,  # sub sp, sp, #0x50
        0xA9047BFD,  # stp x29, x30, [sp, #0x40]
        0x910103FD,  # add x29, sp, #0x40
        0xD0000909,  # adrp x9, 0x1d0000
        0xF947CD29,  # ldr x9, [x9, #0xf98]
        0xAA0203E5,  # mov x5, x2   // handle
        0x2A0303E6,  # mov w6, w3   // fence
        0x2A0403E7,  # mov w7, w4   // dataspace
        0xAA0103E2,  # mov x2, x1   // display
        0xAA0003E1,  # mov x1, x0   // device
        0x52800003,  # mov w3, #0   // slot
        0x52800004,  # mov w4, #0   // bool
        0xF9400120,  # ldr x0, [x9] // this
        0xF9400009,  # ldr x9, [x0]
        0xF9408929,  # ldr x9, [x9, #0x110]
        0xAA0903EB,  # mov x11, x9              // keep method ptr
        # Rect at sp+0x20: left=0,top=0,right=1600,bottom=2560
        0xA9027FFF,  # stp xzr, xzr, [sp, #0x20]  // left,top = 0
        0x5280C808,  # mov w8, #0x640             // 1600
        0x52814009,  # mov w9, #0xa00             // 2560
        0xA90327E8,  # stp w8, w9, [sp, #0x28]    // right, bottom
        0x910083E8,  # add x8, sp, #0x20          // begin = &rect
        0x9100C3EA,  # add x10, sp, #0x30         // end = &rect+16
        0xA900A3E8,  # stp x8, x10, [sp, #0x8]    // vector begin/end
        0xF9000FEA,  # str x10, [sp, #0x18]       // capacity
        0x910023E8,  # add x8, sp, #0x8
        0xF90003E8,  # str x8, [sp]               // 9th arg = &vec
        0xD63F0160,  # blr x11
        0xA9447BFD,  # ldp x29, x30, [sp, #0x40]
        0x910143FF,  # add sp, sp, #0x50
        0xD65F03C0,  # ret
    ]
    for i, w in enumerate(words):
        put_u32(data, off + i * 4, w)


def apply(data: bytearray) -> None:
    # --- Patch-A: jump tables ---
    got = struct.unpack_from("<H", data, JT_CREATE_LAYER)[0]
    if got not in (4, HALF_CREATE):
        raise SystemExit(f"CREATE_LAYER half unexpected: {got}")
    put_u16(data, JT_CREATE_LAYER, HALF_CREATE)

    got = struct.unpack_from("<H", data, JT_SET_CLIENT_TARGET)[0]
    if got not in (4, HALF_SET_CT):
        raise SystemExit(f"SET_CLIENT_TARGET half unexpected: {got}")
    put_u16(data, JT_SET_CLIENT_TARGET, HALF_SET_CT)

    patch_create_layer_thunk(data)
    patch_set_client_target_thunk(data)

    # --- Patch-B: connected bypass ---
    for off, want in CONNECTED_CBZ:
        got = u32(data, off)
        if got not in (want, NOP):
            raise SystemExit(f"connected cbz @{off:#x}: expected {want:#010x}, got {got:#010x}")
        put_u32(data, off, NOP)

    if NOP_ALL_CONNECTED_IN_MEDIATOR:
        lo, hi = MEDIATOR_CONN_RANGE
        n = 0
        for off in range(lo, hi, 4):
            w = u32(data, off)
            if (w & 0xFFC00000) != 0x39400000:
                continue
            if ((w >> 10) & 0xFFF) != 0x21:
                continue
            rt = w & 0x1F
            for delta in (4, 8):
                cbz_off = off + delta
                if cbz_off >= hi:
                    break
                w2 = u32(data, cbz_off)
                if (w2 & 0xFF00001F) == (0x34000000 | rt):
                    put_u32(data, cbz_off, NOP)
                    n += 1
                    break
        print(f"connected_bypass_mediator_nops={n}")

    # --- Patch-D: checkProperty soft-fail (-22 → 0) ---
    for off, want, repl in CHECKPROP_SOFTFAIL:
        got = u32(data, off)
        if got not in (want, repl):
            raise SystemExit(
                f"checkProperty soft-fail @{off:#x}: expected {want:#010x} or "
                f"{repl:#010x}, got {got:#010x}"
            )
        put_u32(data, off, repl)
    print("checkProperty_softfail=ok")

    # --- Restore setDamage (undo prior Patch-E NOPs if present) ---
    for off, want in SETDAMAGE_CALL:
        got = u32(data, off)
        if got not in (want, NOP):
            raise SystemExit(
                f"setDamage restore @{off:#x}: expected {want:#010x} or NOP, got {got:#010x}"
            )
        put_u32(data, off, want)
    print("setDamage_restored=ok")

    # --- Patch-F: force setActiveConfig → updateActiveConfig ---
    off, want = SET_ACTIVE_MEDIATOR_BLS
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"setActive mediator bls @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    off, want = SET_ACTIVE_FLAG_CBZ
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"setActive flag cbz @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    off, want = SET_ACTIVE_COUNT_BLS
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"setActive count bls @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    off, want = SET_ACTIVE_SAME_BNE
    got = u32(data, off)
    if got not in (want, B_TO_UPDATE):
        raise SystemExit(f"setActive same bne @{off:#x}: {got:#010x}")
    put_u32(data, off, B_TO_UPDATE)
    print("setActiveConfig_force_update=ok")

    # --- Patch-G: force config count / WIDTH / HEIGHT from CRTC mode ---
    off, want = GET_NUM_CONFIGS_MUL
    got = u32(data, off)
    if got not in (want, MOV_W0_1):
        raise SystemExit(f"getNumConfigs mul @{off:#x}: {got:#010x}")
    put_u32(data, off, MOV_W0_1)
    off, want = GET_MODE_WIDTH_ZERO
    got = u32(data, off)
    if got not in (want, MOV_W0_1600):
        raise SystemExit(f"getModeWidth zero @{off:#x}: {got:#010x}")
    put_u32(data, off, MOV_W0_1600)
    off, want = GET_MODE_HEIGHT_ZERO
    got = u32(data, off)
    if got not in (want, MOV_W0_2560):
        raise SystemExit(f"getModeHeight zero @{off:#x}: {got:#010x}")
    put_u32(data, off, MOV_W0_2560)

    for off, want, repl, label in (
        (SDDP_W_A[0], SDDP_W_A[1], MOV_W0_1600, "sddp_w_a"),
        (SDDP_H_A[0], SDDP_H_A[1], MOV_W0_2560, "sddp_h_a"),
        (SDDP_W_B[0], SDDP_W_B[1], MOV_W0_1600, "sddp_w_b"),
        (SDDP_H_B[0], SDDP_H_B[1], MOV_W0_2560, "sddp_h_b"),
    ):
        # Force WH into w8 (same Rd as stock ldr w8, ...)
        # mov w8, #imm: 0x52800000 | (imm<<5) | 8
        imm = 0x640 if repl == MOV_W0_1600 else 0xA00
        mov_w8 = 0x52800000 | (imm << 5) | 8
        got = u32(data, off)
        if got not in (want, mov_w8):
            raise SystemExit(f"{label} @{off:#x}: {got:#010x}")
        put_u32(data, off, mov_w8)

    # HWCDisplay::getWidth / getHeight → constant return (Attribute path)
    for off, imm, label in (
        (HWC_GET_WIDTH, 0x640, "getWidth"),
        (HWC_GET_HEIGHT, 0xA00, "getHeight"),
    ):
        mov_w0 = 0x52800000 | (imm << 5)
        got0 = u32(data, off)
        got1 = u32(data, off + 4)
        if got0 not in (STP_X29_X30_M20, mov_w0):
            raise SystemExit(f"{label} @{off:#x}: unexpected {got0:#010x}")
        if got0 == mov_w0 and got1 == RET:
            continue
        put_u32(data, off, mov_w0)
        put_u32(data, off + 4, RET)
    print("crtc_config_force_1600x2560=ok")

    # --- Patch-H: ValidateDisplay thunk ABI (outTypes*/outReqs*) ---
    off = VALIDATE_THUNK
    stock0 = u32(data, off)
    stock_mov = u32(data, off + 8)
    already = u32(data, off) == VALIDATE_PATCHED[0] and u32(data, off + 4) == VALIDATE_PATCHED[1]
    if not already:
        # Stock starts with adrp; 3rd word is mov w3,w2
        if stock0 not in (ADRP_X8_1D0000_AF120, VALIDATE_PATCHED[0]):
            raise SystemExit(f"validate thunk adrp @{off:#x}: {stock0:#010x}")
        if stock_mov not in (VALIDATE_STOCK_MOV_W3_W2, VALIDATE_PATCHED[2]):
            raise SystemExit(f"validate thunk mov @{off + 8:#x}: {stock_mov:#010x}")
        for i, w in enumerate(VALIDATE_PATCHED):
            put_u32(data, off + i * 4, w)
    off, want = VALIDATE_CONNECTED_CBZ
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"HWCDisplay::validate connected cbz @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    # Always report validated so getChanged can run after client-target present.
    got0 = u32(data, IS_VALIDATED)
    got1 = u32(data, IS_VALIDATED + 4)
    if got0 not in (IS_VALIDATED_STOCK[0], MOV_W0_1):
        raise SystemExit(f"isValidated @{IS_VALIDATED:#x}: {got0:#010x}")
    put_u32(data, IS_VALIDATED, MOV_W0_1)
    put_u32(data, IS_VALIDATED + 4, RET)
    off, want = GET_CHANGED_VALIDATED_TBZ
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"getChanged validated tbz @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    # Force PresentValiState=3 and jump to be324 (no stale b.eq on Z from type scan)
    off, want = PRESENT_VALI_LDR
    got = u32(data, off)
    if got not in (want, MOV_W8_3):
        raise SystemExit(f"present PresentVali ldr @{off:#x}: {got:#010x}")
    seq = (
        (PRESENT_VALI_LDR[0], MOV_W8_3, PRESENT_VALI_LDR[1]),
        (PRESENT_VALI_CMP5[0], STR_W8_X23_3A8, PRESENT_VALI_CMP5[1]),
        (PRESENT_VALI_BEQ5[0], B_BDDF4_TO_BE324, PRESENT_VALI_BEQ5[1]),
        (PRESENT_VALI_CMP3[0], NOP, PRESENT_VALI_CMP3[1]),
        (PRESENT_VALI_BEQ3[0], NOP, PRESENT_VALI_BEQ3[1]),
    )
    for off, repl, stock in seq:
        got = u32(data, off)
        if got not in (stock, repl, NOP, MOV_W8_3, STR_W8_X23_3A8, B_BDDF4_TO_BE324):
            raise SystemExit(f"present PresentVali @{off:#x}: {got:#010x}")
        put_u32(data, off, repl)
    off, want = PRESENT_STATE_BNE
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"present state bne @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    # isConnected always true (else present skips createFb)
    got0 = u32(data, IS_CONNECTED)
    if got0 not in (STP_X29_X30_M20, MOV_W0_1):
        raise SystemExit(f"isConnected @{IS_CONNECTED:#x}: {got0:#010x}")
    put_u32(data, IS_CONNECTED, MOV_W0_1)
    put_u32(data, IS_CONNECTED + 4, RET)
    off, want = PRESENT_ISCONN_TBZ
    got = u32(data, off)
    if got not in (want, NOP):
        raise SystemExit(f"present isConnected tbz @{off:#x}: {got:#010x}")
    put_u32(data, off, NOP)
    # Force onPlugIn past "already connected" so +0x170 enable runs
    off, want = ONPLUGIN_ALREADY_TBZ
    got = u32(data, off)
    if got not in (want, B_D8C1C_TO_D8C74):
        raise SystemExit(f"onPlugIn already tbz @{off:#x}: {got:#010x}")
    put_u32(data, off, B_D8C1C_TO_D8C74)
    # Patch-H3: AbortMessager::abort → ret (keep OverlayEngine / Lomiri alive)
    got0 = u32(data, ABORT_MESSAGER_ABORT)
    if got0 not in (ABORT_MESSAGER_ABORT_STOCK0, RET):
        raise SystemExit(f"AbortMessager::abort @{ABORT_MESSAGER_ABORT:#x}: {got0:#010x}")
    put_u32(data, ABORT_MESSAGER_ABORT, RET)
    print("validate_thunk_abi=ok abort_messager_ret=ok")


def main() -> int:
    if not IN_PATH.is_file():
        print(f"missing input: {IN_PATH}", file=sys.stderr)
        return 1
    data = bytearray(IN_PATH.read_bytes())
    apply(data)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_bytes(data)
    md5 = hashlib.md5(data).hexdigest()
    print(f"wrote {OUT_PATH}")
    print(f"size={len(data)} md5={md5}")
    # Quick verify
    assert struct.unpack_from("<H", data, JT_CREATE_LAYER)[0] == HALF_CREATE
    assert struct.unpack_from("<H", data, JT_SET_CLIENT_TARGET)[0] == HALF_SET_CT
    for off, _ in CONNECTED_CBZ:
        assert u32(data, off) == NOP
    assert u32(data, 0xAE850) == 0xAA0203E4
    assert u32(data, 0xAED30) == 0xD10143FF  # frame for full-screen damage vec
    for off, _, repl in CHECKPROP_SOFTFAIL:
        assert u32(data, off) == repl
    for off, want in SETDAMAGE_CALL:
        assert u32(data, off) == want
    assert u32(data, SET_ACTIVE_MEDIATOR_BLS[0]) == NOP
    assert u32(data, SET_ACTIVE_FLAG_CBZ[0]) == NOP
    assert u32(data, SET_ACTIVE_COUNT_BLS[0]) == NOP
    assert u32(data, SET_ACTIVE_SAME_BNE[0]) == B_TO_UPDATE
    assert u32(data, GET_NUM_CONFIGS_MUL[0]) == MOV_W0_1
    assert u32(data, GET_MODE_WIDTH_ZERO[0]) == MOV_W0_1600
    assert u32(data, GET_MODE_HEIGHT_ZERO[0]) == MOV_W0_2560
    assert u32(data, SDDP_W_A[0]) == (0x52800000 | (0x640 << 5) | 8)
    assert u32(data, SDDP_H_A[0]) == (0x52800000 | (0xA00 << 5) | 8)
    assert u32(data, SDDP_W_B[0]) == (0x52800000 | (0x640 << 5) | 8)
    assert u32(data, SDDP_H_B[0]) == (0x52800000 | (0xA00 << 5) | 8)
    assert u32(data, HWC_GET_WIDTH) == MOV_W0_1600
    assert u32(data, HWC_GET_WIDTH + 4) == RET
    assert u32(data, HWC_GET_HEIGHT) == MOV_W0_2560
    assert u32(data, HWC_GET_HEIGHT + 4) == RET
    for i, w in enumerate(VALIDATE_PATCHED):
        assert u32(data, VALIDATE_THUNK + i * 4) == w
    assert u32(data, VALIDATE_CONNECTED_CBZ[0]) == NOP
    assert u32(data, IS_VALIDATED) == MOV_W0_1
    assert u32(data, IS_VALIDATED + 4) == RET
    assert u32(data, GET_CHANGED_VALIDATED_TBZ[0]) == NOP
    assert u32(data, PRESENT_VALI_LDR[0]) == MOV_W8_3
    assert u32(data, PRESENT_VALI_CMP5[0]) == STR_W8_X23_3A8
    assert u32(data, PRESENT_VALI_BEQ5[0]) == B_BDDF4_TO_BE324
    assert u32(data, PRESENT_VALI_CMP3[0]) == NOP
    assert u32(data, PRESENT_VALI_BEQ3[0]) == NOP
    assert u32(data, PRESENT_STATE_BNE[0]) == NOP
    assert u32(data, IS_CONNECTED) == MOV_W0_1
    assert u32(data, IS_CONNECTED + 4) == RET
    assert u32(data, PRESENT_ISCONN_TBZ[0]) == NOP
    assert u32(data, ONPLUGIN_ALREADY_TBZ[0]) == B_D8C1C_TO_D8C74
    assert u32(data, ABORT_MESSAGER_ABORT) == RET
    print("verify=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


