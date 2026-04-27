# System Layout (Halium-style, AIDL)

## Flash artifacts

Built under `builder/out/`:

- `system.img` (PHH base + Halium overlay + `rootfs.erofs` payload)
- `vbmeta-disabled.img`
- `linux_rootfs.erofs` (intermediate payload used inside `system.img`)

## Partition usage

- `system`: flashed with project-built `system.img`
- `vbmeta`: flashed with `vbmeta-disabled.img`
- `boot` / `vendor_boot` / `dtbo` / `vendor` / `userdata`: untouched

## Runtime mount model

1. Android mounts `/system` (our PHH+overlay system image).
2. `ubuntu-gsi-launcher` mounts `/system/usr/share/ubuntu-gsi/rootfs.erofs` read-only.
3. Overlay upper/work reside under `/data/uhl_overlay/{upper,work}`.
4. Launcher bind-mounts `/vendor`, `/dev`, `/proc`, `/sys`, `/data` into chroot view.
5. `chroot` to Ubuntu systemd.

## Core paths

- `/system/etc/init/ubuntu-gsi.rc`
- `/system/bin/ubuntu-gsi-launcher`
- `/system/bin/ubuntu-gsi-stop-android-ui`
- `/system/usr/lib/ubuntu-gsi/compat/`
- `/system/usr/share/ubuntu-gsi/rootfs.erofs`

For design details and constraints, see `docs/halium-architecture.md`.
