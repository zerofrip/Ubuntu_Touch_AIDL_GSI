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
│  wifi · telephony/SIM · input/touchscreen   │
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

On first boot, the system automatically:

1. Expands the userdata partition to full capacity (`resize2fs`)
2. Creates temporary default user: **ubuntu** / **ubuntu**
3. Configures locale, timezone, networking
4. Enables SSH
5. Launches **Lomiri Shell** (Mir/Wayland)
6. Starts the **GUI Setup Wizard** (with on-screen keyboard)

The Setup Wizard allows you to configure:
- Username
- Password
- Timezone
- System language

> No physical keyboard required — the on-screen keyboard (Onboard) launches automatically.

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
│   │   └── usr/lib/ubuntu-gsi/
│   │       ├── firstboot.sh       # Non-interactive first boot
│   │       └── setup-wizard.sh    # GUI setup wizard (zenity)
│   └── systemd/                   # Systemd service units
│       ├── ubuntu-gsi-firstboot.service
│       └── ubuntu-gsi-setup-wizard.service
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
| Setup wizard doesn't appear | Check `journalctl -u ubuntu-gsi-setup-wizard` |
| On-screen keyboard missing | Verify `onboard` is installed: `dpkg -l onboard` |
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

| Component | License | Source |
|-----------|---------|--------|
| AOSP frameworks/native | Apache 2.0 | [AOSP](https://android.googlesource.com/platform/frameworks/native) |
| AOSP system/core | Apache 2.0 | [AOSP](https://android.googlesource.com/platform/system/core) |
| AOSP system/sepolicy | Apache 2.0 | [AOSP](https://android.googlesource.com/platform/system/sepolicy) |
| LXC | LGPL-2.1+ | [GitHub](https://github.com/lxc/lxc) |
| libseccomp | LGPL-2.1 | [GitHub](https://github.com/seccomp/libseccomp) |
| Lomiri Shell | GPL-3.0 | [GitLab](https://gitlab.com/ubports/development/core/lomiri) |
| Mir Display Server | GPL-2.0 / LGPL-3.0 | [GitHub](https://github.com/canonical/mir) |
| Onboard (OSK) | GPL-3.0 | [Launchpad](https://launchpad.net/onboard) |
| Zenity | LGPL-2.1+ | [GitLab](https://gitlab.gnome.org/GNOME/zenity) |
| Ubuntu Font Family | Ubuntu Font Licence 1.0 | [Ubuntu](https://design.ubuntu.com/font) |
| Noto Fonts | OFL-1.1 | [GitHub](https://github.com/googlefonts/noto-fonts) |
| Adwaita Icon Theme | LGPL-3.0+ / CC-BY-SA-3.0 | [GitLab](https://gitlab.gnome.org/GNOME/adwaita-icon-theme) |
| dbus-x11 | GPL-2.0+ | [freedesktop.org](https://www.freedesktop.org/wiki/Software/dbus/) |

See [NOTICE](NOTICE) for full attribution and source code availability.

## 📄 License

Apache License 2.0. See [LICENSE](LICENSE).
