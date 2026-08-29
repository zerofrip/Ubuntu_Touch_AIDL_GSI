#!/bin/bash
# =============================================================================
# scripts/verify_lomiri_rootfs.sh — Diagnose + provision rootfs + enable launcher
# =============================================================================
# Usage (device booted into nested Ubuntu GSI, adb available):
#   bash scripts/verify_lomiri_rootfs.sh              # diagnose only
#   bash scripts/verify_lomiri_rootfs.sh --provision   # push erofs + enable + reboot
#   bash scripts/verify_lomiri_rootfs.sh --check       # post-reboot verification
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EROFS="${ROOTFS_EROFS_HOST:-$REPO_ROOT/builder/out/linux_rootfs.erofs}"
MODE="${1:-diagnose}"

su0() { adb shell "su 0 $*" ; }

diag() {
    echo "=== Device ==="
    adb devices
    echo "=== Props ==="
    echo -n "sys.boot_completed="; adb shell getprop sys.boot_completed
    echo -n "persist.ubuntu_gsi.enable="; adb shell getprop persist.ubuntu_gsi.enable
    echo -n "persist.ubuntu_gsi.failed="; adb shell getprop persist.ubuntu_gsi.failed
    echo -n "init.svc.ubuntu-gsi-launcher="; adb shell getprop init.svc.ubuntu-gsi-launcher
    echo "=== /data/ubuntu-gsi ==="
    su0 "ls -la /data/ubuntu-gsi 2>&1" || true
    echo "=== /system/usr/share/ubuntu-gsi ==="
    su0 "ls -la /system/usr/share/ubuntu-gsi 2>&1" || true
    echo "=== launcher logcat (last 50) ==="
    su0 "logcat -d -s ubuntu-gsi-launcher 2>&1" | tail -50 || true
    echo "=== host erofs ==="
    ls -la "$EROFS" 2>&1 || echo "MISSING $EROFS"
}

provision() {
    [ -f "$EROFS" ] || { echo "Missing $EROFS — build rootfs first"; exit 1; }
    adb devices | grep -qE '\tdevice$' || { echo "No adb device"; exit 1; }
    echo "Provisioning $EROFS → /data/ubuntu-gsi/rootfs.erofs"
    su0 "mkdir -p /data/ubuntu-gsi /data/uhl_overlay/upper /data/uhl_overlay/work"
    # push to sdcard then move (adb push as root can be flaky)
    adb push "$EROFS" /sdcard/rootfs.erofs
    su0 "cp /sdcard/rootfs.erofs /data/ubuntu-gsi/rootfs.erofs"
    su0 "cp /data/ubuntu-gsi/rootfs.erofs /data/ubuntu-gsi/rootfs.erofs.bak"
    su0 "sh -c 'cd /data/ubuntu-gsi && (sha256sum rootfs.erofs 2>/dev/null || toybox sha256sum rootfs.erofs) > rootfs.erofs.sha256'"
    su0 "rm -f /sdcard/rootfs.erofs"
    su0 "ls -la /data/ubuntu-gsi"
    su0 "setprop persist.ubuntu_gsi.failed 0"
    su0 "setprop persist.ubuntu_gsi.enable 1"
    echo "enable=$(adb shell getprop persist.ubuntu_gsi.enable) failed=$(adb shell getprop persist.ubuntu_gsi.failed)"
    echo "Rebooting..."
    adb reboot
}

check() {
    echo "Waiting for boot_completed..."
    for i in $(seq 1 90); do
        if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
            break
        fi
        sleep 2
    done
    echo "boot_completed=$(adb shell getprop sys.boot_completed | tr -d '\r')"
    echo "enable=$(adb shell getprop persist.ubuntu_gsi.enable | tr -d '\r')"
    echo "failed=$(adb shell getprop persist.ubuntu_gsi.failed | tr -d '\r')"
    echo "svc=$(adb shell getprop init.svc.ubuntu-gsi-launcher | tr -d '\r')"
    echo "=== launcher logcat ==="
    su0 "logcat -d -s ubuntu-gsi-launcher 2>&1" | tail -80 || true
    echo "=== mounts ==="
    su0 "mount 2>&1" | grep -E 'halium|erofs|overlay' || true
    echo "=== lomiri hints ==="
    su0 "pidof lomiri 2>&1; pidof systemd 2>&1; ls /mnt/halium/merged/usr/bin/lomiri 2>&1" || true
}

