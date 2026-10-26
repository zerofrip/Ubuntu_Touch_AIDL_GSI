#!/system/bin/sh
# =============================================================================
# device_prep_lomiri_gpu.sh — thin wrapper (deprecated entrypoint)
# =============================================================================
# Prefer /usr/lib/ubuntu-gsi/hal-gpu-bringup.sh lomiri_prep (shipped in system.img).
# This script remains for older run_chroot_lomiri.sh / adb push flows.
# =============================================================================

set -u
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:${PATH:-}"

GPU=""
for c in \
    /usr/lib/ubuntu-gsi/hal-gpu-bringup.sh \
    /mnt/halium/merged/usr/lib/ubuntu-gsi/hal-gpu-bringup.sh \
    /data/uhl_overlay/ubuntu-gsi-bin/hal-gpu-bringup.sh \
    /data/local/tmp/hal-gpu-bringup.sh; do
    if [ -x "$c" ]; then
        GPU="$c"
        break
    fi
done

if [ -z "$GPU" ]; then
    echo "device_prep_lomiri_gpu: hal-gpu-bringup.sh not found" >&2
    exit 1
fi

# Force re-prep when called explicitly from host tooling.
export HAL_GPU_FORCE="${HAL_GPU_FORCE:-1}"
exec "$GPU" lomiri_prep
