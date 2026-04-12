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
# 4-sensor. IIO sensor permissions and iio-sensor-proxy setup
# ---------------------------------------------------------------------------
log "Configuring IIO sensor permissions"

# Set IIO sysfs attributes readable
for iio_dev in /sys/bus/iio/devices/iio:device*; do
    [ -d "$iio_dev" ] || continue
    chmod -R a+r "$iio_dev" 2>/dev/null || true
done

# Set IIO character device permissions
for iio_cdev in /dev/iio:device*; do
    [ -c "$iio_cdev" ] || continue
    chmod 0666 "$iio_cdev" 2>/dev/null || true
done

# Add IIO udev rules for persistent sensor permissions
cat >> /etc/udev/rules.d/50-ubuntu-gsi-gpu.rules << 'IIOEOF'

# IIO sensor devices (light, proximity, accelerometer, gyro)
SUBSYSTEM=="iio", MODE="0666"
KERNEL=="iio:device*", MODE="0666"
IIOEOF
log "IIO sensor udev rules installed"

# Enable iio-sensor-proxy service (D-Bus sensor API)
if systemctl list-unit-files iio-sensor-proxy.service >/dev/null 2>&1; then
    systemctl enable iio-sensor-proxy.service 2>/dev/null || true
    log "iio-sensor-proxy.service enabled"
fi

# ---------------------------------------------------------------------------
# 4-bat. Battery / power supply setup
# ---------------------------------------------------------------------------
log "Configuring battery/power supply subsystem"

