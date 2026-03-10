#!/bin/bash
# =============================================================================
# aidl/graphics/graphics_hal.sh — Graphics AIDL HAL Wrapper
# =============================================================================
# Manages GPU discovery, Mir compositor lifecycle, and the LLVMpipe watchdog.
# Bridges Mir/Wayland to Android vendor graphics via
# AIDL binder interface android.hardware.graphics.composer3.IComposer.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "graphics" "android.hardware.graphics.composer3.IComposer" "critical"

GPU_CACHE="/data/uhl_overlay/gpu_success.cache"

# ---------------------------------------------------------------------------
# GPU Detection
# ---------------------------------------------------------------------------
detect_gpu_mode() {
    # Check cached result first
    if [ -f "$GPU_CACHE" ]; then
        # shellcheck source=/dev/null
        source "$GPU_CACHE"
        hal_info "GPU cache hit: MODE=$MODE"
        return
    fi

    export LD_LIBRARY_PATH="/system/lib64:/vendor/lib64"

    # Try Vulkan/Zink first
    if ls /vendor/lib64/hw/vulkan.*.so 1>/dev/null 2>&1; then
        MODE="vulkan_zink"
        hal_info "Vulkan OEM driver detected → Zink pipeline"
    elif ls /vendor/lib64/egl/libGLES_*.so 1>/dev/null 2>&1 || \
         ls /vendor/lib64/libEGL_*.so 1>/dev/null 2>&1; then
        MODE="egl_hybris"
        hal_info "EGL OEM driver detected → libhybris pipeline"
    else
        MODE="llvmpipe"
        hal_info "No GPU drivers → LLVMpipe software rendering"
    fi
}

apply_gpu_env() {
    case "$MODE" in
        vulkan_zink)
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            export MIR_SERVER_GRAPHICS_PLATFORM=mesa
            ;;
        egl_hybris)
            export EGL_PLATFORM=hybris
            export MIR_SERVER_GRAPHICS_PLATFORM=android
            export LOMIRI_FORCE_FALLBACK_GLES=0
            ;;
        llvmpipe|*)
            export LIBGL_ALWAYS_SOFTWARE=1
            export GALLIUM_DRIVER=llvmpipe
            export MIR_SERVER_GRAPHICS_PLATFORM=mesa
            ;;
    esac
    hal_set_state "gpu_mode" "$MODE"
}

# ---------------------------------------------------------------------------
# Native handler — GPU compositor lifecycle
# ---------------------------------------------------------------------------
graphics_native() {
    detect_gpu_mode
    apply_gpu_env

    MAX_RETRIES=3
    CRASH_COUNT=0

    while [ $CRASH_COUNT -lt $MAX_RETRIES ]; do
        hal_info "Starting compositor (attempt $((CRASH_COUNT+1))/$MAX_RETRIES, mode=$MODE)"

        # Start Mir compositor (Lomiri will connect as a Wayland client)
        if command -v miral-app >/dev/null 2>&1; then
            miral-app --kiosk &
            COMP_PID=$!
        elif command -v mir_demo_server >/dev/null 2>&1; then
            mir_demo_server &
            COMP_PID=$!
        else
            hal_error "No Mir compositor binary found"
            exit 1
        fi

        # 5-second stabilization window
        sleep 5

        if kill -0 $COMP_PID 2>/dev/null; then
            hal_info "Compositor stabilized (PID $COMP_PID)"
            hal_set_state "status" "active"

            # Persist GPU cache on first success
            if [ ! -f "$GPU_CACHE" ]; then
                echo "MODE=$MODE" > "$GPU_CACHE"
                hal_info "GPU cache written: MODE=$MODE"
            fi

            wait $COMP_PID
            hal_info "Compositor exited normally"
            exit 0
        fi

        hal_error "Compositor crashed within 5s"
        CRASH_COUNT=$((CRASH_COUNT + 1))

        # Fall back to LLVMpipe on crash
        if [ "$MODE" != "llvmpipe" ]; then
            hal_warn "Falling back to LLVMpipe"
            MODE="llvmpipe"
            apply_gpu_env
            rm -f "$GPU_CACHE"
        fi
    done

    hal_error "Compositor failed after $MAX_RETRIES attempts"
    exit 1
}

# ---------------------------------------------------------------------------
# Mock handler — software-only rendering
# ---------------------------------------------------------------------------
graphics_mock() {
    MODE="llvmpipe"
    apply_gpu_env
    graphics_native  # Same logic, just starts in llvmpipe mode
}

aidl_hal_run graphics_native graphics_mock
