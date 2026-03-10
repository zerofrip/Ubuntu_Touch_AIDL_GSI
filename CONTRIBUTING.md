# Contributing to Ubuntu GSI

Thank you for your interest in contributing! This document covers the setup, conventions, and workflow for development.

## Prerequisites

| Tool | Package | Purpose |
|------|---------|---------|
| `mksquashfs` | `squashfs-tools` | RootFS compression |
| `mkfs.ext4` | `e2fsprogs` | system.img creation |
| `jq` | `jq` | JSON manifest parsing |
| `git` | `git` | Version control |
| `shellcheck` | `shellcheck` | Shell script linting |

Install all at once:

```bash
sudo apt install squashfs-tools e2fsprogs jq git shellcheck
```

## Quick Setup

```bash
git clone --recursive https://github.com/zerofrip/Ubuntu_GSI.git
cd Ubuntu_GSI

# Validate environment
make check

# Build (downloads rootfs if not present)
make build
```

## Project Layout

```
Ubuntu_GSI/
├── build.sh                    # Master build orchestrator
├── config.env                  # Build configuration knobs
├── Makefile                    # Convenience targets
├── scripts/                    # Host-side tooling
│   ├── check_environment.sh    # Dependency validator
│   └── install.sh              # Device flash helper
├── builder/
│   ├── init/                   # Android init sequence
│   ├── scripts/                # On-device runtime scripts
│   ├── system/                 # Subsystems (UHL, HAF, GPU)
│   └── waydroid/               # LXC container setup
├── docs/                       # Architecture documentation
└── third_party/                # Git submodules (AOSP, LXC, libseccomp)
```

## Development Workflow

1. **Create a branch** from `main`:
   ```bash
   git checkout -b feature/my-improvement
   ```

2. **Make changes** — follow the conventions below.

3. **Lint before committing**:
   ```bash
   make lint
   ```

4. **Test the build**:
   ```bash
   make build
   ```

5. **Submit a PR** against `main`. The CI pipeline will run ShellCheck and a dry-run build automatically.

## Code Conventions

### Shell Scripts

- Use `#!/bin/bash` (or `#!/bin/sh` for init scripts).
- Always `set -e` (fail on error). Prefer `set -euo pipefail` for host-side scripts.
- Use `$(command)` instead of backticks.
- Auto-detect paths relative to `BASH_SOURCE` — **never hardcode absolute paths**.
- Include a header comment block explaining the script's purpose.
- Log with ISO 8601 timestamps: `echo "[$(date -Iseconds)] [Component] Message"`.

### JSON Configuration

- Validate with `jq` before committing.
- Use descriptive keys (`name`, `binary`, `critical`).

### Commit Messages

Follow conventional format:

```
type(scope): short description

Optional longer body explaining the reasoning.
```

Types: `feat`, `fix`, `docs`, `ci`, `refactor`, `test`, `chore`.

Examples:
- `feat(hal): add bluetooth daemon support`
- `fix(build): remove hardcoded workspace path`
- `docs(readme): add troubleshooting section`

## Adding a New HAL Daemon

1. Create `builder/system/haf/<name>_daemon.sh` following the existing pattern.
2. Register it in `builder/system/uhl/module_manifest.json`.
3. Add the corresponding pipe name to the `SERVICES` array in `builder/system/uhl/uhl_manager.sh`.

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
