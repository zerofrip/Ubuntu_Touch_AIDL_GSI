#!/bin/bash
# =============================================================================
# rootfs/overlay/usr/lib/ubuntu-gsi/firstboot.sh — First Boot Initialization
# =============================================================================
# Runs once on the very first boot of the Ubuntu GSI system.
# Performs non-interactive system setup: partition resize, default user,
# locale, networking. User customization is deferred to the GUI Setup
# Wizard which launches after Lomiri starts.
# =============================================================================

set -euo pipefail

FIRSTBOOT_MARKER="/data/uhl_overlay/.firstboot_complete"
LOG="/data/uhl_overlay/firstboot.log"

log() { echo "[$(date -Iseconds)] [Firstboot] $1" | tee -a "$LOG"; }

# Skip if already completed
if [ -f "$FIRSTBOOT_MARKER" ]; then
    log "First boot already completed — skipping"
    exit 0
fi

log "═══════════════════════════════════════════════════"
log "  Ubuntu GSI — First Boot Initialization"
log "═══════════════════════════════════════════════════"

# ---------------------------------------------------------------------------
# 0. Automatic userdata partition resize (use entire partition)
# ---------------------------------------------------------------------------
log "Step 0: Userdata partition — automatic full resize"

# Locate the block device backing /data (most reliable: read from /proc/mounts)
USERDATA_DEV=$(awk '$2 == "/data" { print $1 }' /proc/mounts 2>/dev/null | head -1)

# Fallback: well-known Android by-name symlinks
if [ -z "$USERDATA_DEV" ]; then
    for _c in \
        /dev/block/bootdevice/by-name/userdata \
        /dev/block/by-name/userdata; do
        if [ -b "$_c" ]; then
            USERDATA_DEV="$_c"
            break
        fi
    done
fi

if [ -n "$USERDATA_DEV" ]; then
    log "Expanding userdata to full partition..."
    if resize2fs "$USERDATA_DEV" >>"$LOG" 2>&1; then
        log "Userdata expanded to full partition successfully"
    else
        log "WARNING: resize2fs failed — continuing without resize"
    fi
else
    log "WARNING: Could not locate userdata block device — skipping resize"
fi

# ---------------------------------------------------------------------------
# 1. Create default user
# ---------------------------------------------------------------------------
log "Creating default user: ubuntu"

if ! id -u ubuntu >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,audio,video,input,render ubuntu
    echo "ubuntu:ubuntu" | chpasswd
    log "User 'ubuntu' created (password: ubuntu)"
else
    log "User 'ubuntu' already exists"
fi

# Configure sudo without password (for initial setup)
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu-gsi
chmod 440 /etc/sudoers.d/ubuntu-gsi

# Create XDG runtime directory
mkdir -p /run/user/1000
chown ubuntu:ubuntu /run/user/1000
chmod 0700 /run/user/1000

# ---------------------------------------------------------------------------
# 2. Configure locale
# ---------------------------------------------------------------------------
log "Configuring locale"

if [ -f /etc/locale.gen ]; then
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen 2>/dev/null || true
fi

cat > /etc/default/locale << 'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

# ---------------------------------------------------------------------------
# 3. Configure timezone
# ---------------------------------------------------------------------------
log "Setting timezone to UTC (change with: timedatectl set-timezone)"

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

# ---------------------------------------------------------------------------
# 4. Configure networking
# ---------------------------------------------------------------------------
log "Configuring NetworkManager"

if command -v nmcli >/dev/null 2>&1; then
    systemctl enable NetworkManager 2>/dev/null || true
fi

# Enable SSH
if [ -f /etc/ssh/sshd_config ]; then
    systemctl enable ssh 2>/dev/null || true
    log "SSH server enabled"
fi

# ---------------------------------------------------------------------------
# 5. Mask incompatible systemd units
# ---------------------------------------------------------------------------
log "Masking incompatible systemd units"

for unit in \
    systemd-modules-load.service \
    systemd-udevd.service \
    systemd-udevd-kernel.socket \
    systemd-udevd-control.socket \
    modprobe@.service \
    SystemdJournal2Gelf.service \
; do
    systemctl mask "$unit" 2>/dev/null || true
done

log "Incompatible units masked"

# ---------------------------------------------------------------------------
# 6. Set graphical target
# ---------------------------------------------------------------------------
log "Setting default target to graphical"
systemctl set-default graphical.target 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Mark firstboot complete & flag GUI wizard
# ---------------------------------------------------------------------------
date -Iseconds > "$FIRSTBOOT_MARKER"

# Signal the GUI Setup Wizard to launch after Lomiri starts
touch /data/uhl_overlay/.setup_wizard_pending

log "═══════════════════════════════════════════════════"
log "  First boot complete!"
log "  GUI Setup Wizard will launch after Lomiri starts."
log "═══════════════════════════════════════════════════"
