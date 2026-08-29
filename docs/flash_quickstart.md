# Flash Quickstart (Halium-style, AIDL)

Keep stock `boot.img` and stock kernel unchanged. Flash only `system`, disabled
`vbmeta*`, and (on first install) `userdata`.

## 1) Build

```bash
cd Ubuntu_Touch_AIDL_GSI
git checkout android-16.0   # or android-12.0 … android-15.0 matching vendor
make build-minimal
```

Expected artifacts in `builder/out/`:

- `android-XX_system.img` (e.g. `android-16.0_system.img`; `system.img` symlink may exist)
- `vbmeta-disabled.img`
- `userdata.img` (seeds `/data/ubuntu-gsi/rootfs.erofs` + overlay dirs)
- `linux_rootfs.erofs` (intermediate)

## 2) Reboot device to fastboot

```bash
adb reboot bootloader
```

or use hardware keys.

## 3) Flash (recommended: Makefile)

```bash
make flash
```

This runs `scripts/flash.sh` and flashes **system + vbmeta-disabled + userdata**
by default (with size checks).

### Manual flash (A/B example)

```bash
fastboot flash vbmeta_a builder/out/vbmeta-disabled.img
fastboot flash vbmeta_system_a builder/out/vbmeta-disabled.img
fastboot flash vbmeta_vendor_a builder/out/vbmeta-disabled.img
fastboot reboot fastboot
fastboot flash system_a builder/out/android-16.0_system.img
fastboot flash userdata builder/out/userdata.img
fastboot reboot
```

Do **not** pass `--disable-verity` / `--disable-verification` when flashing
standalone `vbmeta*.img` files. On fastboot 34+, that path fails with
`Failed to find AVB_MAGIC at offset: 0`. Verity is disabled by baking
`flags=3` into `vbmeta-disabled.img` at build time.

Do **not** flash `boot`, `vendor_boot`, `dtbo`, or `vendor`.

### When to flash userdata

| Situation | userdata |
|-----------|----------|
| First install / factory reset / empty `/data` | **Flash** (`make flash` or `--userdata-only`) |
| Refresh rootfs seed + wipe `/data` | **Flash** |
| Everyday system (and/or vbmeta) update with existing `/data/ubuntu-gsi` | **Skip** (`make flash-system` or `bash scripts/flash.sh --no-userdata`) |

Flashing `userdata` wipes Android `/data` (apps, Wi‑Fi, settings).

Selective targets:

```bash
make flash-system
make flash-vbmeta
bash scripts/flash.sh --no-userdata
bash scripts/flash.sh --userdata-only
```

## 4) Runtime toggle

Lomiri auto-starts after power-on / `sys.boot_completed` by default
(`persist.ubuntu_gsi.enable=1` is baked into `system.img`).

Disable launcher (boot Android userspace only):

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

Re-enable auto-start:

```bash
adb shell setprop persist.ubuntu_gsi.enable 1
adb reboot
```

## 5) Recovery path

If Lomiri does not come up, return to Android-only userspace:

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

If the system partition is broken, reflash stock system from the OEM package,
then re-apply this project's `system` + `vbmeta` (and `userdata` if `/data` was wiped).

See also: `docs/halium-architecture.md`, `docs/lower-layer-display.md`.