CHROOT="${CHROOT:-/mnt/halium/merged}"

# Build HYBRIS_LD on-device (no SoC hardcode). Echo path only.
device_hybris_path() {
    su0 'sh -c "
base=/vendor/lib64/egl:/vendor/lib64/hw:/system_real/lib64:/system_real/lib64/hw
for d in /vendor/lib64/*; do
  [ -d \"\$d\" ] || continue
  b=\$(basename \"\$d\")
  case \"\$b\" in egl|hw) continue ;; esac
  ls \"\$d\"/libGLES*.so \"\$d\"/libEGL*.so \"\$d\"/hwcomposer.*.so \"\$d\"/gralloc.*.so >/dev/null 2>&1 || continue
  base=\${base}:\$d
done
for extra in /apex/com.android.vndk.v34/lib64 /apex/com.android.vndk.v33/lib64 /apex/com.android.vndk.v32/lib64 /apex/com.android.runtime/lib64/bionic; do
  [ -d \"\$extra\" ] || continue
  base=\${base}:\$extra
done
echo \"\$base\"
"' | tr -d '\r'
}

check_gpu() {
    check
    echo ""
    echo "=== GPU / libhybris checks ==="
    HYBRIS_PATH="$(device_hybris_path)"
    echo "HYBRIS_LD_LIBRARY_PATH=$HYBRIS_PATH"
    echo "--- libsync / gralloc in chroot ---"
    su0 "ls -la $CHROOT/usr/lib/aarch64-linux-gnu/libsync.so* 2>&1" || true
    su0 "ls -la $CHROOT/usr/lib/aarch64-linux-gnu/libgralloc.so* 2>&1" || true
    echo "--- Mir platform modules ---"
    su0 "ls $CHROOT/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android*.so* 2>&1" || true
    echo "--- test_egl ---"
    su0 "chroot $CHROOT sh -c 'export HYBRIS_LD_LIBRARY_PATH=$HYBRIS_PATH; /usr/lib/aarch64-linux-gnu/libhybris/test_egl' 2>&1" || true
    echo "test_egl_exit=$?"
    echo "--- test_hwcomposer ---"
    su0 "chroot $CHROOT sh -c 'export HYBRIS_LD_LIBRARY_PATH=$HYBRIS_PATH; /usr/lib/aarch64-linux-gnu/libhybris/test_hwcomposer' 2>&1" || true
    echo "test_hwcomposer_exit=$?"
    echo "--- Mir logcat ---"
    su0 "logcat -d -s Mir 2>&1" | tail -40 || true
    echo "--- lomiri process (10s poll) ---"
    for i in $(seq 1 5); do
        pid=$(adb shell "su 0 pidof lomiri 2>/dev/null" | tr -d '\r' || true)
        echo "t=${i}s pidof lomiri=${pid:-empty}"
        [ -n "$pid" ] && break
        sleep 2
    done
    failed=$(adb shell getprop persist.ubuntu_gsi.failed 2>/dev/null | tr -d '\r')
    if [ -z "${pid:-}" ]; then
        echo "WARN: lomiri not running yet — check Mir/libhybris logs above"
    else
        echo "OK: lomiri pid=$pid"
    fi
    if [ "$failed" = "1" ]; then
        echo "FAIL: persist.ubuntu_gsi.failed=1"
        exit 1
    fi
}

case "$MODE" in
    diagnose|--diagnose|"") diag ;;
    --provision|provision) provision ;;
    --check|check) check ;;
    --check-gpu|check-gpu) check_gpu ;;
    --check-apt|check-apt)
        bash "$SCRIPT_DIR/check_chroot_apt.sh"
        ;;
    *)
        echo "Usage: $0 [--diagnose|--provision|--check|--check-gpu|--check-apt]"
        exit 1
        ;;
esac


