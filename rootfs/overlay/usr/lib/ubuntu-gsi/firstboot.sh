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

# ---------------------------------------------------------------------------
# 4-gpu. GPU/DRM device permissions
# ---------------------------------------------------------------------------
log "Configuring GPU/DRM device permissions"

# Ensure render group exists and ubuntu user belongs to it
if ! getent group render >/dev/null 2>&1; then
    groupadd -r render 2>/dev/null || true
fi
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG render,video ubuntu 2>/dev/null || true
fi

# Set DRM device permissions
if [ -d /dev/dri ]; then
    for dri_dev in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$dri_dev" ] || continue
        chmod 0666 "$dri_dev" 2>/dev/null || true
    done
    log "DRM device permissions set"
fi

# Create udev rule for persistent DRM permissions
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/50-ubuntu-gsi-gpu.rules << 'GPUEOF'
# DRM render nodes — accessible by render group
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"

# Framebuffer
SUBSYSTEM=="graphics", KERNEL=="fb*", MODE="0666"
GPUEOF
log "GPU udev rules installed"

# ---------------------------------------------------------------------------
# 4-cam. Camera device permissions
# ---------------------------------------------------------------------------
log "Configuring camera device permissions"

# Set V4L2 and media controller device permissions
for cam_dev in /dev/video* /dev/media*; do
    [ -e "$cam_dev" ] || continue
    chmod 0666 "$cam_dev" 2>/dev/null || true
done

# Add camera udev rules for persistent permissions
cat >> /etc/udev/rules.d/50-ubuntu-gsi-gpu.rules << 'CAMEOF'

# V4L2 camera devices
SUBSYSTEM=="video4linux", MODE="0666"

# Media controller devices (camera pipelines)
SUBSYSTEM=="media", MODE="0666"
CAMEOF
log "Camera udev rules installed"

# ---------------------------------------------------------------------------
# 4a. WiFi subsystem setup
# ---------------------------------------------------------------------------
log "Configuring WiFi subsystem"

# Unblock WiFi radios (some vendors ship with soft-block)
if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock all 2>/dev/null || true
    log "rfkill: unblocked WiFi radios"
fi

