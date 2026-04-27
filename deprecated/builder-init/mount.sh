#!/bin/sh
# =============================================================================
# mount.sh (Final Master OverlayFS Pivot Framework with Multi-Snapshot)
# =============================================================================

set -e

LOG_FILE="/data/uhl_overlay/rollback.log"
SNAP_LOG="/data/uhl_overlay/snapshot_rotation.log"
mkdir -p /data/uhl_overlay
touch "$LOG_FILE" "$SNAP_LOG"
echo "[$(date -Iseconds)] [Master Pivot] Assembling Dynamic Userdata Bindings..." >> "$LOG_FILE"

mkdir -p /data
mount -t ext4 /dev/block/bootdevice/by-name/userdata /data 2>/dev/null || true

BASE="/rootfs/ubuntu-base"
UPPER="/data/uhl_overlay/upper"
WORK="/data/uhl_overlay/work"
MERGED="/rootfs/merged"

mkdir -p "$BASE" "$UPPER" "$WORK" "$MERGED"

# =============================================================================
# Multi-Generation Snapshot Rotation & Rollback Mechanics
# =============================================================================

SNAPSHOT_1="/data/uhl_overlay/snapshot.1"
SNAPSHOT_2="/data/uhl_overlay/snapshot.2"
SNAPSHOT_3="/data/uhl_overlay/snapshot.3"

if [ -f "/data/uhl_overlay/rollback" ]; then
    echo "[$(date -Iseconds)] [Master Pivot] FATAL BREAKAGE DETECTED (Rollback Request Found)." >> "$LOG_FILE"
    echo "[$(date -Iseconds)] [Snapshot Audit] Executing Generation 1 Reversion natively." >> "$SNAP_LOG"
    
    if [ -d "$SNAPSHOT_1" ]; then
        echo "[$(date -Iseconds)] [Master Pivot] Restoring Generation 1 Snapshot..." >> "$LOG_FILE"
        rm -rf "$UPPER" "$WORK"
        cp -a "$SNAPSHOT_1" "$UPPER"
        mkdir -p "$WORK"
        rm -f "/data/uhl_overlay/rollback"
        echo "[$(date -Iseconds)] [Master Pivot] Rollback SUCCESS." >> "$LOG_FILE"
        echo "[$(date -Iseconds)] [Snapshot Audit] Rollback Execution Finished. System reverted." >> "$SNAP_LOG"
    else
        echo "[$(date -Iseconds)] [Master Pivot] ERROR: No Snapshots exist to rollback!" >> "$LOG_FILE"
        echo "[$(date -Iseconds)] [Snapshot Audit] FATAL: System attempted rollback but no bounds existed." >> "$SNAP_LOG"
    fi
else
    # Rotate existing snapshots seamlessly before booting
    echo "[$(date -Iseconds)] [Master Pivot] Archiving current Upper boundary into Snapshot Generations..." >> "$LOG_FILE"
    
    # Garbage Collection: Explicitly prevent storage bloat natively deleting past 3
    if [ -d "$SNAPSHOT_3" ]; then
         echo "[$(date -Iseconds)] [Snapshot Audit] Garbage Collection: Purging older Generation > 3 cleanly." >> "$SNAP_LOG"
         rm -rf "$SNAPSHOT_3"
    fi
    
    [ -d "$SNAPSHOT_2" ] && mv "$SNAPSHOT_2" "$SNAPSHOT_3" && echo "[$(date -Iseconds)] [Snapshot Audit] Rotated Gen 2 -> 3." >> "$SNAP_LOG"
    [ -d "$SNAPSHOT_1" ] && mv "$SNAPSHOT_1" "$SNAPSHOT_2" && echo "[$(date -Iseconds)] [Snapshot Audit] Rotated Gen 1 -> 2." >> "$SNAP_LOG"
    
    cp -a "$UPPER" "$SNAPSHOT_1"
    echo "[$(date -Iseconds)] [Snapshot Audit] Captured current stable OS into Generation 1." >> "$SNAP_LOG"
    echo "[$(date -Iseconds)] [Master Pivot] Snapshot Rotation Complete." >> "$LOG_FILE"
