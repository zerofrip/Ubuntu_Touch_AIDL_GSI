# Boot Flow — Ubuntu Touch AIDL GSI (Halium-style)

This project no longer uses a custom `/init/init` or a squashfs **rootfs pivot**
via `userdata`. Ubuntu runs as a late-boot **chroot** from `rootfs.erofs`.

Hard constraints:

- keep **stock `boot.img`**
- keep **stock kernel**
- do **not** flash `boot`, `vendor_boot`, `dtbo`, or `vendor`
- flash **`system.img` + disabled `vbmeta`**; flash **`userdata.img` on first install** to seed `/data/ubuntu-gsi/rootfs.erofs`

For the complete authoritative design, read:

- `docs/halium-architecture.md`
- `docs/flash_quickstart.md`

---

## Runtime sequence (current)

1. Bootloader loads the stock `boot.img` and stock kernel.
2. Android init from stock ramdisk becomes PID 1.
3. Android mounts our custom `system.img` (PHH Treble base + Halium overlay).
4. Android starts vendor HAL services normally (`servicemanager`/AIDL path).
5. `ubuntu-gsi-compat-android` runs from `/system/etc/init/ubuntu-gsi.rc`.
6. On `sys.boot_completed=1`, Android starts `/system/bin/ubuntu-gsi-launcher`.
7. Launcher ensures `/data/ubuntu-gsi/rootfs.erofs` (from userdata seed or by
   healing from `/system/usr/share/ubuntu-gsi/rootfs.erofs` when
   `ROOTFS_SEED_IN_SYSTEM=1`), mounts it read-only, assembles overlayfs on
   `/data/uhl_overlay/*`, bind-mounts `/vendor` + `/dev` + `/proc` + `/sys`,
   then `chroot`s into Ubuntu systemd.
8. Inside chroot, systemd starts `lomiri.service`, networking helpers, and
   `ubuntu-gsi-compat.service`.

---

## Removed from boot path

These are historical and live under `deprecated/`:

- `builder/init/init`
- `builder/init/mount.sh`
- `linux_rootfs.squashfs` pivot on `userdata`
- `binder-bridge.service`

---

## Flash flow (current)

First install (or when reseeding `/data`):

```bash
make flash
# equivalent: bash scripts/flash.sh
```

System-only update (keep existing `/data`):

```bash
make flash-system
# or: bash scripts/flash.sh --no-userdata
```

`boot`, `vendor_boot`, `dtbo`, and `vendor` stay untouched. Skipping userdata
is safe only when `/data/ubuntu-gsi/rootfs.erofs` (or a system seed heal path)
already exists.