# Symlink vendor WiFi firmware into Linux firmware search path
for fw_dir in \
    /vendor/firmware/wlan \
    /vendor/firmware \
    /vendor/etc/wifi \
    /odm/firmware \
    /odm/etc/wifi; do
    if [ -d "$fw_dir" ]; then
        mkdir -p /lib/firmware/vendor
        for fw_file in "$fw_dir"/*; do
            [ -f "$fw_file" ] || continue
            base=$(basename "$fw_file")
            [ -e "/lib/firmware/$base" ] || ln -sf "$fw_file" "/lib/firmware/$base" 2>/dev/null || true
        done
        log "Linked vendor WiFi firmware from $fw_dir"
    fi
done

# Generate base wpa_supplicant config if missing
if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    mkdir -p /etc/wpa_supplicant
    cat > /etc/wpa_supplicant/wpa_supplicant.conf << 'WPAEOF'
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
p2p_disabled=1
WPAEOF
    log "Generated default wpa_supplicant.conf"
fi

# Configure NetworkManager WiFi backend
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi.conf << 'NMWIFI'
[device]
wifi.scan-rand-mac-address=no
wifi.backend=wpa_supplicant

[connectivity]
enabled=true
NMWIFI

# Set regulatory domain from vendor if available
if [ -f /vendor/build.prop ]; then
    REGDOMAIN=$(grep "ro.boot.wificountrycode" /vendor/build.prop 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    if [ -n "$REGDOMAIN" ] && command -v iw >/dev/null 2>&1; then
        echo "REGDOMAIN=$REGDOMAIN" > /etc/default/crda 2>/dev/null || true
        log "WiFi regulatory domain: $REGDOMAIN"
    fi
fi

log "WiFi subsystem configured"

# ---------------------------------------------------------------------------
# 4b. Telephony/modem setup
# ---------------------------------------------------------------------------
log "Configuring telephony subsystem"

# Enable oFono or ModemManager
if command -v ofonod >/dev/null 2>&1; then
    systemctl enable ofono 2>/dev/null || true
    log "oFono telephony service enabled"
fi

if command -v ModemManager >/dev/null 2>&1; then
    systemctl enable ModemManager 2>/dev/null || true
    log "ModemManager service enabled"
fi

# Unblock WWAN radios
if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wwan 2>/dev/null || true
    log "rfkill: unblocked WWAN radios"
fi

# Set modem device permissions
for dev in /dev/cdc-wdm* /dev/ttyACM* /dev/ttyUSB* /dev/ttyMT* /dev/ccci_* /dev/eemcs_*; do
    [ -e "$dev" ] && chmod 0660 "$dev" 2>/dev/null || true
done

# Add ubuntu user to dialout group for modem access
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG dialout ubuntu 2>/dev/null || true
fi

# Configure NetworkManager for mobile broadband
cat > /etc/NetworkManager/conf.d/modem.conf << 'NMMODEM'
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=none
NMMODEM

log "Telephony subsystem configured"

# ---------------------------------------------------------------------------
# 4c. Input/Touchscreen setup
# ---------------------------------------------------------------------------
log "Configuring input/touchscreen subsystem"

# Ensure input device nodes have correct permissions
if [ -d /dev/input ]; then
    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue
        chmod 0660 "$event_dev" 2>/dev/null || true
        chgrp input "$event_dev" 2>/dev/null || true
    done
    log "Input device permissions set (group=input, mode=0660)"
fi

# Create libinput quirks for Android vendor touchscreens
mkdir -p /etc/libinput
cat > /etc/libinput/90-ubuntu-gsi-touch.quirks << 'QUIRKSEOF'
[Ubuntu GSI Touchscreen Defaults]
MatchUdevType=touchscreen
AttrPalmSizeThreshold=0
AttrPalmPressureThreshold=0
AttrThumbPressureThreshold=0
QUIRKSEOF
log "libinput touchscreen quirks installed"

# Enable the input HAL service
if [ -f /etc/systemd/system/input-hal.service ] || [ -f /lib/systemd/system/input-hal.service ]; then
    systemctl enable input-hal.service 2>/dev/null || true
    log "Input HAL service enabled"
fi

log "Input/touchscreen subsystem configured"

# ---------------------------------------------------------------------------
# 4d. Audio/Speaker setup
# ---------------------------------------------------------------------------
log "Configuring audio subsystem"

# Add ubuntu user to audio group (should be set at useradd, but ensure)
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG audio,pulse,pulse-access ubuntu 2>/dev/null || true
fi

# Unmute ALSA controls on all detected cards
if command -v amixer >/dev/null 2>&1; then
    card_num=0
    while [ -d "/proc/asound/card${card_num}" ]; do
        for ctl in Master Speaker Headphone PCM; do
            amixer -c "$card_num" -q set "$ctl" 80% unmute 2>/dev/null || true
        done
        log "ALSA card $card_num unmuted"
        card_num=$((card_num + 1))
    done
fi

# Configure PulseAudio for system-wide mode (needed for GSI environment)
mkdir -p /etc/pulse
if [ -f /etc/pulse/system.pa ]; then
    # Ensure ALSA modules are loaded
    if ! grep -q "module-alsa-card" /etc/pulse/system.pa 2>/dev/null; then
        cat >> /etc/pulse/system.pa << 'PULSEEOF'

### Ubuntu GSI — Auto-detect ALSA cards
load-module module-udev-detect
load-module module-native-protocol-unix auth-anonymous=1
PULSEEOF
        log "PulseAudio system.pa updated with ALSA auto-detect"
    fi
fi

# Enable volume key daemon
if [ -f /etc/systemd/system/volume-key-daemon.service ] || [ -f /lib/systemd/system/volume-key-daemon.service ]; then
    systemctl enable volume-key-daemon.service 2>/dev/null || true
    log "Volume key daemon enabled"
fi

log "Audio subsystem configured"

# Enable SSH
if [ -f /etc/ssh/sshd_config ]; then
    systemctl enable ssh 2>/dev/null || true
    log "SSH server enabled"
fi

# ---------------------------------------------------------------------------
# 5. Mask incompatible systemd units
# ---------------------------------------------------------------------------
log "Masking incompatible systemd units"

# NOTE: systemd-udevd is NOT masked — it is required for input device
# detection (/dev/input/event* nodes, touchscreen udev rules).
for unit in \
    systemd-modules-load.service \
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
