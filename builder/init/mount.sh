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

# Securely preserve Discovery states into the Systemd environment natively
cp /tmp/gpu_state "$MERGED/tmp/" 2>/dev/null
cp /tmp/binder_state "$MERGED/tmp/" 2>/dev/null

# Bind-mount Android RIL/modem sockets if available (for telephony HAL)
if [ -d /dev/socket ]; then
    mkdir -p "$MERGED/dev/socket"
    mount --bind /dev/socket "$MERGED/dev/socket"
    echo "[$(date -Iseconds)] [Master Pivot] Bound /dev/socket for RIL access." >> "$LOG_FILE"
fi

# Ensure vendor WiFi firmware is accessible from merged root
if [ -d /vendor/firmware ]; then
    mkdir -p "$MERGED/vendor/firmware"
    # Already bind-mounted via /vendor, but ensure path is accessible
    echo "[$(date -Iseconds)] [Master Pivot] Vendor firmware accessible via /vendor mount." >> "$LOG_FILE"
fi

if [ ! -x "$MERGED/lib/systemd/systemd" ]; then
     echo "[$(date -Iseconds)] [Master Pivot] FATAL: Pivot execution aborted. Systemd target corrupted." >> "$LOG_FILE"
     exit 1
fi

echo "[$(date -Iseconds)] [Master Pivot] Switching Root to systemd..." >> "$LOG_FILE"
exec switch_root "$MERGED" /lib/systemd/systemd --log-target=kmsg
