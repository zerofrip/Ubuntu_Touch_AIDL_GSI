# Builder Architecture (Halium-style, AIDL)

This builder no longer produces a custom-init Linux-only system image.

Current objective:

- keep stock `boot.img`
- keep stock kernel
- compose a PHH-based `system.img` that launches Ubuntu post-boot

## Build pipeline

```text
fetch_phh_gsi.sh
  -> cache PHH base image (Android 14 defaults for AIDL)
  -> build_rootfs.sh
  -> build_rootfs_erofs.sh
  -> build_vbmeta_disabled.sh
  -> build_system_img.sh
```

## Artifact model

- `builder/cache/phh-gsi.img`
  - PHH Treble base image
- `builder/out/ubuntu-rootfs/`
  - unpacked Ubuntu rootfs staging tree
- `builder/out/linux_rootfs.erofs`
  - compressed chroot payload
- `builder/out/system.img`
  - PHH base + Halium overlay + rootfs.erofs
- `builder/out/vbmeta-disabled.img`
  - hashtree-disabled vbmeta for custom system mounting

## Runtime hand-off model

```text
stock Android init
  -> /system/etc/init/ubuntu-gsi.rc
  -> /system/bin/ubuntu-gsi-launcher
  -> mount rootfs.erofs + overlay on /data/uhl_overlay
  -> chroot to Ubuntu systemd
  -> Lomiri and Ubuntu services
```

## Legacy note

Previous builder docs that referenced custom `/init`, `mount.sh`, squashfs-on-userdata,
or bridge daemons as mandatory boot components are legacy. Their code is preserved under
`deprecated/` for historical reference.
