# Boot Flow — Ubuntu Touch AIDL GSI (Halium-style)

This project no longer uses a custom `/init/init` or `userdata.img` rootfs pivot.

As of April 2026, boot is redesigned to satisfy the hard constraint:

- keep **stock `boot.img`**
- keep **stock kernel**
- flash only **`system.img` + disabled `vbmeta`**

For the complete authoritative design, read:

- `docs/halium-architecture.md`

---

## Runtime sequence (current)

1. Bootloader loads the stock `boot.img` and stock kernel.
2. Android init from stock ramdisk becomes PID 1.
3. Android mounts our custom `system.img` (PHH Treble base + Halium overlay).
4. Android starts vendor HAL services normally (`servicemanager`/AIDL path).
5. `ubuntu-gsi-compat-android` runs from `/system/etc/init/ubuntu-gsi.rc`.
6. On `sys.boot_completed=1`, Android starts `/system/bin/ubuntu-gsi-launcher`.
7. Launcher mounts `/system/usr/share/ubuntu-gsi/rootfs.erofs`, assembles overlayfs on `/data/uhl_overlay/*`, bind-mounts `/vendor` + `/dev` + `/proc` + `/sys`, then `chroot`s into Ubuntu systemd.
8. Inside chroot, systemd starts `lomiri.service` and `ubuntu-gsi-compat.service`.

---

## Removed from boot path

These are now historical and live under `deprecated/`:

- `builder/init/init`
- `builder/init/mount.sh`
- `linux_rootfs.squashfs` on `userdata`
- `binder-bridge.service`

---

## Flash flow (current)

```bash
fastboot --disable-verity --disable-verification flash vbmeta builder/out/vbmeta-disabled.img
fastboot flash system builder/out/system.img
fastboot reboot
```

`boot`, `vendor_boot`, `dtbo`, `vendor`, `userdata` are intentionally untouched.