fi

# =============================================================================
# OverlayFS Assembly and Mount Validation
# =============================================================================

echo "[$(date -Iseconds)] [Master Pivot] Creating Read-Write Root Bounds..." >> "$LOG_FILE"
if [ -f "/data/linux_rootfs.squashfs" ]; then
    mount -t squashfs -o loop /data/linux_rootfs.squashfs "$BASE"
else
    echo "[$(date -Iseconds)] [Master Pivot] FATAL: System Squashfs topology missing!" >> "$LOG_FILE"
    exit 1
fi

mount -t overlay overlay -o lowerdir="$BASE",upperdir="$UPPER",workdir="$WORK" "$MERGED"

# Explicit Mountpoint Validation Check
if ! mountpoint -q "$MERGED"; then
    echo "[$(date -Iseconds)] [Master Pivot] FATAL: OverlayFS failed to map natively. Halting pivot!" >> "$LOG_FILE"
    exit 1
fi

echo "[$(date -Iseconds)] [Master Pivot] OverlayFS Validation Passed." >> "$LOG_FILE"
mkdir -p "$MERGED/vendor" "$MERGED/dev/binderfs" "$MERGED/tmp" "$MERGED/data/uhl_overlay"
mount --bind /vendor "$MERGED/vendor"
mount --bind /dev/binderfs "$MERGED/dev/binderfs"

# Bind-mount /data for userdata partition visibility (storage info)
if [ -d /data ]; then
    mkdir -p "$MERGED/data"
    mount --bind /data "$MERGED/data"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /data for storage access." >> "$LOG_FILE"
fi

# Bind-mount /dev/block for block device discovery (udisks2, lsblk)
if [ -d /dev/block ]; then
    mkdir -p "$MERGED/dev/block"
    mount --bind /dev/block "$MERGED/dev/block"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/block for storage discovery." >> "$LOG_FILE"
fi

# Bind-mount /sys/block for partition/disk info (udisks2, df)
if [ -d /sys/block ]; then
    mkdir -p "$MERGED/sys/block"
    mount --bind /sys/block "$MERGED/sys/block"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /sys/block for disk info." >> "$LOG_FILE"
fi

# Bind-mount /dev/rtc for hardware clock access
for rtc_dev in /dev/rtc /dev/rtc0; do
    if [ -c "$rtc_dev" ]; then
        rtc_name=$(basename "$rtc_dev")
        touch "$MERGED/dev/$rtc_name" 2>/dev/null
        mount --bind "$rtc_dev" "$MERGED/dev/$rtc_name"
        echo "[$(date -Iseconds)] [Master Pivot] Bound $rtc_dev for hardware clock." >> "$LOG_FILE"
    fi
done

# Bind-mount /sys/class/rtc for RTC sysfs interface
if [ -d /sys/class/rtc ]; then
    mkdir -p "$MERGED/sys/class/rtc"
    mount --bind /sys/class/rtc "$MERGED/sys/class/rtc"
fi

# Securely preserve Discovery states into the Systemd environment natively
cp /tmp/gpu_state "$MERGED/tmp/" 2>/dev/null
cp /tmp/binder_state "$MERGED/tmp/" 2>/dev/null

# Bind-mount Android RIL/modem sockets if available (for telephony HAL)
if [ -d /dev/socket ]; then
    mkdir -p "$MERGED/dev/socket"
    mount --bind /dev/socket "$MERGED/dev/socket"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/socket for RIL access." >> "$LOG_FILE"
fi

# Bind-mount modem/radio device nodes for telephony (QMI, MBIM, MediaTek CCCI)
modem_bound=0
for modem_dev in /dev/qmi* /dev/cdc-wdm* /dev/ttyMT* /dev/ccci_* /dev/eemcs_*; do
    [ -c "$modem_dev" ] || continue
    modem_name=$(basename "$modem_dev")
    touch "$MERGED/dev/$modem_name" 2>/dev/null
    mount --bind "$modem_dev" "$MERGED/dev/$modem_name"
    modem_bound=$((modem_bound + 1))
