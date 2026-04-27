# Threat Model (Halium-style)

This document covers the current architecture where Android remains the host OS
and Ubuntu runs as a chroot launched post-boot.

## Trust boundaries

- Boot chain: OEM-controlled (`bootloader`, `boot.img`, kernel)
- Android host userspace: PHH base + vendor services
- Ubuntu guest userspace: chroot environment started by launcher
- Shared kernel and shared device nodes (`/dev`, binderfs, DRM, input)

## Primary risks

1. **Privileged launcher misuse**
   - `ubuntu-gsi-launcher` runs as root from Android init context.
2. **Shared-kernel attack surface**
   - Ubuntu and Android processes share one kernel.
3. **Compatibility quirk overreach**
   - `compat-engine` may write sysfs/proc knobs with unsafe values.
4. **Misconfigured verity state**
   - Disabled vbmeta is required for custom system; this weakens integrity guarantees.

## Mitigations

- Keep launcher script minimal and audited.
- Restrict compat rules and require explicit per-device match conditions.
- Preserve stock `boot.img` and kernel to avoid introducing ramdisk/kernel regressions.
- Keep `persist.ubuntu_gsi.enable=0` escape hatch for Android-only recovery.

## Residual risk

This project prioritizes compatibility and bring-up flexibility over hard-lock
integrity guarantees. Devices using disabled vbmeta should be treated as
untrusted-development profiles, not high-assurance production security targets.
