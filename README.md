# Ubuntu Touch AIDL GSI (Halium-style)

[![Build](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/build.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/build.yml)
[![Lint](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/lint.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Ubuntu Touch for Treble devices with **AIDL-era vendor stacks** (Android 12+), redesigned to keep stock boot components untouched.

Build and release images from **vendor-version branches** (`android-12.0` … `android-16.0`). The `main` branch is documentation-only.

## Vendor Branch Strategy

| Branch | Target vendor Android | TrebleDroid release | PHH variant |
|--------|----------------------|---------------------|-------------|
| `android-12.0` | 12 | `v416` (phhusson) | `squeak-arm64-ab-vanilla` |
| `android-13.0` | 13 | `ci-20230905` | `td-arm64-ab-vanilla` |
| `android-14.0` | 14 | `ci-20240508` | `td-arm64-ab-vanilla` |
| `android-15.0` | 15 | `ci-20250415` | `td-arm64-ab-vanilla` |
| `android-16.0` | 16 | `ci-20250617` | `td-arm64-vanilla` |

For **HEADWOLF F8** (MT6897), try **`android-15.0`** first if the device was upgraded from Android 15→16 and Android 16 GSI bootloops. Use **`android-16.0`** when vendor/GSI major versions match cleanly.

TrebleDroid references: [treble_experimentations releases](https://github.com/TrebleDroid/treble_experimentations/releases), [device_phh_treble](https://github.com/TrebleDroid/device_phh_treble).

## Design Goals

- Keep **stock `boot.img`** untouched.
- Keep **stock kernel** untouched.
- Flash only:
  - `android-XX_system.img` (versioned system image)
  - `vbmeta-disabled.img`
  - `userdata.img` (seeds `/data/ubuntu-gsi/rootfs.erofs`)
- Do not flash `boot`, `vendor_boot`, `dtbo`, or `vendor`.

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
git checkout android-16.0   # pick branch matching your vendor Android version

make build-minimal
```

Pipeline:

- device_phh sync -> PHH fetch -> rootfs build -> erofs pack -> vbmeta-disabled -> system image compose -> userdata -> release packaging

Release artifacts under `builder/out/`:

- `android-XX_system.img` (e.g. `android-16.0_system.img`)
- `userdata.img`
- `vbmeta-disabled.img`
- `linux_rootfs.erofs` (intermediate)

`main` does not build release images. Checkout an `android-*` branch first.

## Flash

```bash
make flash
```

or manually:

```bash
fastboot flash vbmeta_a builder/out/vbmeta-disabled.img
fastboot flash vbmeta_system_a builder/out/vbmeta-disabled.img
fastboot flash vbmeta_vendor_a builder/out/vbmeta-disabled.img
fastboot reboot fastboot
fastboot flash system_a builder/out/android-16.0_system.img
fastboot flash userdata builder/out/userdata.img
fastboot reboot
```

Do **not** pass `--disable-verity` / `--disable-verification` to fastboot when flashing
standalone `vbmeta*.img` files. On fastboot 34+, that flag path fails with
`Failed to find AVB_MAGIC at offset: 0`. Verity is disabled by baking `flags=3`
into `vbmeta-disabled.img` at build time.

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

Per-branch settings live in `vendor/android-XX.Y.env` and are loaded automatically from the git branch name (or `VENDOR_ANDROID_VERSION`).

Example (`vendor/android-16.0.env`):

- `PHH_GSI_REPO=TrebleDroid/treble_experimentations`
- `PHH_GSI_VERSION=ci-20250617`
- `PHH_GSI_VARIANT=td-arm64-vanilla`
- `RELEASE_SYSTEM_IMG=android-16.0_system.img`

Supported PHH variants: `arm64-ab*`, `td-arm64-ab-vanilla`, and `td-arm64-vanilla` (Android 16).

Override in `vendor/*.env` or via environment variables if your target requires a different base.

Local source build mode:

- Set `PHH_GSI_SOURCE=custom`
- Set `TREBLE_EXP_PATH` to your local `treble_experimentations` checkout
- Optionally set `PHH_CUSTOM_TARGET` and `PHH_CUSTOM_VARIANT`
- Run `make phh-custom` (or `make build`)

Smaller preset shortcut:

- `make phh-custom-minimal`
- Equivalent to `PHH_CUSTOM_TARGET=android-15.0` + `PHH_CUSTOM_VARIANT=td-arm64-ab-vanilla`

Ultra-light rootfs preset:

- `make build-minimal`
- Uses `GSI_ROOTFS_PROFILE=minimal` and `rootfs/packages.minimal.list`
- Also applies aggressive rootfs pruning by default in minimal mode

Rootfs persistence/self-heal:

- Launcher keeps runtime rootfs in `/data/ubuntu-gsi/rootfs.erofs`
- Backup copy is kept at `/data/ubuntu-gsi/rootfs.erofs.bak`
- SHA-256 is verified at boot; missing/corrupt data copy is auto-restored
- Restore source is system seed `/system/usr/share/ubuntu-gsi/rootfs.erofs`
- `ROOTFS_SEED_IN_SYSTEM=0` keeps `system.img` smaller, but removes reset-time seed restore


Quick reference flash guide: `docs/flash_quickstart.md`

## Notes

- Legacy docs/scripts that mention `linux_rootfs.squashfs`, `userdata.img` pivot, or binder bridge daemons are historical and replaced by the Halium-style flow.
- See `docs/halium-architecture.md` for current behavior.

