# Lower-layer display verification (DRM/KMS vs HWC)

## Recommendation (2-D)

| Candidate | Role |
|-----------|------|
| **DRM/KMS + Mesa GBM** (Mir without android2) | Primary experiment — true layer below HWC |
| fbdev | Diagnostics only |
| Current HWC + libhybris | **Production default** |

## Latest automated verdict

- **Stamp:** `20260827T113631Z`
- **Verdict:** **CONDITIONAL**
- **Artifact:** `builder/out/lower-layer-display/verify_latest.md`

Regenerate:

```bash
bash scripts/verify_lower_layer_display.sh
# optional: also build prop dump
# bash scripts/diag_mtk_drm.sh
```

## Dual system.img build + flash trial (2026-08-27)

| Artifact | Path |
|----------|------|
| 通常版 (HWC) | `builder/out/android-16.0_system.img` |
| 低レイヤ版 | `builder/out/android-16.0_system_lower-layer.img` |
| Build method | `builder/out/dual_system_build_method.txt` → `debugfs-fallback`（sudo 無し時） |

フラッシュ: 低レイヤ版のみ `fastboot flash system`（`--system-only` 相当）。userdata 未フラッシュ。

### Post-flash evidence

| Check | Result |
|-------|--------|
| `/system/etc/ubuntu-gsi/display-mode` | `lower-layer` |
| `verify_lower_layer_display.sh` | **CONDITIONAL**（DRM card0 + connector present） |
| `run_chroot_lomiri.sh` log | `DISPLAY_MODE=lower-layer` / `GPU_MODE=llvmpipe` |
| Mir android2 | 無効化成功（`file too short` / bind stub） |
| Mir selected driver | `mir:android`（legacy）— GBM/llvmpipe 未採用 |
| `pidof lomiri` | **none**（起動直後に終了; egl_warmup segfault） |
| 画面 present | **未達成** |

**Compositor 判定: NO-GO**（android2 無効は焼き込み動作確認済み。DRM 単独 present / Lomiri 生存は未達）。本番既定は通常版 HWC のまま。復旧は `android-16.0_system.img` を `--system-only` で再フラッシュ。

証拠ログ: `builder/out/lower-layer-lomiri-run2.log`, `builder/out/start-lomiri.host.log`, `builder/out/flash_lower_layer.log`

## Procedure

1. Confirm `/dev/dri/card*` and connected connector under `/sys/class/drm`.
2. Run `drm_prop_dump` (via `diag_mtk_drm.sh`) for connector/crtc/plane props.
3. Keep SurfaceFlinger stopped (Halium hand-off). Do **not** unbind NVT or rebind HWC carelessly.
4. Optional experiment: `VERIFY_LOWER_LAYER_TRY_MIR=1` creates
   `/data/local/tmp/lomiri_disable_android2` (start-lomiri / device_prep honour this when wired).
5. Production path remains Mir android2 → libhybris → vendor HWC until verdict is **GO**
   with a successful exclusive modeset/present.

## Go criteria

- Exclusive DRM master obtainable without vendor HWC process
- Atomic modeset + frame present without HWC
- Mir (or a Mesa GBM test client) displays a frame for ≥30s without crash
- Touch/input still works under the same session

## Current project default

**Do not switch** `start-lomiri.sh` off HWC based on CONDITIONAL results.
