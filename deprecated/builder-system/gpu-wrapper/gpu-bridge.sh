#!/bin/bash
# =============================================================================
# gpu-bridge.sh (Final Master GPU Translation Matrix & Watchdog Limits & Cache)
# =============================================================================
# Evaluates Vulkan/EGL routing precisely suppressing hardware failures.
# Contains a strict 5-second Watchdog trap that logs compositor deaths.
# Generates a `gpu_success.cache` after 5 seconds speeding up subsequent boots.
# =============================================================================

LOG_FILE="/data/uhl_overlay/gpu_stage.log"
STATS_FILE="/data/uhl_overlay/gpu_stats.log"
CACHE_FILE="/data/uhl_overlay/gpu_success.cache"
mkdir -p /data/uhl_overlay
touch "$LOG_FILE" "$STATS_FILE"

echo "[$(date -Iseconds)] [Master GPU Matrix] Evaluating Hardware State..." >> "$LOG_FILE"

STATE_FILE="/tmp/gpu_state"
# shellcheck source=/dev/null
source "$STATE_FILE" 2>/dev/null || MODE="UNKNOWN"

export LD_LIBRARY_PATH="/system/lib64:/vendor/lib64"

apply_vulkan_zink() {
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export GALLIUM_DRIVER=zink
    export MIR_SERVER_GRAPHICS_PLATFORM=mesa
}

apply_egl_hybris() {
    export EGL_PLATFORM=hybris
    export MIR_SERVER_GRAPHICS_PLATFORM=android
    export LOMIRI_FORCE_FALLBACK_GLES=0
}

apply_cpu_llvmpipe() {
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
    export MIR_SERVER_GRAPHICS_PLATFORM=mesa
}

case "$MODE" in
    "VULKAN_ZINK_READY") apply_vulkan_zink ;;
    "EGL_HYBRIS_READY") apply_egl_hybris ;;
    *) apply_cpu_llvmpipe ;;
esac

# =============================================================================
# The Ultimate GUI Watchdog & Cache Tracking
# =============================================================================

MAX_RETRIES=3
CRASH_COUNT=0

while [ $CRASH_COUNT -lt $MAX_RETRIES ]; do
    echo "[$(date -Iseconds)] [Master GPU Matrix] Spinning up Compositor (Attempt $((CRASH_COUNT+1))/$MAX_RETRIES)..." >> "$LOG_FILE"
    
    /usr/bin/miral-app -kiosk "$@" &
    COMP_PID=$!
    
    # 5-second critical stabilization window
    sleep 5
    
    if kill -0 $COMP_PID 2>/dev/null; then
        echo "[$(date -Iseconds)] [Master GPU Matrix] SUCCESS: Hardware Acceleration stabilized after 5 seconds." >> "$LOG_FILE"
        echo "[$(date -Iseconds)] [GPU Stats] FINAL BOUNDS: Wayland active natively via UID $COMP_PID. Fallbacks triggered: $CRASH_COUNT" >> "$STATS_FILE"
        
        if [ "$MODE" != "UNKNOWN" ] && [ ! -f "$CACHE_FILE" ]; then
            echo "[$(date -Iseconds)] [Master GPU Matrix] Persisting validated Graphics cache ($MODE) locally protecting boots!" >> "$LOG_FILE"
            echo "MODE=$MODE" > "$CACHE_FILE"
        fi

        wait $COMP_PID
        exit 0
    fi
    
    echo "[$(date -Iseconds)] [Master GPU Matrix] FATAL: Hardware Acceleration crashed (miral-app died unexpectedly)!" >> "$LOG_FILE"
    CRASH_COUNT=$((CRASH_COUNT + 1))
    
    # Destroy Corrupt Caches natively!
    rm -f "$CACHE_FILE"
    
    if [ "$MODE" != "UNKNOWN" ]; then
        echo "[$(date -Iseconds)] [Master GPU Matrix] >> Watchdog Triggered. Emptied caches mapping LLVMPIPE organically..." >> "$LOG_FILE"
        apply_cpu_llvmpipe
        MODE="UNKNOWN" 
    fi
done

echo "[$(date -Iseconds)] [Master GPU Matrix] FATAL LIMIT: Exceeded $MAX_RETRIES continuous composer crashes! Halting execution." >> "$LOG_FILE"
echo "[$(date -Iseconds)] [GPU Stats] FATAL BOUNDS: Wayland permanently failed bounding $MAX_RETRIES attempts. Display aborted completely." >> "$STATS_FILE"
exit 1