done
if [ "$modem_bound" -gt 0 ]; then
    echo "[$(date -Iseconds)] [Master Pivot] Bound $modem_bound modem device(s) for telephony." >> "$LOG_FILE"
fi

# Bind-mount /dev/smd* for Qualcomm shared memory driver (voice/data)
for smd_dev in /dev/smd*; do
    [ -c "$smd_dev" ] || continue
    smd_name=$(basename "$smd_dev")
    touch "$MERGED/dev/$smd_name" 2>/dev/null
    mount --bind "$smd_dev" "$MERGED/dev/$smd_name"
done

# Bind-mount /sys/class/net for modem network interface visibility
if [ -d /sys/class/net ]; then
    mkdir -p "$MERGED/sys/class/net"
    mount --bind /sys/class/net "$MERGED/sys/class/net"
fi

# Bind-mount /dev/input for touchscreen and input device access
if [ -d /dev/input ]; then
    mkdir -p "$MERGED/dev/input"
    mount --bind /dev/input "$MERGED/dev/input"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/input for touchscreen/input access." >> "$LOG_FILE"
fi

# Bind-mount /dev/dri for GPU/DRM access (hardware-accelerated rendering)
if [ -d /dev/dri ]; then
    mkdir -p "$MERGED/dev/dri"
    mount --bind /dev/dri "$MERGED/dev/dri"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/dri for GPU/DRM access." >> "$LOG_FILE"
fi

# Bind-mount /dev/fb0 for framebuffer fallback (legacy display path)
if [ -c /dev/fb0 ]; then
    touch "$MERGED/dev/fb0" 2>/dev/null
    mount --bind /dev/fb0 "$MERGED/dev/fb0"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/fb0 for framebuffer access." >> "$LOG_FILE"
fi

# Bind-mount /dev/graphics for Android HWC/gralloc access
if [ -d /dev/graphics ]; then
    mkdir -p "$MERGED/dev/graphics"
    mount --bind /dev/graphics "$MERGED/dev/graphics"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/graphics for HWC access." >> "$LOG_FILE"
fi

# Bind-mount /dev/video* for camera device access (V4L2)
cam_bound=0
for cam_dev in /dev/video*; do
    [ -c "$cam_dev" ] || continue
    cam_name=$(basename "$cam_dev")
    touch "$MERGED/dev/$cam_name" 2>/dev/null
    mount --bind "$cam_dev" "$MERGED/dev/$cam_name"
    cam_bound=$((cam_bound + 1))
done
if [ "$cam_bound" -gt 0 ]; then
    echo "[$(date -Iseconds)] [Master Pivot] Bound $cam_bound V4L2 camera devices." >> "$LOG_FILE"
fi

# Bind-mount /dev/media* for media controller access (camera pipelines)
for media_dev in /dev/media*; do
    [ -c "$media_dev" ] || continue
    media_name=$(basename "$media_dev")
    touch "$MERGED/dev/$media_name" 2>/dev/null
    mount --bind "$media_dev" "$MERGED/dev/$media_name"
done

# Ensure vendor WiFi firmware is accessible from merged root
if [ -d /vendor/firmware ]; then
    mkdir -p "$MERGED/vendor/firmware"
    # Already bind-mounted via /vendor, but ensure path is accessible
    echo "[$(date -Iseconds)] [Master Pivot] Vendor firmware accessible via /vendor mount." >> "$LOG_FILE"
fi

# Bind-mount /sys/class/power_supply for battery status/capacity
if [ -d /sys/class/power_supply ]; then
    mkdir -p "$MERGED/sys/class/power_supply"
    mount --bind /sys/class/power_supply "$MERGED/sys/class/power_supply"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /sys/class/power_supply for battery access." >> "$LOG_FILE"
fi

