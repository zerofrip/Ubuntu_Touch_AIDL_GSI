# Ubuntu Touch GSI Final Master Framework

[![Build](https://github.com/zerofrip/Ubuntu_GSI/actions/workflows/build.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_GSI/actions/workflows/build.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

This repository provides the ultimate, production-grade logic for deploying **Ubuntu Touch (Linux) GSI** implementations on **Android 15-18+** devices. It integrates advanced GPU abstraction, HAL dynamic detection, multi-generation snapshot management, and isolated LXC sandboxing.

## ⚡ Quick Start

```bash
# Clone with submodules
git clone --recursive https://github.com/zerofrip/Ubuntu_GSI.git
cd Ubuntu_GSI

# Check build environment
make check

# Build (downloads rootfs automatically if missing)
make build

# Flash to device (interactive)
make install
```

## 🚀 Key Features

- **Stepwise GPU Discovery:** Automatic transitioning from Native Vulkan/EGL to libhybris, with a 5-second Watchdog triggering LLVMpipe fallback.
- **Universal HAL Layer (UHL):** Event-driven, modular daemons using a shared HAL library (`common_hal.sh`) and dynamic JSON manifests.
- **Multi-Generation Snapshots:** 3+ rotating OverlayFS generations with automated garbage collection and explicit rollback triggers.
- **LXC Sandbox Isolation:** Dynamic NAT assignment (10.x.3.1), strict BinderFS write-locks, and Seccomp V2 filtering for Waydroid.
- **OTA Multi-Stage Safety:** Fingerprint-based cache flushing to ensure stability across Android vendor updates.
- **Automated QA Reporting:** Comprehensive HTML, JSON, and CSV diagnostic reports tracking total subsystem health.
- **CI/CD Pipeline:** GitHub Actions workflow with ShellCheck linting and automated builds.

## 📂 Repository Structure

### 🛠️ Host-Side Tooling (`scripts/`)
- **`scripts/check_environment.sh`**: Validates build dependencies, disk space, and submodule status.
- **`scripts/install.sh`**: Interactive device flash helper (fastboot + ADB automation).

### 🛠️ Core Build Pipeline
- **`build.sh`**: The master build orchestrator. Sources `config.env`, runs environment check, then sequences rootfs extraction → SquashFS compilation → system.img packaging.
- **`config.env`**: Configurable build parameters (rootfs URL, compression, image size, architecture).
- **`Makefile`**: Convenience targets — `make build`, `make check`, `make clean`, `make install`, `make lint`.

### 🛠️ Builder Components (`builder/`)
- **`builder/scripts/rootfs-builder.sh`**: Compiles the Ubuntu rootfs into a compressed SquashFS block.
- **`builder/scripts/gsi-pack.sh`**: Generates the final `system.img` for Fastboot flashing.
- **`builder/scripts/detect-gpu.sh`**: GPU capability discovery and OTA-safe caching.
- **`builder/scripts/detect-vendor-services.sh`**: Scans Android vendor HALs and generates fingerprint hashes.

### 🧩 Subsystems (`builder/`)
- **`builder/init/`**:
    - `mount.sh`: Manages OverlayFS pivot_root, snapshot rotation, and fallback recovery.
- **`builder/system/gpu-wrapper/`**:
    - `gpu-bridge.sh`: Manages compositor lifecycle, hardware acceleration, and the LLVMpipe watchdog.
- **`builder/system/uhl/`**:
    - `uhl_manager.sh`: Dynamically boots services based on `module_manifest.json`.
    - `module_manifest.json`: Configuration manifest for UHL daemons.
- **`builder/system/haf/`**:
    - `common_hal.sh`: Shared library for HAL mocking and retry logic.
    - `*_daemon.sh`: Modular services for Audio, Camera, Power, Sensors, and Input.
- **`builder/waydroid/`**:
    - `setup_container.sh`: Provisions dynamic LXC networking and IPC sandboxing.
    - `lxc-seccomp.conf`: Seccomp V2 policy for container confinement.

### 🧪 QA & Diagnostics (`builder/scripts/`)
- **`test-gpu-fallback.sh`**: Simulates GPU compositor crashes.
- **`test-hal-mocks.sh`**: Validates Selective HAL mocking logic.
- **`test-rollback.sh`**: Tests OverlayFS snapshot recovery.
- **`test-waydroid-isolation.sh`**: Verifies LXC network and IPC boundaries.
- **`aggregate-logs.sh`**: Compiles all telemetry into `MASTER_QA_REPORT` (HTML/JSON/CSV).

## 🛠️ Build & Installation

### Prerequisites

| Tool | Package | Required |
|------|---------|----------|
| `mksquashfs` | `squashfs-tools` | ✅ |
| `mkfs.ext4` | `e2fsprogs` | ✅ |
| `jq` | `jq` | ✅ |
| `wget` or `curl` | `wget` / `curl` | ✅ |
| `adb` | `android-tools-adb` | For flashing |
| `fastboot` | `android-tools-fastboot` | For flashing |
| `shellcheck` | `shellcheck` | For linting |

```bash
# Install all build dependencies (Ubuntu/Debian)
sudo apt install squashfs-tools e2fsprogs jq wget shellcheck
```

### Build

```bash
# Option A: Using Make (recommended)
make build

# Option B: Direct execution
./build.sh
```

### Configuration

Edit `config.env` to customize build parameters without modifying scripts:

| Variable | Default | Description |
|----------|---------|-------------|
| `ROOTFS_URL` | UBports Focal arm64 | Download URL for Ubuntu rootfs |
| `SQUASHFS_COMP` | `xz` | Compression: `xz`, `gzip`, `lzo`, `lz4`, `zstd` |
| `SYSTEM_IMG_SIZE_MB` | `512` | system.img size in MB |
| `ARCH` | `arm64` | Target architecture |

```bash
# Example: build with faster (but larger) compression
SQUASHFS_COMP=lz4 make build
```

### Deploy to Device

```bash
# Interactive installer (recommended)
make install

# Manual deployment
fastboot flash system builder/out/system.img
adb push builder/out/linux_rootfs.squashfs /data/
```

## 📈 QA & Debugging

All logs are aggregated in `/data/uhl_overlay/`.

- **Master Report:** `MASTER_QA_REPORT.html` (Visual summary)
- **JSON Data:** `MASTER_QA_REPORT.json` (For automated analysis)
- **Log Targets:**
    - `gpu_stage.log`: GPU detection and watchdog events.
    - `snapshot_rotation.log`: Snapshot creation and rotation events.
    - `hal.log`: Hardware discovery and retry metrics.
    - `waydroid_container*.log`: Per-container network and IPC maps.

## 🔄 Recovery & Rollback

If the system fails to boot, the framework detects a `rollback` file.
```bash
# Force a rollback to the previous stable snapshot on next boot
touch /data/uhl_overlay/rollback
```
Snapshots are automatically purged after 3 generations to prevent storage bloat.

## 🔧 Troubleshooting

| Problem | Solution |
|---------|----------|
| `mksquashfs: command not found` | `sudo apt install squashfs-tools` |
| `mkfs.ext4: command not found` | `sudo apt install e2fsprogs` |
| Build fails with permission error | Run `chmod +x build.sh scripts/*.sh` |
| Device not detected by `make install` | Enable USB debugging, check `adb devices` |
| System doesn't boot after flash | `adb shell touch /data/uhl_overlay/rollback && adb reboot` |
| GPU fails, black screen | System auto-falls back to LLVMpipe after 5s; check `gpu_stage.log` |
| HAL daemons won't start | Check `daemon.log` and verify `module_manifest.json` entries |

## Security Model

Five independent security layers protect the container:

| Layer | What It Blocks |
|-------|----------------|
| **Linux Namespaces** | Process/mount/network/IPC visibility |
| **Capability Drops** | Module loading, raw I/O, device creation |
| **Seccomp Filter** | `init_module`, `kexec_load`, `ptrace`, `bpf`, container escape syscalls |
| **SELinux MAC** | Unauthorized binder calls, vendor/filesystem access |
| **cgroup Device ACL** | All devices except `/dev/binder`, `/dev/null`, `/dev/urandom`, ptys |

See [threat_model.md](docs/threat_model.md) for detailed attack scenario analysis.

---

## What's Excluded (By Design)

| Component | Reason |
|-----------|--------|
| `hwservicemanager` | No HIDL transport |
| `vndservicemanager` | No vendor binder domain |
| Zygote / ART | No Android apps |
| SurfaceFlinger | No Android UI |
| `/vendor` mount | Treble isolation — HAL access via binder only |
| HIDL HALs | AIDL-only policy |

---

## Third-Party Components

This project depends on the following upstream components, integrated as git submodules under `third_party/`:

| Component | Repository | Version | License | Copyright |
|-----------|-----------|---------|---------|-----------| 
| **AOSP frameworks/native** | [googlesource.com](https://android.googlesource.com/platform/frameworks/native) | `android-16.0.0_r1` | Apache 2.0 | The Android Open Source Project |
| **AOSP system/core** | [googlesource.com](https://android.googlesource.com/platform/system/core) | `android-16.0.0_r1` | Apache 2.0 | The Android Open Source Project |
| **AOSP system/sepolicy** | [googlesource.com](https://android.googlesource.com/platform/system/sepolicy) | `android-16.0.0_r1` | Apache 2.0 | The Android Open Source Project |
| **LXC** | [github.com/lxc/lxc](https://github.com/lxc/lxc) | `v6.0.6` | LGPL-2.1+ | LXC contributors |
| **libseccomp** | [github.com/seccomp/libseccomp](https://github.com/seccomp/libseccomp) | `v2.6.0` | LGPL-2.1 | Paul Moore, Red Hat Inc. |

Upstream license files:
- AOSP: [Apache 2.0](https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/LICENSE)
- LXC: [LGPL-2.1+](https://github.com/lxc/lxc/blob/main/COPYING)
- libseccomp: [LGPL-2.1](https://github.com/seccomp/libseccomp/blob/main/LICENSE)

---

## License Compliance

### Apache License 2.0 (AOSP Components)

All AOSP-derived components (`frameworks/native`, `system/core`, `system/sepolicy`) are licensed under [Apache 2.0](http://www.apache.org/licenses/LICENSE-2.0).

**Obligations**:
- A copy of the license is included in [LICENSE](LICENSE)
- Attribution notices are consolidated in the [NOTICE](NOTICE) file
- Modified files carry prominent notices stating changes (per Section 4b)
- Source code is available via the submodule references

### LGPL-2.1 (LXC, libseccomp)

LXC and libseccomp are licensed under the [GNU Lesser General Public License v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).

**Obligations**:
- **Dynamic linking**: This project dynamically links against `liblxc.so` and `libseccomp.so`. Under LGPL-2.1, dynamically linked applications may be distributed under any license, provided the LGPL library source is available
- **Source availability**: Full source code is available via the git submodules under `third_party/lxc/` and `third_party/libseccomp/`
- **Static linking**: If statically linked, the combined work must be distributed under terms that permit modification and reverse engineering of the LGPL portions. Dynamic linking is the recommended approach and avoids this requirement
- **Modification disclosure**: Any modifications to LXC or libseccomp source must be clearly marked and source made available

### Ubuntu Packages

Ubuntu packages installed via `apt` inside the container carry their own individual licenses. Package licensing is diverse and includes GPL, LGPL, MIT, BSD, and others. Users are responsible for compliance with the licenses of any additional packages they install.

### Linux Kernel (GPL-2.0)

The Linux kernel used by the host device is licensed under GPL-2.0. This project does **not** modify or redistribute the kernel. Kernel modifications (if any) are the responsibility of the device vendor or user.

---

## Redistribution Restrictions

- **No vendor blobs**: This project does **not** include or redistribute any proprietary vendor binaries. The vendor partition is never accessed by the container.
- **No Google Mobile Services (GMS)**: Google Play Services, Play Store, and other GMS components are **not** included.
- **Ubuntu®** is a registered trademark of **Canonical Ltd**. Use of the Ubuntu name and logo is subject to Canonical's [trademark policy](https://ubuntu.com/legal/trademarks).
- **Android™** is a trademark of **Google LLC**. Use of the Android name is in compliance with Google's [brand guidelines](https://developer.android.com/distribute/marketing-tools/brand-guidelines).
- This project is **not** affiliated with, endorsed by, or sponsored by Google LLC, Canonical Ltd., or any device manufacturer.

---

## Attribution

```
Ubuntu GSI
Copyright (c) 2026 Ubuntu GSI Contributors

This project includes software developed by:

  The Android Open Source Project
  Copyright (C) 2006-2025 The Android Open Source Project
  Licensed under the Apache License, Version 2.0
  https://android.googlesource.com/

  LXC — Linux Containers
  Copyright (C) 2011-2024 LXC contributors
  Licensed under the GNU Lesser General Public License v2.1+
  https://linuxcontainers.org/

  libseccomp — Enhanced Seccomp (mode 2) Helper Library
  Copyright (C) 2012-2024 Paul Moore, Red Hat Inc.
  Licensed under the GNU Lesser General Public License v2.1
  https://github.com/seccomp/libseccomp

See NOTICE file for full attribution details.
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [boot_flow.md](docs/boot_flow.md) | Step-by-step boot sequence with diagrams |
| [threat_model.md](docs/threat_model.md) | Attack surfaces, mitigations, risk matrix |
| [selinux_policy.md](docs/selinux_policy.md) | SELinux rule reference with rationale |
| [system_layout.md](docs/system_layout.md) | Complete directory tree documentation |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Developer setup, conventions, and PR workflow |

---

## References / Inspiration

### Ubuntu Touch GSI Experimental Ideas

The concept of combining a Generic System Image with an Ubuntu-based rootfs to run Ubuntu on Treble-compliant Android devices was explored in an experimental project on the XDA Developers forum:

**[GSI [arm64][A/AB] Ubuntu Touch (ubports)](https://xdaforums.com/t/gsi-arm64-a-ab-ubuntu-touch-ubports.4110581/)**

Key ideas from that community discussion:

- **GSI + Ubuntu Touch rootfs**: The project demonstrated that a generic system image paired with an Ubuntu Touch rootfs could boot Ubuntu Touch via the Treble GSI mechanism, using the Halium compatibility layer for hardware access.
- **Vendor base requirements**: Successful boot required an Android 9 (Pie) vendor base and a Halium-patched kernel to provide the necessary hardware abstraction layer interfaces.
- **Feasibility proof**: While the project was experimental and appears to be no longer actively developed, it demonstrated that the fundamental approach of running a full Linux distribution on top of a Treble-compliant GSI is feasible.

This project idea was partially inspired by community exploration and experimentation from the XDA Developers forum linked above. Our approach differs in several ways — notably the use of LXC containers for isolation, AIDL-only binder IPC (no HIDL/Halium), multi-layer security hardening, and targeting modern Android 16 vendor images — but the core concept of a GSI-based Ubuntu system owes credit to that earlier community work.

---

## Updating Ubuntu

Ubuntu packages are updatable via `apt` without reflashing:

```bash
lxc-attach -n ubuntu -- bash -c "apt update && apt upgrade -y"
```

Changes persist in the OverlayFS upper layer (`/data/ubuntu/overlay/`). To clean-reset Ubuntu, simply delete the overlay directory.

---

## 📄 License
This framework is provided under the Apache License 2.0. See `LICENSE` for details.
