# Architecture (Halium-style, AIDL)

This repository uses a Halium-style architecture:

- Stock `boot.img` and stock kernel boot Android normally.
- PHH-based `system.img` carries Halium overlay components.
- Ubuntu runs as a chroot from `rootfs.erofs` after Android boot completion.

## High-level flow

```text
Bootloader
  -> Stock kernel + stock ramdisk init
  -> Android userspace + vendor HAL services
  -> /system/etc/init/ubuntu-gsi.rc
  -> /system/bin/ubuntu-gsi-launcher
  -> mount /data/ubuntu-gsi/rootfs.erofs (+ heal from system seed if needed)
  -> overlay on /data/uhl_overlay
  -> chroot to Ubuntu systemd
  -> Lomiri + Ubuntu services
```

## Key points

- No custom PID1 replacement.
- No legacy squashfs **rootfs pivot** on userdata. Current `userdata.img` only
  **seeds** `/data/ubuntu-gsi/rootfs.erofs` and overlay directories for first boot.
- Dual seed: runtime image on `/data`; optional heal from
  `/system/usr/share/ubuntu-gsi/rootfs.erofs` (`ROOTFS_SEED_IN_SYSTEM`).
- No mandatory binder bridge daemon in the primary boot path.
- Compatibility quirks are applied by `halium/compat/compat-engine.sh` in Android and Linux modes.

## Related docs

- `docs/halium-architecture.md` — authoritative design
- `docs/flash_quickstart.md` — flash / userdata policy
- `docs/hal-bridge-matrix.md` — HAL bring-up matrix
- `docs/lower-layer-display.md` — lower-layer display mode

## Legacy note

Previous architecture docs that referenced `squashfs` + `switch_root` + custom `/init/init`
are historical. See `deprecated/` for code history and `docs/halium-architecture.md` for the
authoritative current design.
