# Flash Quickstart (Halium-style, AIDL)

This quickstart assumes you want to keep stock `boot.img` and stock kernel unchanged.

## 1) Build

```bash
cd Ubuntu_Touch_AIDL_GSI
make build
```

Expected artifacts in `builder/out/`:

- `system.img`
- `vbmeta-disabled.img`

## 2) Reboot device to fastboot

```bash
adb reboot bootloader
```

or use hardware keys.

## 3) Flash only system + vbmeta

```bash
fastboot --disable-verity --disable-verification flash vbmeta builder/out/vbmeta-disabled.img
fastboot flash system builder/out/system.img
fastboot reboot
```

Do **not** flash `boot`, `vendor_boot`, `dtbo`, `vendor`, or `userdata`.

## 4) Runtime toggle

Enable launcher:

```bash
adb shell setprop persist.ubuntu_gsi.enable 1
```

Disable launcher (boot Android userspace only):

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

## 5) Recovery path

If the UI does not come up, return to Android-only userspace:

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

If system partition is broken, reflash stock system from OEM package.