# Bind-mount /sys/bus/iio for IIO sensor access (light, proximity, accel, etc.)
if [ -d /sys/bus/iio/devices ]; then
    mkdir -p "$MERGED/sys/bus/iio"
    mount --bind /sys/bus/iio "$MERGED/sys/bus/iio"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /sys/bus/iio for sensor access." >> "$LOG_FILE"
fi

# Bind-mount /dev/iio:device* for IIO raw data access
for iio_dev in /dev/iio:device*; do
    [ -c "$iio_dev" ] || continue
    iio_name=$(basename "$iio_dev")
    touch "$MERGED/dev/$iio_name" 2>/dev/null
    mount --bind "$iio_dev" "$MERGED/dev/$iio_name"
done

# Bind-mount GNSS/GPS serial devices
for gnss_dev in /dev/ttyHS* /dev/ttyMSM* /dev/gnss* /dev/ttyUSB*; do
    [ -c "$gnss_dev" ] || continue
    gnss_name=$(basename "$gnss_dev")
    touch "$MERGED/dev/$gnss_name" 2>/dev/null
    mount --bind "$gnss_dev" "$MERGED/dev/$gnss_name"
    echo "[$(date -Iseconds)] [Master Pivot] Bound $gnss_dev for GNSS access." >> "$LOG_FILE"
done

# Bind-mount /dev/uhid for Bluetooth HID device support
if [ -c /dev/uhid ]; then
    touch "$MERGED/dev/uhid" 2>/dev/null
    mount --bind /dev/uhid "$MERGED/dev/uhid"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/uhid for Bluetooth HID." >> "$LOG_FILE"
fi

# Bind-mount /sys/class/timed_output for vibrator (Android sysfs)
if [ -d /sys/class/timed_output ]; then
    mkdir -p "$MERGED/sys/class/timed_output"
    mount --bind /sys/class/timed_output "$MERGED/sys/class/timed_output"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /sys/class/timed_output for vibrator." >> "$LOG_FILE"
fi

# Bind-mount /sys/class/leds for LED-class vibrator and indicator LEDs
if [ -d /sys/class/leds ]; then
    mkdir -p "$MERGED/sys/class/leds"
    mount --bind /sys/class/leds "$MERGED/sys/class/leds"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /sys/class/leds for vibrator/LEDs." >> "$LOG_FILE"
fi

# Bind-mount /sys/class/backlight for screen brightness control
if [ -d /sys/class/backlight ]; then
    mkdir -p "$MERGED/sys/class/backlight"
    mount --bind /sys/class/backlight "$MERGED/sys/class/backlight"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /sys/class/backlight for brightness." >> "$LOG_FILE"
fi

# Bind-mount SD card (external MMC) block devices
for mmcblk in /dev/mmcblk1 /dev/mmcblk1p*; do
    if [ -b "$mmcblk" ]; then
        mmcblk_name=$(basename "$mmcblk")
        touch "$MERGED/dev/$mmcblk_name" 2>/dev/null || true
        mount --bind "$mmcblk" "$MERGED/dev/$mmcblk_name"
    fi
done
if [ -b /dev/mmcblk1 ]; then
    echo "[$(date -Iseconds)] [Master Pivot] Bound SD card block devices." >> "$LOG_FILE"
fi

# Bind-mount /sys/class/mmc_host for MMC/SD detection
if [ -d /sys/class/mmc_host ]; then
    mkdir -p "$MERGED/sys/class/mmc_host"
    mount --bind /sys/class/mmc_host "$MERGED/sys/class/mmc_host"
fi

if [ ! -x "$MERGED/lib/systemd/systemd" ]; then
     echo "[$(date -Iseconds)] [Master Pivot] FATAL: Pivot execution aborted. Systemd target corrupted." >> "$LOG_FILE"
     exit 1
fi

echo "[$(date -Iseconds)] [Master Pivot] Switching Root to systemd..." >> "$LOG_FILE"
exec switch_root "$MERGED" /lib/systemd/systemd --log-target=kmsg
