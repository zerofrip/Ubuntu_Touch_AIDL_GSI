# Ubuntu Touch GSI — Mobile Linux for Android Devices

[![Build](https://github.com/zerofrip/Ubuntu_Touch_GSI/actions/workflows/build.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_GSI/actions/workflows/build.yml)
[![Lint](https://github.com/zerofrip/Ubuntu_Touch_GSI/actions/workflows/lint.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_GSI/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A production-grade Ubuntu Touch distribution that runs natively on Android Treble devices. Uses AIDL-only binder IPC, Mir/Wayland display, and Lomiri shell to deliver a full Linux mobile experience on Android hardware.

## Architecture

```
┌─────────────────────────────────────────────┐
│           Lomiri Shell (Ubuntu Touch)       │
├─────────────────────────────────────────────┤
│             Mir / Wayland                   │
├─────────────────────────────────────────────┤
│   Ubuntu Userspace (systemd · apt · SSH)    │
├─────────────────────────────────────────────┤
│           Binder Bridge Daemon              │
├─────────────────────────────────────────────┤
│      AIDL HAL Wrappers (no HIDL)            │
│  power · audio · camera · sensors · gpu     │
├─────────────────────────────────────────────┤
│    /dev/binder ←→ Android Vendor HALs       │
├─────────────────────────────────────────────┤
│         Linux Kernel (vendor)               │
└─────────────────────────────────────────────┘
```

## ⚡ Quick Start

```bash
# Clone
git clone --recursive https://github.com/zerofrip/Ubuntu_Touch_GSI.git
cd Ubuntu_GSI

# Build everything (system.img + userdata.img)
make build

# Flash to device (fastboot — no adb required)
make flash
```

## 🛠️ Build

### Prerequisites

```bash
sudo apt install squashfs-tools e2fsprogs jq wget debootstrap qemu-user-static
```

| Tool | Package | Purpose |
|------|---------|---------|
| `mksquashfs` | `squashfs-tools` | Compress rootfs |
| `mkfs.ext4` | `e2fsprogs` | Create images |
| `jq` | `jq` | Parse HAL manifest |
| `debootstrap` | `debootstrap` | Build rootfs from scratch |
| `fastboot` | `android-tools-fastboot` | Flash device |

### Build Targets

```bash
make build          # Full pipeline: rootfs → squashfs → system.img → userdata.img
make rootfs         # Build Ubuntu rootfs (requires sudo)
make squashfs       # Compress rootfs to SquashFS
make system         # Generate system.img
make userdata       # Generate userdata.img
make package        # Build all images (uses existing rootfs)
```

### Configuration

Edit `config.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `ROOTFS_URL` | UBports Focal arm64 | Rootfs download URL |
| `SQUASHFS_COMP` | `xz` | Compression algorithm |
| `SYSTEM_IMG_SIZE_MB` | `0` (auto) | system.img size; `0` = content + 8 MB headroom (min 16 MB) |
| `USERDATA_IMG_SIZE_MB` | `0` (auto) | userdata.img size; `0` = squashfs + 64 MB headroom; expands on first boot |
| `ARCH` | `arm64` | Target architecture |

## 📱 Flash to Device

> **Important:** After flashing, the device boots Ubuntu — not Android. There is no `adbd`, so **adb cannot be used**. Both images must be flashed via fastboot.

```bash
# Interactive (recommended)
make flash

# Manual
fastboot flash system   builder/out/system.img
fastboot flash userdata builder/out/userdata.img
fastboot reboot
```

**Selective flashing:**
```bash
make flash-system     # System only (preserves userdata/settings)
make flash-userdata   # Userdata only (preserves system)
```

### Pre-flash device check:
```bash
make check-device     # Checks Treble, architecture, bootloader unlock
```

## 🖥️ First Boot

On first boot an **interactive terminal** appears on `/dev/console` to set the userdata partition size:

```
═══════════════════════════════════════════════════════════
  Ubuntu GSI — System Partition Setup
═══════════════════════════════════════════════════════════
  Device        : /dev/block/bootdevice/by-name/userdata
  Total capacity: 128.0 GB  (131072 MB)
  Formats: 20G / 512M / 50% / all (default) / skip
  Size [all]: _
```

After confirming, `resize2fs` expands the userdata ext4 to the selected size. The system then automatically:

1. Creates default user: **ubuntu** / **ubuntu**
2. Configures locale (en_US.UTF-8)
3. Sets timezone to UTC
4. Enables NetworkManager and SSH
5. Masks incompatible systemd units
6. Sets `graphical.target` for Lomiri shell

**SSH access (after boot):**
```bash
ssh ubuntu@<device-ip>    # password: ubuntu
```

## 📂 Repository Structure

```
Ubuntu_GSI/
├── aidl/                          # AIDL HAL service wrappers
│   ├── common/aidl_hal_base.sh    # Shared HAL library
│   ├── camera/camera_hal.sh
│   ├── audio/audio_hal.sh
│   ├── power/power_hal.sh
│   ├── sensors/sensors_hal.sh
│   ├── graphics/graphics_hal.sh
│   └── manifest.json              # HAL module manifest
├── binder/                        # Binder bridge daemon
│   └── binder-bridge.sh
├── rootfs/                        # Rootfs configuration
│   ├── packages.list              # Required packages
│   ├── overlay/                   # Files injected into rootfs
│   └── systemd/                   # Systemd service units
├── gui/                           # GUI stack
│   ├── install_lomiri.sh          # Lomiri installer
│   └── start_lomiri.sh            # Compositor launcher
├── builder/                       # Build pipeline
│   ├── init/                      # Boot init + mount.sh
│   ├── scripts/                   # Build scripts + QA tests
│   ├── system/                    # Legacy HAL subsystems
│   └── waydroid/                  # Waydroid container setup
├── scripts/                       # Host-side tools
│   ├── build_rootfs.sh            # Rootfs builder (debootstrap)
│   ├── build_userdata_img.sh      # Userdata image builder
│   ├── flash.sh                   # Fastboot flash script
│   ├── check_device.sh            # Device compatibility checker
│   └── check_environment.sh       # Build env validator
├── docs/                          # Documentation
│   ├── architecture.md            # System architecture
│   ├── gpu_graphics.md            # GPU strategy
│   ├── boot_flow.md               # Boot sequence
│   └── threat_model.md            # Security model
├── .github/workflows/             # CI pipeline
├── build.sh                       # Master build orchestrator
├── config.env                     # Build configuration
└── Makefile                       # Build targets
```

## 🎨 GPU Support

The graphics HAL auto-detects the best rendering pipeline:

| Pipeline | Detection | Performance |
|----------|-----------|-------------|
| **Vulkan/Zink** | vendor Vulkan driver → Mesa Zink | ★★★★★ |
| **EGL/libhybris** | vendor EGL driver → libhybris | ★★★★ |
| **LLVMpipe** | Fallback (always works) | ★★ |

If the compositor crashes, the watchdog automatically falls back to LLVMpipe. See [gpu_graphics.md](docs/gpu_graphics.md) for details.

## 🔧 Package Management

Ubuntu packages work normally via apt:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install firefox vlc
```

Changes persist in the OverlayFS upper layer. To factory reset, delete `/data/uhl_overlay/upper/`.

## 🔄 Recovery & Rollback

```bash
# Rollback to previous snapshot on next boot
touch /data/uhl_overlay/rollback
reboot
```

3 rotating snapshots are maintained automatically.

## 🔧 Troubleshooting

| Problem | Solution |
|---------|----------|
| Build fails | `make check` to validate environment |
| Device not detected | Ensure device is in fastboot mode |
| adb doesn't work after flash | **Expected** — use SSH instead |
| Black screen after flash | Reflash both images: `make flash` |
| GUI doesn't start | Check `journalctl -u lomiri` |
| SSH can't connect | Wait 30s for firstboot to complete |
| userdata.img too small | Increase `USERDATA_IMG_SIZE_MB` in config.env |

## 🏗️ Design Decisions

| Decision | Rationale |
|----------|-----------|
| AIDL-only (no HIDL) | HIDL deprecated since Android 12 |
| Binder IPC only | No vendor partition mount needed |
| OverlayFS | Immutable base + persistent changes |
| squashfs rootfs | Compressed, read-only, fast mount |
| fastboot-only install | No adbd after Ubuntu boots |
| systemd | Standard Linux service management |

## Security Model

| Layer | What It Blocks |
|-------|----------------|
| **Linux Namespaces** | Process/mount/network/IPC isolation |
| **Capability Drops** | Module loading, raw I/O |
| **Seccomp Filter** | Container escape syscalls |
| **SELinux MAC** | Unauthorized binder calls |
| **cgroup ACL** | Device access restrictions |

See [threat_model.md](docs/threat_model.md) for details.

## 📖 Documentation

| Document | Description |
|----------|-------------|
| [architecture.md](docs/architecture.md) | System architecture + diagrams |
| [gpu_graphics.md](docs/gpu_graphics.md) | GPU strategy + limitations |
| [boot_flow.md](docs/boot_flow.md) | Complete boot sequence |
| [threat_model.md](docs/threat_model.md) | Security analysis |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Developer guide |

## Third-Party Components

| Component | License |
|-----------|---------|
| AOSP frameworks/native | Apache 2.0 |
| AOSP system/core | Apache 2.0 |
| AOSP system/sepolicy | Apache 2.0 |
| LXC | LGPL-2.1+ |
| libseccomp | LGPL-2.1 |

See [NOTICE](NOTICE) for full attribution.

## 📄 License

Apache License 2.0. See [LICENSE](LICENSE).
