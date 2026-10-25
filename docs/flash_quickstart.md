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

GitHub Releases attach `android-XX_system.img.xz` (compressed). Decompress before
flashing (`xz -dk android-16.0_system.img.xz`). Uncompressed raw images are also
on the Actions workflow artifacts tab.

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
# From a GitHub Release download:
# xz -dk android-16.0_system.img.xz

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

### Debug trace (optional)

Set `UBUNTU_GSI_DEBUG_TRACE=1` in the environment before starting Android to enable
opt-in JSON structured logging to `/data/local/tmp/ubuntu-gsi-debug-trace.log`
(override path with `UBUNTU_GSI_DEBUG_TRACE_LOG`). All NVT touch and HWC diagnostics
gate behind this flag; it defaults to off. There is no persisted system property for
this -- it must be exported in the environment of whatever process runs the launcher
and compat scripts (for example via a `setenv` override in a custom `.rc` fragment,
or by exporting it before invoking the scripts by hand over `adb shell`).

### F8 (MT6897) HWC in-process patch (build time)

Set `ENABLE_HWC_INPROC_PATCH=1` in `config.env` before running `make build` to build
and ship a patched `hwc_inproc.so` inside `system.img` at
`/system/usr/lib/ubuntu-gsi/halium-compat/hwc_inproc.so`.

The patch input is `builder/out/hwc-patches/hwcomposer.mtk_common.patched.so`
(the PQ-v1-patched binary — **not** the raw stock `.so`). If that file is absent,
`make build` will print a clear error explaining how to extract it from a connected F8
first. The search order at runtime is:

1. `/data/uhl_overlay/halium-compat/hwc_inproc.so` (hotfix overlay — highest priority)
2. `/data/local/tmp/hwc_inproc.so`
3. `/system/usr/lib/ubuntu-gsi/halium-compat/hwc_inproc.so` (shipped in system.img)

The patched `.so` is only ever bind-mounted at runtime; it is never written to `/vendor`.

## 5) Recovery path

If Lomiri does not come up, return to Android-only userspace:

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

If the system partition is broken, reflash stock system from the OEM package,
then re-apply this project's `system` + `vbmeta` (and `userdata` if `/data` was wiped).

See also: `docs/halium-architecture.md`, `docs/lower-layer-display.md`.

## 6) Verifying apt upgrade safety

From the second boot onward, `apt upgrade`/`apt dist-upgrade` can be used
inside the chroot to update all packages. Because this environment runs on
top of the unmodified Android kernel (there is no real `/boot`, no
initramfs-tools-managed initrd, and no bootloader for the chroot to manage),
the rootfs ships an apt pin (`/etc/apt/preferences.d/90-ubuntu-gsi-no-kernel.pref`)
that prevents `linux-image*`, `linux-headers*`, `initramfs-tools*`, `grub*`,
and related packages from ever being installed or upgraded, even
transitively.

To confirm the safeguard is active:

```bash
adb shell
# inside the chroot (e.g. via the ubuntu-gsi-launcher shell, or ssh):
apt-get update
apt-get dist-upgrade --dry-run
```

Check the dry-run output: packages matching `linux-image*`, `linux-headers*`,
`linux-modules*`, `linux-base`, `initramfs-tools*`, `grub*`, `flash-kernel`,
`u-boot*`, `shim*`, or `systemd-boot` must **not** appear in the list of
packages to be installed or upgraded. If any do appear, the pin file is
missing or was overridden; do not proceed with the upgrade.
