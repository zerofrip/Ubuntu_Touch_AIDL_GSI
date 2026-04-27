# Ubuntu Touch AIDL GSI (Halium-style)

[![Build](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/build.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/build.yml)
[![Lint](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/lint.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Ubuntu Touch for Treble devices with **AIDL-era vendor stacks** (Android 12+), redesigned to keep stock boot components untouched.

## Design Goals

- Keep **stock `boot.img`** untouched.
- Keep **stock kernel** untouched.
- Flash only:
  - `system.img`
  - `vbmeta-disabled.img`
- Do not flash `boot`, `vendor_boot`, `dtbo`, `vendor`, or `userdata`.

## Current Architecture (Halium-style)

Android boots normally, then launches Ubuntu userspace late in boot:

1. Stock bootloader + stock kernel + stock ramdisk init (PID 1)
2. PHH-based `/system` boots Android framework + vendor HAL services
3. `/system/etc/init/ubuntu-gsi.rc` starts `ubuntu-gsi-launcher`
4. Launcher mounts `rootfs.erofs`, builds overlay on `/data/uhl_overlay`, then `chroot`s into Ubuntu systemd
5. Lomiri/Mir starts from inside the Ubuntu chroot

Authoritative design doc: `docs/halium-architecture.md`

## Repository Roles

- `halium/`
  - `etc/init/ubuntu-gsi.rc` Android init service definitions
  - `bin/ubuntu-gsi-launcher` chroot pivot driver
  - `bin/ubuntu-gsi-stop-android-ui` SurfaceFlinger hand-off helper
  - `compat/` PHH/TrebleDroid-style compatibility engine
  - `lomiri/start-lomiri.sh` Lomiri/libhybris startup scaffold
- `scripts/`
  - `fetch_phh_gsi.sh` PHH base download/prepare
  - `build_rootfs.sh` Ubuntu chroot rootfs build
  - `build_rootfs_erofs.sh` rootfs -> erofs pack
  - `build_vbmeta_disabled.sh` disabled vbmeta build
  - `build_system_img.sh` PHH base + Halium overlay merge
  - `flash.sh` flashes `system + vbmeta` only
- `deprecated/`
  - legacy pre-Halium components kept for reference

## Build Prerequisites

```bash
sudo apt install \
  debootstrap qemu-user-static e2fsprogs erofs-utils jq wget unzip \
  android-sdk-libsparse-utils android-tools-fastboot python3
```

`avbtool` is recommended for production `vbmeta-disabled.img` generation.

## Build

```bash
git clone --recursive https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI.git
cd Ubuntu_Touch_AIDL_GSI

make build
```

Pipeline:

- PHH fetch -> rootfs build -> erofs pack -> vbmeta-disabled -> system image compose

Artifacts are generated under `builder/out/`:

- `system.img`
- `linux_rootfs.erofs`
- `vbmeta-disabled.img`

## Flash

```bash
make flash
```

or manually:

```bash
fastboot --disable-verity --disable-verification flash vbmeta builder/out/vbmeta-disabled.img
fastboot flash system builder/out/system.img
fastboot reboot
```

Selective flash:

```bash
make flash-system
make flash-vbmeta
```

## Runtime Control

Enable Ubuntu launcher (default is auto-on from init rules):

```bash
adb shell setprop persist.ubuntu_gsi.enable 1
```

Disable launcher and boot Android-only userspace:

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

## Compatibility Engine

The compatibility layer is inspired by:

- [phhusson/device_phh_treble](https://github.com/phhusson/device_phh_treble)
- [phhusson/vendor_hardware_overlay](https://github.com/phhusson/vendor_hardware_overlay)
- [TrebleDroid/treble_app](https://github.com/TrebleDroid/treble_app)

Main files:

- `halium/compat/quirks.json`
- `halium/compat/compat-engine.sh`
- `halium/compat/prop-handler.sh`
- `halium/compat/lib/detect-platform.sh`

Engine supports mode-aware execution (`android`, `linux`, `both`) for per-action filtering.

## AIDL Variant Defaults

`config.env` defaults:

- `PHH_GSI_VERSION=v559`
- `PHH_GSI_VARIANT=arm64-ab-vanilla`

Override in `config.env` or via environment variables if your target requires a different base.


Quick reference flash guide: `docs/flash_quickstart.md`

## Notes

- Legacy docs/scripts that mention `linux_rootfs.squashfs`, `userdata.img` pivot, or binder bridge daemons are historical and replaced by the Halium-style flow.
- See `docs/halium-architecture.md` for current behavior.
