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
  - `lomiri/start-lomiri.sh` Lomiri startup (indicators, secrets, app-net watchdog)
- `scripts/`
  - `fetch_phh_gsi.sh` PHH base download/prepare
  - `build_rootfs.sh` Ubuntu chroot rootfs build
  - `build_rootfs_erofs.sh` rootfs -> erofs pack
  - `build_vbmeta_disabled.sh` disabled vbmeta build
  - `build_system_img.sh` PHH base + Halium overlay merge
  - `build_userdata_img.sh` userdata seed (`/data/ubuntu-gsi/rootfs.erofs`)
  - `fetch_openstore_clicks.sh` Core Apps click download (`rootfs/clicks.core-apps.list`)
  - `flash.sh` flashes `system + vbmeta + userdata` (selective flags available)
- `rootfs/overlay/usr/lib/ubuntu-gsi/`
  - WiFi reclaim / app DNS+routing (`wifi-bringup.sh`, `halium-app-net.sh`)
  - HAL / display bring-up helpers
- `deprecated/`
  - legacy pre-Halium components kept for reference

## Build Prerequisites

```bash
sudo apt install \
  debootstrap qemu-user-static e2fsprogs erofs-utils f2fs-tools jq wget unzip \
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

`main` is documentation-first for day-to-day commits, but **Actions → Build Ubuntu GSI → Run workflow** on `main` builds all vendor majors:

- `android-12.0_system.img` … `android-16.0_system.img` (PHH/TrebleDroid base differs per version)
- `userdata.img` and `vbmeta-disabled.img` once each (shared; not vendor-specific)
- Optional release tag input attaches those assets to a GitHub Release as
  `android-XX_system.img.xz` (xz-compressed; decompress before flash) plus
  shared `userdata.img` / `vbmeta-disabled.img`. Raw uncompressed system images
  remain on the workflow artifacts tab.

For a single-version local/CI build, checkout the matching `android-*` branch instead.


## Flash

```bash
make flash
```

or manually (local `builder/out/` images):

```bash
fastboot flash vbmeta_a builder/out/vbmeta-disabled.img
fastboot flash vbmeta_system_a builder/out/vbmeta-disabled.img
fastboot flash vbmeta_vendor_a builder/out/vbmeta-disabled.img
fastboot reboot fastboot
fastboot flash system_a builder/out/android-16.0_system.img
fastboot flash userdata builder/out/userdata.img
fastboot reboot
```

GitHub Release assets ship `android-XX_system.img.xz` — decompress first:

```bash
xz -dk android-16.0_system.img.xz
fastboot flash system_a android-16.0_system.img
```

Do **not** pass `--disable-verity` / `--disable-verification` to fastboot when flashing
standalone `vbmeta*.img` files. On fastboot 34+, that flag path fails with
`Failed to find AVB_MAGIC at offset: 0`. Verity is disabled by baking `flags=3`
into `vbmeta-disabled.img` at build time.

`make flash` includes **userdata** (wipes `/data`). Use that on first install.
For everyday system updates that keep existing `/data/ubuntu-gsi`, skip userdata:

```bash
make flash-system
make flash-vbmeta
bash scripts/flash.sh --no-userdata
```

Full flash guide: `docs/flash_quickstart.md`.

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

Core Apps (OpenStore clicks):

- Listed in `rootfs/clicks.core-apps.list`
- Fetched during `build_rootfs` into `builder/cache/openstore-clicks/` (or `make fetch-clicks`)
- Unpacked into rootfs at `/opt/click.ubuntu.com/` with `.desktop` entries for the Lomiri app drawer
- Skip network fetch with `GSI_SKIP_CLICK_FETCH=1` (uses existing cache only)

Rootfs persistence/self-heal:

- Launcher keeps runtime rootfs in `/data/ubuntu-gsi/rootfs.erofs`
- Backup copy is kept at `/data/ubuntu-gsi/rootfs.erofs.bak`
- SHA-256 is verified at boot; missing/corrupt data copy is auto-restored
- Restore source is system seed `/system/usr/share/ubuntu-gsi/rootfs.erofs`
- `ROOTFS_SEED_IN_SYSTEM=0` keeps `system.img` smaller, but removes reset-time seed restore


## CI multi-version (`main`)

From the Actions tab, run **Build Ubuntu GSI** on branch `main` (`workflow_dispatch`).
That produces every `android-XX_system.img` plus one shared `userdata.img` and
`vbmeta-disabled.img`. Set the optional tag input to publish a GitHub Release
(`*.img.xz` for system images so all majors fit under the 2GB asset limit).

## Documentation

- `docs/halium-architecture.md` — authoritative Halium design
- `docs/flash_quickstart.md` — flash / userdata policy
- `docs/boot_flow.md` / `docs/system_layout.md` — boot and layout
- `docs/hal-bridge-matrix.md` — HAL bring-up matrix
- `docs/lower-layer-display.md` — lower-layer / DRM display mode

## Notes

- Legacy docs/scripts that mention `linux_rootfs.squashfs`, squashfs **userdata pivot**, or binder bridge daemons are historical. Current `userdata.img` only seeds `/data/ubuntu-gsi/rootfs.erofs`.
- See `docs/halium-architecture.md` for current behavior.


