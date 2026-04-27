# Deprecated Components

The contents of this directory belong to the **previous architecture**, which
attempted to entirely replace Android's userspace with Linux/systemd by
flashing a custom `system.img` plus a `userdata.img` containing the rootfs.

That architecture was abandoned in **April 2026** because it requires a
**custom `boot.img`** (to make the kernel execute our shell `init` instead
of Android's stock init), which violates the project owner's hard
constraint of *"never modify the stock `boot.img` or kernel."*

The current Halium-style design is documented in
[`docs/halium-architecture.md`](../docs/halium-architecture.md).

Nothing in this directory is built by the current `build.sh` /
`Makefile` / `scripts/`. It is preserved purely for historical reference,
`git blame`, and possible reuse should the constraints ever change.

## Inventory

| Path | Was used for | Reason it was retired |
|------|--------------|-----------------------|
| `aidl/` | Self-built shell HAL wrappers (audio, camera, sensors, …) | Vendor HALs are reachable directly via `/dev/binder` once the stock Android runs underneath; no shell wrapper is needed. |
| `binder/` | Self-built bridge daemon between Linux and `/dev/binder` | Android already runs `servicemanager`, so binder is usable as-is. |
| `builder-init/` | Custom `/init/init` and `/init/mount.sh` shell scripts injected into `system.img` as PID 1 | Stock Android init is now PID 1 (constraint #1). |
| `builder-system/` | Linux-only system subsystems (logging, dbus glue, etc.) shipped at root of `system.img` | Now live inside the Ubuntu chroot rootfs (`rootfs.erofs`), not at `/system`. |
| `builder-waydroid/` | Waydroid container artefacts | Waydroid is not part of the Halium-inverse design. If needed, it can be installed inside the chroot via `apt`. |
| `gsi-pack-old.sh` | Old `system.img` packager that produced an ext4 with `/init` at root | Replaced by `scripts/build_system_img.sh`, which overlays our additions on top of a PHH Treble GSI base. |
| `systemd-units-old/` | systemd HAL service units (`audio-hal.service`, `binder-bridge.service`, …) | The HALs are no longer wrapped on the Linux side. |

## When Would I Look Here?

* You are debugging why a particular HAL was previously implemented as a
  shell wrapper and want to understand the contract.
* You are building a different downstream product where you *can* modify
  `boot.img` (e.g. a developer-board flavour).
* You are auditing the `git` history of a specific component and want to
  see its last working state in the legacy architecture.

For everything else, work from the current `halium/`, `rootfs/`, and
`scripts/` directories.
