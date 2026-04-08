#!/bin/bash
# =============================================================================
# rootfs/overlay/usr/lib/ubuntu-gsi/firstboot.sh — First Boot Initialization
# =============================================================================
# Runs once on the very first boot of the Ubuntu GSI system.
# Creates default user, configures locale, sets up networking, and
# marks firstboot as complete.
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
# 0. Interactive userdata partition resize
# ---------------------------------------------------------------------------
log "Step 0: Userdata partition setup — interactive resize"

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
    TOTAL_BYTES=$(blockdev --getsize64 "$USERDATA_DEV" 2>/dev/null || echo 0)
    TOTAL_MB=$(( TOTAL_BYTES / 1024 / 1024 ))
    TOTAL_GB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_BYTES / 1073741824 }")

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Ubuntu GSI — System Partition Setup"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  Device        : $USERDATA_DEV"
    echo "  Total capacity: ${TOTAL_GB} GB  (${TOTAL_MB} MB)"
    echo ""
    echo "  Enter the size to allocate for the Ubuntu system partition."
    echo ""
    echo "  Formats:"
    echo "    20G        — fixed size in GiB"
    echo "    512M       — fixed size in MiB"
    echo "    50%        — percentage of total capacity"
    echo "    all        — use entire partition  (default)"
    echo "    skip       — keep current minimal size"
    echo ""
    printf "  Size [all]: "
    read -r PARTITION_INPUT

    PARTITION_INPUT="${PARTITION_INPUT:-all}"
    log "User input: '${PARTITION_INPUT}'"

    case "$PARTITION_INPUT" in
        skip)
            log "Resize skipped by user"
            ;;
        all|"")
            log "Expanding to full partition (resize2fs without size argument)..."
            if resize2fs "$USERDATA_DEV" >>"$LOG" 2>&1; then
                log "Userdata expanded to full partition successfully"
            else
                log "WARNING: resize2fs failed — continuing without resize"
            fi
            ;;
        *%)
            PCT="${PARTITION_INPUT%%%}"
            if [ "$PCT" -gt 0 ] && [ "$PCT" -le 100 ] 2>/dev/null; then
                DESIRED_MB=$(( TOTAL_MB * PCT / 100 ))
                log "Expanding to ${PCT}% → ${DESIRED_MB} MB..."
                if resize2fs "$USERDATA_DEV" "${DESIRED_MB}M" >>"$LOG" 2>&1; then
                    log "Userdata expanded to ${DESIRED_MB} MB (${PCT}%) successfully"
                else
                    log "WARNING: resize2fs failed — continuing without resize"
                fi
            else
                log "WARNING: Invalid percentage '${PARTITION_INPUT}' — skipping resize"
            fi
            ;;
        *)
            log "Expanding to ${PARTITION_INPUT}..."
            if resize2fs "$USERDATA_DEV" "$PARTITION_INPUT" >>"$LOG" 2>&1; then
                log "Userdata expanded to ${PARTITION_INPUT} successfully"
            else
                log "WARNING: resize2fs failed for size '${PARTITION_INPUT}' — continuing without resize"
            fi
            ;;
    esac
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
# 7. Mark complete
# ---------------------------------------------------------------------------
date -Iseconds > "$FIRSTBOOT_MARKER"
log "═══════════════════════════════════════════════════"
log "  First boot complete!"
log "  Default user: ubuntu / ubuntu"
log "  SSH is enabled. Change password on first login."
log "═══════════════════════════════════════════════════"