# Set battery sysfs permissions for upower access
for psu in /sys/class/power_supply/*; do
    [ -d "$psu" ] || continue
    chmod 0644 "$psu/capacity" 2>/dev/null || true
    chmod 0644 "$psu/status" 2>/dev/null || true
    chmod 0644 "$psu/type" 2>/dev/null || true
    chmod 0644 "$psu/online" 2>/dev/null || true
    chmod 0644 "$psu/voltage_now" 2>/dev/null || true
    chmod 0644 "$psu/current_now" 2>/dev/null || true
    chmod 0644 "$psu/temp" 2>/dev/null || true
    chmod 0644 "$psu/charge_full" 2>/dev/null || true
    chmod 0644 "$psu/charge_now" 2>/dev/null || true
    chmod 0644 "$psu/health" 2>/dev/null || true
    chmod 0644 "$psu/technology" 2>/dev/null || true
    log "Power supply permissions set: $(basename "$psu")"
done

# Add udev rules for power_supply subsystem
cat >> /etc/udev/rules.d/60-ubuntu-gsi-modem.rules << 'PSUEOF'

# Battery / power supply — allow upower to read battery attributes
SUBSYSTEM=="power_supply", MODE="0644"
PSUEOF

# Enable upower daemon
if systemctl list-unit-files upower.service >/dev/null 2>&1; then
    systemctl enable upower.service 2>/dev/null || true
    log "upower.service enabled"
fi

log "Battery/power supply subsystem configured"

# ---------------------------------------------------------------------------
# 4-stor. Storage subsystem setup
# ---------------------------------------------------------------------------
log "Configuring storage subsystem"

# Enable udisks2 for D-Bus storage management
if systemctl list-unit-files udisks2.service >/dev/null 2>&1; then
    systemctl enable udisks2.service 2>/dev/null || true
    log "udisks2.service enabled"
fi

# Add block device udev rules
cat >> /etc/udev/rules.d/60-ubuntu-gsi-modem.rules << 'STOREOF'

# Block devices — allow udisks2 to enumerate storage
SUBSYSTEM=="block", MODE="0660", GROUP="disk"
STOREOF

# Add ubuntu user to disk group for storage access
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG disk ubuntu 2>/dev/null || true
fi

log "Storage subsystem configured"

# ---------------------------------------------------------------------------
# 4-usb. USB gadget setup (MTP + RNDIS for PC connection)
# ---------------------------------------------------------------------------
log "Configuring USB gadget (MTP + RNDIS)"

if [ -f /usr/lib/ubuntu-gsi/usb-gadget.sh ]; then
    chmod +x /usr/lib/ubuntu-gsi/usb-gadget.sh
    systemctl enable usb-gadget.service 2>/dev/null || true
    log "usb-gadget.service enabled (MTP file transfer + RNDIS network)"
fi

# Add ubuntu user to plugdev group for USB device access
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG plugdev ubuntu 2>/dev/null || true
fi

log "USB gadget configured"

# ---------------------------------------------------------------------------
# 4-usb-otg. USB OTG (Host mode) setup
# ---------------------------------------------------------------------------
log "Configuring USB OTG (host mode)"

if [ -f /usr/lib/ubuntu-gsi/usb-otg.sh ]; then
    chmod +x /usr/lib/ubuntu-gsi/usb-otg.sh
    log "USB OTG role switch script installed"
fi

# Ensure input group exists and add ubuntu user for USB HID devices
if id -u ubuntu >/dev/null 2>&1; then
    groupadd -f input 2>/dev/null || true
    usermod -aG input ubuntu 2>/dev/null || true
    usermod -aG dialout ubuntu 2>/dev/null || true
fi

log "USB OTG configured (auto role switch via udev)"

# ---------------------------------------------------------------------------
# 4-rtc. Hardware clock (RTC) setup
# ---------------------------------------------------------------------------
log "Configuring hardware clock"

# Sync hardware clock to system on first boot
if [ -c /dev/rtc0 ]; then
    chmod 0644 /dev/rtc0 2>/dev/null || true
    hwclock --hctosys 2>/dev/null || true
    log "Hardware clock synced to system time"
fi

# Enable NTP time sync
if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    systemctl enable systemd-timesyncd.service 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
    log "NTP time synchronization enabled"
fi

log "Hardware clock configured"

# ---------------------------------------------------------------------------
# 4-gps. GPS/GNSS subsystem setup
# ---------------------------------------------------------------------------
log "Configuring GPS/GNSS subsystem"

# Set GNSS serial device permissions
for gnss_dev in /dev/ttyHS* /dev/ttyMSM* /dev/gnss* /dev/ttyUSB*; do
    [ -c "$gnss_dev" ] || continue
    chmod 0666 "$gnss_dev" 2>/dev/null || true
done

# Add GNSS udev rules
cat >> /etc/udev/rules.d/50-ubuntu-gsi-gpu.rules << 'GNSSEOF'

# GNSS/GPS serial devices
SUBSYSTEM=="tty", KERNEL=="ttyHS*", MODE="0666"
SUBSYSTEM=="tty", KERNEL=="ttyMSM*", MODE="0666"
SUBSYSTEM=="gnss", MODE="0666"
GNSSEOF

# Enable gpsd if installed
if systemctl list-unit-files gpsd.service >/dev/null 2>&1; then
    systemctl enable gpsd.service 2>/dev/null || true
    systemctl enable gpsd.socket 2>/dev/null || true
    log "gpsd.service enabled"
fi

# Enable geoclue for D-Bus location API
if systemctl list-unit-files geoclue.service >/dev/null 2>&1; then
    systemctl enable geoclue.service 2>/dev/null || true
    log "geoclue.service enabled"
fi

# Add ubuntu user to dialout group (for serial GPS access)
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG dialout ubuntu 2>/dev/null || true
fi
log "GPS subsystem configured"

# ---------------------------------------------------------------------------
# 4-bt. Bluetooth subsystem setup
# ---------------------------------------------------------------------------
log "Configuring Bluetooth subsystem"

# Unblock Bluetooth radio
if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock bluetooth 2>/dev/null || true
    log "rfkill: unblocked Bluetooth"
fi

# Symlink vendor Bluetooth firmware
for fw_dir in /vendor/firmware /vendor/firmware/bt /odm/firmware; do
    if [ -d "$fw_dir" ]; then
        for fw_file in "$fw_dir"/BCM*.hcd "$fw_dir"/bt_*.bin "$fw_dir"/*.btp \
                       "$fw_dir"/WCNSS*.bin "$fw_dir"/crc*.bin; do
            [ -f "$fw_file" ] || continue
            base=$(basename "$fw_file")
            [ -e "/lib/firmware/$base" ] || ln -sf "$fw_file" "/lib/firmware/$base" 2>/dev/null || true
        done
        log "Linked BT firmware from $fw_dir"
    fi
done

# Add ubuntu user to bluetooth group
if id -u ubuntu >/dev/null 2>&1; then
    usermod -aG bluetooth ubuntu 2>/dev/null || true
fi

# Enable BlueZ service
if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
    systemctl enable bluetooth.service 2>/dev/null || true
    log "bluetooth.service enabled"
fi
log "Bluetooth subsystem configured"

# ---------------------------------------------------------------------------
# 4-vibr. Vibrator device permissions
# ---------------------------------------------------------------------------
log "Configuring vibrator device permissions"

# Android timed_output vibrator
if [ -e /sys/class/timed_output/vibrator/enable ]; then
    chmod 0666 /sys/class/timed_output/vibrator/enable 2>/dev/null || true
    log "timed_output vibrator permissions set"
fi

# LED-class vibrator
for led in /sys/class/leds/vibrator /sys/class/leds/vibrator_0; do
    if [ -d "$led" ]; then
        chmod 0666 "$led/brightness" 2>/dev/null || true
        chmod 0666 "$led/activate" 2>/dev/null || true
        chmod 0666 "$led/duration" 2>/dev/null || true
        log "LED-class vibrator permissions set: $led"
    fi
done

# Add vibrator udev rules
cat >> /etc/udev/rules.d/50-ubuntu-gsi-gpu.rules << 'VIBREOF'

# Vibrator devices
SUBSYSTEM=="timed_output", MODE="0666"
SUBSYSTEM=="leds", KERNEL=="vibrator*", ATTR{brightness}="0", MODE="0666"
VIBREOF
log "Vibrator udev rules installed"

# ---------------------------------------------------------------------------
# 4-hall. Hall sensor (lid switch) udev rule
# ---------------------------------------------------------------------------
log "Configuring hall sensor (lid switch)"

cat >> /etc/udev/rules.d/50-ubuntu-gsi-gpu.rules << 'HALLEOF'

# Hall sensor (lid switch) — allow logind to see SW_LID events
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_SWITCH}=="1", TAG+="power-switch"
HALLEOF
log "Hall sensor udev rules installed"

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
# 4b2. Voice call / SMS application setup
# ---------------------------------------------------------------------------
log "Configuring voice call and SMS applications"

# Create modem device udev rules for persistent permissions
cat > /etc/udev/rules.d/60-ubuntu-gsi-modem.rules << 'MODEMEOF'
# Qualcomm QMI modem
SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", MODE="0660", GROUP="dialout"
KERNEL=="qmi*", MODE="0660", GROUP="dialout"
KERNEL=="cdc-wdm*", MODE="0660", GROUP="dialout"

# MediaTek CCCI modem
KERNEL=="ccci_*", MODE="0660", GROUP="dialout"
KERNEL=="eemcs_*", MODE="0660", GROUP="dialout"
KERNEL=="ttyMT*", MODE="0660", GROUP="dialout"

# Generic USB modems
KERNEL=="ttyACM*", MODE="0660", GROUP="dialout"
KERNEL=="ttyUSB*", MODE="0660", GROUP="dialout"

# Qualcomm SMD (shared memory driver)
KERNEL=="smd*", MODE="0660", GROUP="dialout"
MODEMEOF
log "Modem udev rules installed"

# Setup call history / SMS storage directory
if id -u ubuntu >/dev/null 2>&1; then
    mkdir -p /home/ubuntu/.local/share/calls
    mkdir -p /home/ubuntu/.local/share/chatty
    chown -R ubuntu:ubuntu /home/ubuntu/.local/share/calls 2>/dev/null || true
    chown -R ubuntu:ubuntu /home/ubuntu/.local/share/chatty 2>/dev/null || true
    log "Call history and SMS storage directories created"
fi

# Configure oFono voice call and SMS plugins
if [ -d /etc/ofono ]; then
    cat > /etc/ofono/phonesim.conf << 'OFONOEOF'
[Settings]
SetupRequired=false
OFONOEOF
    log "oFono configuration written"
fi

# Enable GNOME Calls autostart for incoming call notifications
if id -u ubuntu >/dev/null 2>&1; then
    mkdir -p /home/ubuntu/.config/autostart
    cat > /home/ubuntu/.config/autostart/gnome-calls.desktop << 'CALLSEOF'
[Desktop Entry]
Type=Application
Name=Phone
Exec=gnome-calls --daemon
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
CALLSEOF
    chown -R ubuntu:ubuntu /home/ubuntu/.config/autostart 2>/dev/null || true
    log "GNOME Calls autostart configured for incoming call notifications"
fi

# Enable Chatty (SMS) autostart
if id -u ubuntu >/dev/null 2>&1; then
    cat > /home/ubuntu/.config/autostart/chatty.desktop << 'CHATTYEOF'
[Desktop Entry]
Type=Application
Name=Messages
Exec=chatty --daemon
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
CHATTYEOF
    chown -R ubuntu:ubuntu /home/ubuntu/.config/autostart 2>/dev/null || true
    log "Chatty SMS autostart configured"
fi

# Enable feedbackd for call vibration/ringtone notifications
if systemctl list-unit-files feedbackd.service >/dev/null 2>&1; then
    systemctl enable feedbackd.service 2>/dev/null || true
    log "feedbackd.service enabled (haptic/ring notifications)"
fi

# Enable mmsd-tng for MMS support
if systemctl list-unit-files mmsd-tng.service >/dev/null 2>&1; then
    systemctl enable mmsd-tng.service 2>/dev/null || true
    log "mmsd-tng MMS service enabled"
fi

log "Voice call and SMS applications configured"

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
        for ctl in Master Speaker Headphone PCM Earpiece Receiver \
                   "Voice Call" Capture "Internal Mic" "Headset Mic"; do
            amixer -c "$card_num" -q set "$ctl" 80% unmute 2>/dev/null || true
        done
        log "ALSA card $card_num unmuted (incl. earpiece/voice/mic)"
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

# ---------------------------------------------------------------------------
# 4e. Screen brightness control
# ---------------------------------------------------------------------------
log "Configuring screen brightness control"

# Set backlight permissions so user can adjust brightness
for bl_dir in /sys/class/backlight/*; do
    [ -d "$bl_dir" ] || continue
    bl_name=$(basename "$bl_dir")
    # Create udev rule for backlight access
    cat > /etc/udev/rules.d/80-backlight.rules <<'BLEOF'
SUBSYSTEM=="backlight", ACTION=="add", RUN+="/bin/chmod 0666 /sys/class/backlight/%k/brightness"
BLEOF
    # Set permissions immediately
    chmod 0666 "$bl_dir/brightness" 2>/dev/null || true
    log "Backlight '$bl_name' permissions set"
    break
done

# ---------------------------------------------------------------------------
# 4f. Flashlight / Camera flash LED
# ---------------------------------------------------------------------------
log "Configuring flashlight/torch control"

# Install flashlight toggle script
if [ -f /usr/lib/ubuntu-gsi/scripts/flashlight/flashlight-toggle.sh ]; then
    chmod +x /usr/lib/ubuntu-gsi/scripts/flashlight/flashlight-toggle.sh
    ln -sf /usr/lib/ubuntu-gsi/scripts/flashlight/flashlight-toggle.sh /usr/local/bin/flashlight
    log "Flashlight toggle installed to /usr/local/bin/flashlight"
fi

# Set flash LED permissions
for flash_led in \
    /sys/class/leds/flashlight \
    /sys/class/leds/torch-light0 \
    /sys/class/leds/torch-light1 \
    /sys/class/leds/led:flash_0 \
    /sys/class/leds/led:torch_0 \
    /sys/class/leds/white:flash \
    /sys/class/leds/white:torch; do
    if [ -d "$flash_led" ]; then
        chmod 0666 "$flash_led/brightness" 2>/dev/null || true
        log "Flash LED permissions set: $(basename "$flash_led")"
    fi
done

# ---------------------------------------------------------------------------
# 4g. SD card auto-mount
# ---------------------------------------------------------------------------
log "Configuring SD card auto-mount"

mkdir -p /media/ubuntu/sdcard

# Udev rule for auto-mounting external SD card partitions
cat > /etc/udev/rules.d/81-sdcard-automount.rules <<'SDEOF'
# Auto-mount external SD card partitions
KERNEL=="mmcblk1p[0-9]*", SUBSYSTEM=="block", ACTION=="add", \
    RUN+="/bin/mkdir -p /media/ubuntu/sdcard/%k", \
    RUN+="/bin/mount -o rw,nosuid,nodev,noexec,uid=1000,gid=1000 /dev/%k /media/ubuntu/sdcard/%k"
KERNEL=="mmcblk1p[0-9]*", SUBSYSTEM=="block", ACTION=="remove", \
    RUN+="/bin/umount -l /media/ubuntu/sdcard/%k", \
    RUN+="/bin/rmdir /media/ubuntu/sdcard/%k"
# If SD card has no partition table, mount the whole device
KERNEL=="mmcblk1", SUBSYSTEM=="block", ACTION=="add", \
    ATTR{partition}!="?*", \
    RUN+="/bin/mkdir -p /media/ubuntu/sdcard/mmcblk1", \
    RUN+="/bin/mount -o rw,nosuid,nodev,noexec,uid=1000,gid=1000 /dev/%k /media/ubuntu/sdcard/mmcblk1"
SDEOF
log "SD card auto-mount udev rules installed"

# Mount any already-inserted SD card
for sdpart in /dev/mmcblk1p*; do
    [ -b "$sdpart" ] || continue
    part_name=$(basename "$sdpart")
    mkdir -p "/media/ubuntu/sdcard/$part_name"
    mount -o rw,nosuid,nodev,noexec,uid=1000,gid=1000 "$sdpart" "/media/ubuntu/sdcard/$part_name" 2>/dev/null || true
    log "Mounted existing SD partition: $part_name"
done

# ---------------------------------------------------------------------------
# 4h. Screen auto-rotation (iio-sensor-proxy)
# ---------------------------------------------------------------------------
log "Configuring screen auto-rotation"

# Enable iio-sensor-proxy for accelerometer-based rotation
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable iio-sensor-proxy.service 2>/dev/null || true
    log "iio-sensor-proxy enabled for auto-rotation"
fi

# ---------------------------------------------------------------------------
# 4h2. Biometric authentication (fingerprint / face)
# ---------------------------------------------------------------------------
log "Configuring biometric authentication"

# -- Fingerprint --
FP_DETECTED=0

# Detect fingerprint device (sysfs, /dev, vendor init.rc)
for fp_dev in /dev/fingerprint* /dev/goodix_fp /dev/fpc1020 /dev/silead_fp \
              /dev/elan_fp /dev/cdfinger /dev/sunwave_fp; do
    if [ -c "$fp_dev" ] || [ -e "$fp_dev" ]; then
        chmod 0660 "$fp_dev" 2>/dev/null || true
        chgrp input "$fp_dev" 2>/dev/null || true
        FP_DETECTED=1
        log "Fingerprint device found: $fp_dev"
        break
    fi
done

if [ "$FP_DETECTED" -eq 0 ]; then
    for rc_file in /vendor/etc/init/*.rc /odm/etc/init/*.rc; do
        [ -f "$rc_file" ] || continue
        if grep -qi "fingerprint" "$rc_file" 2>/dev/null; then
            FP_DETECTED=1
            log "Vendor fingerprint service detected in: $rc_file"
            break
        fi
    done
fi

# Udev rule for fingerprint devices
cat > /etc/udev/rules.d/80-fingerprint.rules <<'FPEOF'
# Fingerprint reader devices
KERNEL=="fingerprint*", MODE="0660", GROUP="input"
KERNEL=="goodix_fp", MODE="0660", GROUP="input"
KERNEL=="fpc1020", MODE="0660", GROUP="input"
KERNEL=="silead_fp", MODE="0660", GROUP="input"
KERNEL=="elan_fp", MODE="0660", GROUP="input"
KERNEL=="cdfinger", MODE="0660", GROUP="input"
KERNEL=="sunwave_fp", MODE="0660", GROUP="input"
FPEOF

if command -v fprintd >/dev/null 2>&1; then
    log "fprintd available — fingerprint enrollment ready"
    log "  Enroll: fprintd-enroll -f right-index-finger ubuntu"
    log "  Verify: fprintd-verify ubuntu"
else
    log "WARN: fprintd not installed — fingerprint auth unavailable"
fi

# -- Face authentication --
for rc_file in /vendor/etc/init/*.rc /odm/etc/init/*.rc; do
    [ -f "$rc_file" ] || continue
    if grep -qi "face.*auth\|biometric.*face" "$rc_file" 2>/dev/null; then
        log "Vendor face auth service detected in: $rc_file"
        break
    fi
done

if command -v howdy >/dev/null 2>&1; then
    log "Howdy available — face recognition ready"
    log "  Add face: sudo howdy add"
    log "  Test: sudo howdy test"
else
    log "WARN: howdy not installed — face auth unavailable"
fi

# -- PAM integration for biometrics --
if [ -f /etc/pam.d/common-auth ]; then
    PAM_MODIFIED=0

    # Add pam_fprintd (fingerprint) before pam_unix if available
    if compgen -G '/usr/lib/*/security/pam_fprintd.so' >/dev/null 2>&1 || compgen -G '/lib/*/security/pam_fprintd.so' >/dev/null 2>&1; then
        if ! grep -q "pam_fprintd" /etc/pam.d/common-auth 2>/dev/null; then
            sed -i '/^auth.*pam_unix\.so/i auth\tsufficient\tpam_fprintd.so' \
                /etc/pam.d/common-auth 2>/dev/null || true
            PAM_MODIFIED=1
            log "PAM: pam_fprintd added to common-auth"
        fi
    fi

    # Add pam_howdy (face) before fingerprint if available
    if compgen -G '/usr/lib/*/security/pam_howdy.so' >/dev/null 2>&1 || compgen -G '/lib/*/security/pam_howdy.so' >/dev/null 2>&1; then
        if ! grep -q "pam_howdy" /etc/pam.d/common-auth 2>/dev/null; then
            if grep -q "pam_fprintd" /etc/pam.d/common-auth 2>/dev/null; then
                sed -i '/pam_fprintd/i auth\tsufficient\tpam_howdy.so' \
                    /etc/pam.d/common-auth 2>/dev/null || true
            else
                sed -i '/^auth.*pam_unix\.so/i auth\tsufficient\tpam_howdy.so' \
                    /etc/pam.d/common-auth 2>/dev/null || true
            fi
            PAM_MODIFIED=1
            log "PAM: pam_howdy added to common-auth"
        fi
    fi

    if [ "$PAM_MODIFIED" -eq 1 ]; then
        log "PAM biometric auth chain: face → fingerprint → password"
    fi
fi

# Enable biometric HAL services
systemctl enable fingerprint-hal.service 2>/dev/null || true
systemctl enable face-hal.service 2>/dev/null || true
log "Biometric authentication configured"

# ---------------------------------------------------------------------------
# 4i. Lock screen / Greeter
# ---------------------------------------------------------------------------
log "Configuring lock screen"

# Lomiri uses its built-in greeter (--mode=full-greeter)
# Configure auto-lock timeout via gsettings
if command -v gsettings >/dev/null 2>&1; then
    # Set as ubuntu user
    su - ubuntu -c "
        gsettings set com.lomiri.touch.system activity-timeout 300 2>/dev/null || true
        gsettings set com.lomiri.touch.system auto-brightness false 2>/dev/null || true
    " 2>/dev/null || true
    log "Lomiri greeter auto-lock configured (300s)"
fi

# ---------------------------------------------------------------------------
# 4j. Notification LED control
# ---------------------------------------------------------------------------
log "Configuring notification LED"

# Detect notification LED (commonly rgb, indicator, or green/blue/red)
for led_pattern in \
    /sys/class/leds/red \
    /sys/class/leds/green \
    /sys/class/leds/blue \
    /sys/class/leds/white \
    /sys/class/leds/rgb \
    /sys/class/leds/indicator \
    /sys/class/leds/charging; do
    if [ -d "$led_pattern" ]; then
        chmod 0666 "$led_pattern/brightness" 2>/dev/null || true
        # Enable trigger access if available
        chmod 0666 "$led_pattern/trigger" 2>/dev/null || true
        log "Notification LED permissions: $(basename "$led_pattern")"
    fi
done

# Udev rule for persistent LED access
cat > /etc/udev/rules.d/82-notification-led.rules <<'LEDEOF'
SUBSYSTEM=="leds", ACTION=="add", RUN+="/bin/chmod 0666 /sys/class/leds/%k/brightness"
SUBSYSTEM=="leds", ACTION=="add", RUN+="/bin/chmod 0666 /sys/class/leds/%k/trigger"
LEDEOF
log "Notification LED udev rules installed"

# ---------------------------------------------------------------------------
# 4k. Screen timeout / DPMS
# ---------------------------------------------------------------------------
log "Configuring screen timeout"

# Create logind idle action configuration
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-screen-timeout.conf <<'DPMSEOF'
[Login]
# Screen off after 60 seconds idle
IdleAction=ignore
IdleActionSec=60s
DPMSEOF
log "Screen timeout: 60s idle configured"

# ---------------------------------------------------------------------------
# 4l. WiFi tethering / Hotspot
# ---------------------------------------------------------------------------
log "Configuring WiFi tethering"

# Create NetworkManager hotspot connection template
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/Hotspot.nmconnection <<'HOTEOF'
[connection]
id=Hotspot
type=wifi
autoconnect=false

[wifi]
mode=ap
ssid=UbuntuGSI-Hotspot

[wifi-security]
key-mgmt=wpa-psk
psk=ubuntu-gsi-hotspot

[ipv4]
method=shared

[ipv6]
method=ignore
HOTEOF
chmod 0600 /etc/NetworkManager/system-connections/Hotspot.nmconnection
log "WiFi tethering hotspot template created"

# ---------------------------------------------------------------------------
# 4m. VPN support (OpenVPN, WireGuard)
# ---------------------------------------------------------------------------
log "Configuring VPN support"

# Enable NetworkManager VPN plugins
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-vpn.conf <<'VPNEOF'
[main]
plugins+=keyfile

[keyfile]
unmanaged-devices=none
VPNEOF

# Ensure WireGuard kernel module loads
if [ -f /lib/modules/"$(uname -r)"/kernel/drivers/net/wireguard/wireguard.ko ]; then
    echo "wireguard" >> /etc/modules-load.d/ubuntu-gsi.conf
    log "WireGuard module auto-load configured"
fi
log "VPN support configured (OpenVPN + WireGuard)"

# ---------------------------------------------------------------------------
# 4n. Screenshot tool
# ---------------------------------------------------------------------------
log "Configuring screenshot tool"

# Create screenshot wrapper script
cat > /usr/local/bin/screenshot <<'SSEOF'
#!/bin/bash
# Ubuntu GSI Screenshot — captures to ~/Pictures/Screenshots
DEST="$HOME/Pictures/Screenshots"
mkdir -p "$DEST"
FILENAME="$DEST/screenshot_$(date +%Y%m%d_%H%M%S).png"
if command -v grim >/dev/null 2>&1; then
    grim "$FILENAME" && echo "Screenshot saved: $FILENAME"
elif command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot -f "$FILENAME"
else
    echo "No screenshot tool available"
    exit 1
fi
SSEOF
chmod +x /usr/local/bin/screenshot
mkdir -p /home/ubuntu/Pictures/Screenshots
chown -R ubuntu:ubuntu /home/ubuntu/Pictures
log "Screenshot tool installed (/usr/local/bin/screenshot)"

# ---------------------------------------------------------------------------
# 4o. Sound profiles (indicator-sound)
# ---------------------------------------------------------------------------
log "Configuring sound profiles"

# Set default sound indicators for Lomiri
if command -v gsettings >/dev/null 2>&1; then
    su - ubuntu -c "
        gsettings set com.lomiri.indicator.sound visible true 2>/dev/null || true
    " 2>/dev/null || true
fi
log "Sound profile indicator configured"

# ---------------------------------------------------------------------------
# 4p. Firefox Mobile Touch Configuration
# ---------------------------------------------------------------------------
log "Configuring Firefox for mobile/touch UI"

FIREFOX_PROFILE_DIR="/home/ubuntu/.mozilla/firefox"
if command -v firefox >/dev/null 2>&1; then
    mkdir -p "$FIREFOX_PROFILE_DIR/gsi.default"

    # Create profile ini
    cat > "$FIREFOX_PROFILE_DIR/profiles.ini" <<'FFPEOF'
[General]
StartWithLastProfile=1

[Profile0]
Name=default
IsRelative=1
Path=gsi.default
Default=1
FFPEOF

    # Mobile-friendly prefs: touch events, compact UI, mobile UA
    cat > "$FIREFOX_PROFILE_DIR/gsi.default/user.js" <<'FFEOF'
// Ubuntu GSI — Firefox Mobile/Touch Configuration
user_pref("dom.w3c_touch_events.enabled", 1);
user_pref("ui.touch.enabled", true);
user_pref("apz.allow_zooming", true);
user_pref("browser.gesture.pinch.in", "cmd_fullZoomReduce");
user_pref("browser.gesture.pinch.out", "cmd_fullZoomEnlarge");
user_pref("browser.chrome.dynamictoolbar", true);
user_pref("browser.display.show_image_placeholders", true);
user_pref("browser.tabs.drawInTitlebar", true);
user_pref("browser.uidensity", 2);
user_pref("browser.toolbars.bookmarks.visibility", "never");
user_pref("general.useragent.override", "Mozilla/5.0 (Linux; Android 14; Mobile) Gecko/128.0 Firefox/128.0");
user_pref("devtools.responsive.touchSimulation.enabled", true);
user_pref("layout.css.devPixelsPerPx", "-1.0");
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("toolkit.cosmeticAnimations.enabled", false);
FFEOF

    chown -R ubuntu:ubuntu "$FIREFOX_PROFILE_DIR"
    log "Firefox mobile touch profile created"
fi

# ---------------------------------------------------------------------------
# 4q. OpenStore — Click App Store Setup
# ---------------------------------------------------------------------------
log "Configuring OpenStore for click package installation"

if command -v openstore-client >/dev/null 2>&1; then
    # Create OpenStore cache directory for ubuntu user
    mkdir -p /home/ubuntu/.cache/open-store.io
    mkdir -p /home/ubuntu/.local/share/open-store.io
    chown -R ubuntu:ubuntu /home/ubuntu/.cache/open-store.io
    chown -R ubuntu:ubuntu /home/ubuntu/.local/share/open-store.io

    # Create desktop shortcut for OpenStore
    OPENSTORE_DESKTOP="/home/ubuntu/.local/share/applications/openstore-client.desktop"
    mkdir -p "$(dirname "$OPENSTORE_DESKTOP")"
    if [ ! -f "$OPENSTORE_DESKTOP" ] && [ -f /usr/share/applications/openstore-client.desktop ]; then
        cp /usr/share/applications/openstore-client.desktop "$OPENSTORE_DESKTOP"
    fi

    log "OpenStore client configured"
    log "Recommended apps available on OpenStore:"
    log "  - lomiri-calendar-app (カレンダー)"
    log "  - lomiri-gallery-app (ギャラリー)"
    log "  - lomiri-music-app (音楽)"
    log "  - lomiri-notes-app (メモ)"
    log "  - lomiri-weather-app (天気)"
    log "  - lomiri-terminal-app (ターミナル)"
    log "  - lomiri-docviewer-app (ドキュメント)"
    log "  - lomiri-mediaplayer-app (メディアプレイヤー)"
    log "  - lomiri-printing-app (印刷)"
else
    log "WARN: openstore-client not found — click apps unavailable"
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
