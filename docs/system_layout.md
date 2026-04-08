# System Image Directory Layout

This document describes the directory structure of both flashable images and the runtime filesystem view after the OverlayFS pivot.

---

## System Partition (`system.img`) — Read-Only, Minimal

Built by `builder/scripts/gsi-pack.sh`. Its only purpose is to provide a custom init that pivots the root filesystem to the Ubuntu SquashFS stored on the userdata partition.

Size is auto-computed: content size + 8 MB headroom (minimum 16 MB). Override via `SYSTEM_IMG_SIZE_MB` in `config.env`.

```
/                               ← ext4 root (system.img)
├── init/
│   ├── init                    ← Custom PID-1 shell script (Stages 1–6)
│   └── mount.sh                ← OverlayFS pivot + switch_root script
├── scripts/
│   ├── detect-gpu.sh           ← Probe vendor Vulkan/EGL presence → /tmp/gpu_state
│   ├── detect-vendor-services.sh ← Binder service liveness check → /tmp/binder_state
│   └── ...                     ← Additional detection and utility scripts
├── system/                     ← Empty directory stub
├── data/                       ← Empty directory (populated from userdata at runtime)
├── dev/
│   └── binderfs/               ← Empty mount point for BinderFS
└── vendor/                     ← Mount point for vendor partition (ro, ext4)
```

**What is NOT in `system.img`:**
- No Android `servicemanager`, `logd`, or any Android userspace binaries
- No LXC or container runtime
- No Ubuntu packages — the Ubuntu rootfs lives entirely in `userdata.img`

---

## Userdata Partition (`userdata.img`) — Read-Write

Built by `scripts/build_userdata_img.sh`. Kept **minimal** at flash time (`linux_rootfs.squashfs` size + 64 MB headroom) and expanded to the user-selected size on first boot via `resize2fs`.

Override auto-size via `USERDATA_IMG_SIZE_MB` in `config.env`.

```
/                               ← ext4 root (userdata.img)
├── linux_rootfs.squashfs       ← Full Ubuntu arm64 rootfs (SquashFS, xz-compressed, read-only)
└── uhl_overlay/
    ├── upper/                  ← OverlayFS upper layer (all persistent writes go here)
    ├── work/                   ← OverlayFS work directory (kernel internal use)
    ├── snapshot.1/             ← Snapshot of upper/ captured at previous boot
    ├── snapshot.2/             ← Older snapshot (rotated each boot)
    ├── snapshot.3/             ← Oldest snapshot (generation > 3 garbage-collected)
    ├── rollback                ← (optional) trigger file: if present, restores snapshot.1 on next boot
    ├── .firstboot_complete     ← Marker: firstboot.service already completed
    ├── firstboot.log           ← firstboot.sh output log
    ├── rollback.log            ← mount.sh pivot + snapshot rotation log
    └── snapshot_rotation.log   ← Snapshot generation audit log
```

---

## Runtime Filesystem View (`/rootfs/merged`) — Post-Pivot

After `switch_root`, the OverlayFS merged view becomes the root filesystem seen by systemd and all Ubuntu processes.

