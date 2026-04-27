# Architecture (Halium-style, AIDL)

This repository now uses a Halium-style architecture:

- Stock `boot.img` and stock kernel boot Android normally.
- PHH-based `system.img` carries Halium overlay components.
- Ubuntu runs as a chroot from `rootfs.erofs` after Android boot completion.

## High-level flow

```mermaid
flowchart TD
    BL[Bootloader] --> K[Stock kernel + stock ramdisk init]
    K --> A[Android userspace + vendor HAL services]
    A --> RC[/system/etc/init/ubuntu-gsi.rc]
    RC --> L[/system/bin/ubuntu-gsi-launcher]
    L --> R[Mount rootfs.erofs + overlay on /data/uhl_overlay]
    R --> C[chroot to Ubuntu systemd]
    C --> U[Lomiri + Ubuntu services]
```

## Key points

- No custom PID1 replacement.
- No `userdata.img` rootfs payload.
- No mandatory binder bridge daemon in the primary boot path.
- Compatibility quirks are applied by `halium/compat/compat-engine.sh` in Android and Linux modes.

## Legacy note

Previous architecture docs that referenced `squashfs` + `switch_root` + custom `/init/init`
are historical. See `deprecated/` for code history and `docs/halium-architecture.md` for the
authoritative current design.
