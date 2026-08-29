# System Layout (Halium-style, AIDL)

## Flash artifacts

Built under `builder/out/`:

- `android-XX_system.img` (PHH base + Halium overlay; optional in-system rootfs seed)
- `vbmeta-disabled.img`
- `userdata.img` (ext4 seed of `/data/ubuntu-gsi/rootfs.erofs` + `/data/uhl_overlay/{upper,work}`)
- `linux_rootfs.erofs` (intermediate payload packed into userdata and/or system)

## Partition usage

- `system`: flashed with project-built `android-XX_system.img`
- `vbmeta` / `vbmeta_system` / `vbmeta_vendor` (as needed): `vbmeta-disabled.img`
- `userdata`: flashed on **first install** (or to reseed/wipe `/data`); skip for everyday system updates
- `boot` / `vendor_boot` / `dtbo` / `vendor`: untouched

## Runtime mount model

1. Android mounts `/system` (our PHH+overlay system image).
2. `ubuntu-gsi-launcher` uses `/data/ubuntu-gsi/rootfs.erofs` as the primary
   rootfs image (seeded by `userdata.img`, or restored from
   `/system/usr/share/ubuntu-gsi/rootfs.erofs` when present).
3. Overlay upper/work reside under `/data/uhl_overlay/{upper,work}`
   (may use an ext4 loop on f2fs `/data`).
4. Launcher bind-mounts `/vendor`, `/dev`, `/proc`, `/sys`, `/data` into the chroot view.
5. `chroot` to Ubuntu systemd.

## Core paths

- `/system/etc/init/ubuntu-gsi.rc`
- `/system/bin/ubuntu-gsi-launcher`
- `/system/bin/ubuntu-gsi-stop-android-ui`
- `/system/usr/lib/ubuntu-gsi/compat/`
- `/system/usr/share/ubuntu-gsi/rootfs.erofs` (optional seed when `ROOTFS_SEED_IN_SYSTEM=1`)
- `/data/ubuntu-gsi/rootfs.erofs` (runtime rootfs image)
- `/data/uhl_overlay/{upper,work}`

For design details and constraints, see `docs/halium-architecture.md`.