```
/                               ← OverlayFS merged
│                                  (lower = linux_rootfs.squashfs)
│                                  (upper = /data/uhl_overlay/upper)
│
├── data/uhl_overlay/           ← Bind-mounted from host /data/uhl_overlay
│   ├── upper/
│   ├── work/
│   ├── snapshot.{1,2,3}/
│   ├── .firstboot_complete
│   └── *.log
│
├── vendor/                     ← Bind-mounted from host /vendor (read-only)
│
├── dev/
│   └── binderfs/               ← Bind-mounted from host /dev/binderfs
│       ├── binder              (also symlinked as /dev/binder)
│       ├── vndbinder           (also symlinked as /dev/vndbinder)
│       └── hwbinder            (also symlinked as /dev/hwbinder)
│
├── tmp/
│   ├── gpu_state               ← GPU detection result: Vulkan / EGL / Software
│   └── binder_state            ← Binder service liveness: IPC_LIVE / IPC_DEAD
│
├── lib/systemd/systemd         ← New PID 1 (executed by switch_root)
│
├── etc/systemd/system/
│   ├── ubuntu-gsi-firstboot.service
│   ├── binder-bridge.service
│   └── lomiri.service
│
└── usr/lib/ubuntu-gsi/
    └── firstboot.sh            ← First-boot initialization script
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Ubuntu rootfs in `userdata`, not `system` | Avoids dm-verity restrictions; no OEM signing key required |
| SquashFS for rootfs | ~50 % size reduction vs. raw ext4; immutable read-only base layer |
| OverlayFS upper layer on `userdata` | `apt install` / config changes persist across reboots without touching `system` |
| 3-generation snapshot rotation | One-command rollback to previous state without fastboot |
| Minimal `system.img` | Passes dm-verity; only init + mount logic needed on the signed partition |
| Auto-expand on first boot | Delivers a small flashable image; uses full device storage at runtime |


---

## System Partition (`/system/`) — Read-Only

The system partition is the GSI image flashed via `fastboot`. It is **always mounted read-only** and protected by dm-verity.

```
/system/
├── bin/
│   ├── servicemanager          # AIDL binder service manager (from AOSP)
│   ├── logd                    # Logging daemon (from AOSP)
│   ├── logcat                  # Log reader utility (from AOSP)
│   ├── lxc-start               # LXC container launcher (cross-compiled for Bionic)
│   ├── lxc-attach              # LXC container attach utility
│   ├── lxc-info                # LXC container info utility
│   ├── lxc-stop                # LXC container stop utility
│   └── sh                      # Shell (toybox/mksh from AOSP)
│
├── lib64/
│   ├── libbinder.so            # Android Binder runtime library
│   ├── libutils.so             # Android utility library
│   ├── libcutils.so            # Android C utility library
│   ├── liblog.so               # Android logging library
│   ├── libc.so                 # Bionic C library
│   ├── libm.so                 # Bionic math library
│   ├── libdl.so                # Bionic dynamic linker
│   ├── libselinux.so           # SELinux library
│   └── liblxc.so               # LXC container library
│
├── etc/
│   ├── init/
│   │   └── ubuntu-gsi.rc       # Minimal Android init configuration
│   ├── lxc/
│   │   └── ubuntu/
│   │       └── config          # LXC container configuration
│   ├── selinux/
│   │   ├── ubuntu_gsi.cil      # SELinux policy (CIL source)
│   │   └── plat_sepolicy.cil   # Platform SELinux policy (from AOSP)
│   ├── seccomp/
│   │   └── ubuntu_container.json  # Seccomp syscall filter profile
│   └── vintf/
│       └── manifest.xml        # VINTF manifest (AIDL HALs only)
│
├── build.prop                  # System build properties
└── init                        # Android init binary (PID 1)
```

---

## Data Partition (`/data/`) — Read-Write

The data partition is the writable userdata partition. It contains the Ubuntu rootfs and all mutable state.

```
/data/
├── ubuntu/
│   ├── rootfs/                 # Ubuntu base rootfs (extracted from tarball)
│   │   ├── bin/
│   │   ├── etc/
│   │   │   ├── apt/
│   │   │   │   └── sources.list    # Ubuntu apt repositories (ports.ubuntu.com)
│   │   │   ├── systemd/
│   │   │   │   ├── system/
│   │   │   │   │   ├── binder-bridge.service
│   │   │   │   │   ├── ubuntu-gsi-init.service
│   │   │   │   │   └── multi-user.target.wants/
│   │   │   │   └── network/
│   │   │   │       └── 50-eth0.network
│   │   │   ├── resolv.conf
│   │   │   └── hostname
│   │   ├── lib/
│   │   ├── sbin/
│   │   │   └── init -> /lib/systemd/systemd
│   │   ├── usr/
│   │   │   └── local/
│   │   │       └── bin/
│   │   │           ├── binder-bridge
│   │   │           └── ubuntu-gsi-init
│   │   ├── var/
│   │   └── dev/
│   │       └── binder             # Mount point (bind-mounted by LXC)
│   │
│   ├── overlay/                # OverlayFS upper layer (writable)
│   │   └── (apt changes, user data, configs written here)
│   │
│   └── workdir/                # OverlayFS work directory
│
└── lxc/
    └── ubuntu/
        └── lxc.log             # LXC container log
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Ubuntu rootfs on `/data` (not `/system`) | System partition is read-only (dm-verity). User data partition is writable and survives GSI updates. |
| OverlayFS for rootfs | Allows apt to install/update packages (writes to upper layer) without modifying the base rootfs. Clean reinstall = delete overlay. |
| No vendor partition mount | Treble isolation — Ubuntu never sees vendor blobs. AIDL HAL access is via binder IPC only. |
| LXC binaries on `/system` | Part of the GSI image, verified by dm-verity. Updated only via GSI flash. |
| Ubuntu binaries on `/data` | Updated via apt, no reflash needed. |

---

## Partition Size Estimates

| Partition | Content | Estimated Size |
|-----------|---------|---------------|
| `system` (GSI) | Android init, servicemanager, logd, LXC, libs, configs | ~50–80 MB |
| `data` (Ubuntu rootfs) | Ubuntu base + packages | ~500 MB – 2 GB |
| `data` (overlay) | User modifications, apt cache | Variable |

> [!NOTE]
> The system partition is dramatically smaller than a standard Android GSI (~1.5 GB) because we exclude the entire Android framework (Zygote, SurfaceFlinger, SystemServer, apps, etc.).
