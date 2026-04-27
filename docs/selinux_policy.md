# SELinux Policy Notes (Halium-style)

The current flow does **not** replace Android PID1 or boot into a standalone
Linux init. Ubuntu is started later as a chroot from Android init services.

## Practical implications

- Android SELinux policy remains the primary policy authority.
- Project scripts run in available Android service domains (or permissive/dev contexts).
- Chrooted Ubuntu processes are still constrained by kernel+SELinux behavior of the host.

## Current policy stance

This repository does not ship a full custom sepolicy tree yet.
Policy handling is delegated to the PHH base + vendor policy environment.

## Future work

- Define minimal additional domains for launcher and compat services.
- Document required allows for binderfs, DRM, and input nodes.
- Add per-device policy overlays only when strictly required.

For architecture context, see `docs/halium-architecture.md`.
