# HAL bridge matrix (Ubuntu Touch AIDL GSI)

Authoritative live snapshot: regenerate with

```bash
bash scripts/diag_vendor_hal_inventory.sh
# → builder/out/hal-inventory/inventory_latest.md
```

On device (every Lomiri start / `ubuntu-gsi-hal-bringup.service`):

```bash
/usr/lib/ubuntu-gsi/hal-capability-router.sh
# → /run/ubuntu-gsi/hal-inventory.json
# → /run/ubuntu-gsi/hal-status/<subsystem>   (path= + status=)
```

This document is the **annotated** matrix. Status values match the inventory
script: `bridged` | `kernel_only` | `pkg_only` | `missing_linux` | `missing`.

Architecture contract: [halium-architecture.md](halium-architecture.md)
(stock boot/kernel/vendor, Android PID1, binderfs bind, libhybris; no custom
binder-bridge daemon).

## Design goals

- **Flash-only portability**: conversion logic ships in `system.img` overlay and
  discovers `/vendor/lib*/hw`, VINTF, and kernel nodes at runtime. No SoC name
  hardcoding in the HAL router (e.g. no fixed `mt6897` path).
- **Low latency / low power**: prefer kernel + event-driven Linux daemons over
  Binder AIDL round-trips. AIDL is **probed once** at boot; no polling bridges
  (`deprecated/aidl/` stays retired). GPU heavy prep (SF/composer reclaim,
  optional HWC patch, `egl_warmup`) runs **lazily** at Lomiri start via
  `hal-gpu-bringup.sh lomiri_prep`, not at every boot.

## Path priority

| Priority | Path | Cost | Examples |
|----------|------|------|----------|
| 1 | Kernel direct | Lowest | evdev, ALSA, IIO, backlight, V4L2, rfkill |
| 2 | Linux daemon (lazy start) | Low | Pulse, BlueZ, iio-sensor-proxy, ofono, NM |
| 3 | AIDL probe once | No conversion | `hal-aidl-probe.sh` |
| — | Forbidden | High | Polling shell AIDL bridges |

## Production path (display)

```
Lomiri → Mir android2 → libhybris HWC/EGL → vendor hwcomposer → kernel DRM
```

Compat stubs (`libui_compat_layer.so`, `libhwc2_compat_layer.so`, `egl_warmup`)
ship under `/usr/lib/ubuntu-gsi/halium-compat/` inside `system.img` (fallback:
`/data/local/tmp/halium13-compat`). HWC `.so` selection is by `hwcomposer.*.so`
glob; optional inproc/patched bind if present in compat dir.

Lower-layer DRM/GBM experiment: [lower-layer-display.md](lower-layer-display.md).

## Boot pipeline

```
hal-enumerate.sh → hal-capability-router.sh
                 → HAL_ENABLE_GPU=1 → hal-gpu-bringup.sh chmod_only
                 → hal-kernel-bringup.sh (selective + lazy daemons)
                 → wifi-bringup.sh (if INV_wifi)
                 → hal-aidl-probe.sh (once)

start-lomiri.sh  → router (if not already)
                 → hal-gpu-bringup.sh lomiri_prep   # SF/HWC reclaim (once)
                 → hybris env + egl_warmup → exec lomiri
```

## Subsystem matrix (runtime discovery)

| Subsystem | Intended Linux path | Router `path=` |
|-----------|---------------------|----------------|
| display_gpu | Mir android2 + libhybris (lazy lomiri_prep) | `hybris` |
| input | `/dev/input` + udev + Mir evdev | `kernel` |
| wifi | rfkill + netdev (+ optional vendor power node) | `kernel` |
| power | sysfs backlight + power_supply | `kernel` |
| audio | ALSA + Pulse (lazy) | `linux_daemon` / `kernel` |
| bluetooth | BlueZ (lazy) | `linux_daemon` / `kernel` |
| sensors | IIO + iio-sensor-proxy (lazy) | `linux_daemon` / `kernel` / `aidl_unavailable` |
| camera | V4L2 + libcamera | `linux_daemon` / `kernel` / `aidl_unavailable` |
| gnss | device nodes | `kernel` / `aidl_unavailable` |
| telephony | modem nodes + ofono (lazy) | `linux_daemon` / `kernel` / `aidl_unavailable` |
| fingerprint | device nodes | `kernel` / `aidl_unavailable` |
| vibrator | timed_output / leds sysfs | `kernel` |

## Runtime status directory

```
/run/ubuntu-gsi/hal-inventory.json
/run/ubuntu-gsi/hal-inventory.env
/run/ubuntu-gsi/hal-status/<subsystem>      # path= / status= from router
/run/ubuntu-gsi/hal-status/<id>_kern        # bringup detail
/run/ubuntu-gsi/hal-status/aidl_<subsystem> # one-shot probe
```

## Phase 2 (explicitly deferred)

Thin AIDL clients only when kernel path is absent on a device class. Priority
if revisited: audio → sensors → gnss → telephony → camera. Do not revive
`deprecated/aidl/` as system services.

## Example snapshot (historical; not normative)

F8 / MT6897 from `inventory_20260827T110020Z` was an example profile. **Source of
truth is the on-device inventory from the current boot**, not this table.
