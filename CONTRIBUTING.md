# Contributing to Ubuntu Touch AIDL GSI

Thank you for your interest in contributing! This document covers setup,
conventions, and workflow for this Halium-style AIDL GSI repository.

## Prerequisites

| Tool | Package | Purpose |
|------|---------|---------|
| `mkfs.erofs` | `erofs-utils` | Rootfs pack |
| `mkfs.ext4` / `mkfs.f2fs` | `e2fsprogs`, `f2fs-tools` | system/userdata images |
| `debootstrap` | `debootstrap` | Ubuntu rootfs bootstrap |
| `qemu-aarch64-static` | `qemu-user-static` | Cross-arch rootfs build |
| `jq` | `jq` | JSON / quirks tooling |
| `shellcheck` | `shellcheck` | Shell script linting |
| `fastboot` | `android-tools-fastboot` | Device flash |
| `git` | `git` | Version control |

```bash
sudo apt install \
  debootstrap qemu-user-static e2fsprogs erofs-utils f2fs-tools \
  jq wget unzip shellcheck \
  android-sdk-libsparse-utils android-tools-fastboot python3
```

## Quick Setup

```bash
git clone --recursive https://github.com/zerofrip/Ubuntu_Touch_AIDL_GSI.git
cd Ubuntu_Touch_AIDL_GSI

# Pick the vendor Android major matching the device
git checkout android-16.0   # or android-12.0 … android-15.0

make build-minimal
```

`main` is **documentation-only** and does not build release images.

## Branch Strategy

| Branch | Role |
|--------|------|
| `android-12.0` … `android-16.0` | Release / build branches (vendor GSI mapping in `vendor/*.env`) |
| `main` | Docs and shared meta only |

Open feature PRs against the matching `android-*` base, not `main`.

## Project Layout

```
Ubuntu_Touch_AIDL_GSI/
├── build.sh                 # Master build orchestrator
├── config.env               # Build knobs
├── Makefile                 # Convenience targets
├── vendor/                  # Per-version PHH/TrebleDroid mapping
├── halium/                  # Launcher, init rc, compat engine, Lomiri start
├── rootfs/                  # Package lists, overlay, systemd units
├── scripts/                 # Host-side build / flash / probe tooling
├── docs/                    # Architecture and flash documentation
└── deprecated/              # Historical pre-Halium components
```

## Development Workflow

1. Branch from the target `android-*` line (or an open feature branch based on it).
2. Make focused changes; keep feature commits split when possible.
3. Lint shell scripts (CI runs ShellCheck with `--severity=warning`):
   ```bash
   find . -name '*.sh' \
     -not -path './third_party/*' \
     -not -path './builder/out/*' \
     -not -path './builder/cache/*' \
     -not -path './deprecated/*' \
     -print0 | xargs -0 shellcheck --severity=warning
   ```
4. Build when touching packaging: `make build-minimal`.
5. Open a PR against the corresponding `android-*` branch.

CI: `.github/workflows/build.yml` (android-* push/PR), `.github/workflows/lint.yml` (`main`).

## Code Conventions

### Shell Scripts

- Use `#!/bin/bash` (or `#!/bin/sh` only where required).
- Prefer `set -euo pipefail` for host-side scripts.
- Use `$(command)` instead of backticks.
- Resolve paths from `BASH_SOURCE` — do not hardcode machine-specific absolute paths.
- Include a short header comment describing purpose.

### Commit Messages

```
type(scope): short description

Optional longer body explaining the reasoning.
```

Types: `feat`, `fix`, `docs`, `ci`, `refactor`, `test`, `chore`.

## Documentation

When changing flash behavior, launcher seed paths, or vbmeta handling, update:

- `README.md`
- `docs/flash_quickstart.md`
- `docs/boot_flow.md` / `docs/system_layout.md` / `docs/architecture.md`
- `docs/halium-architecture.md` (authoritative design)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
