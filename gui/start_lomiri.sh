#!/bin/bash
# =============================================================================
# gui/start_lomiri.sh — Lomiri Compositor Launcher
# =============================================================================
# Sets up the Wayland/Mir environment and launches Lomiri.
# Called by lomiri.service or manually.
#
# Usage:
#   start_lomiri.sh --setup     # Environment setup only (ExecStartPre)
#   start_lomiri.sh             # Full launch
# =============================================================================

set -euo pipefail

LOG="/data/uhl_overlay/lomiri.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date -Iseconds)] [Lomiri] $1" >> "$LOG"; }

# ---------------------------------------------------------------------------
# GPU Environment (read from AIDL graphics HAL state)
# ---------------------------------------------------------------------------
setup_gpu_env() {
    local gpu_mode
    gpu_mode=$(cat /run/ubuntu-gsi/hal/graphics.gpu_mode 2>/dev/null || echo "llvmpipe")

    case "$gpu_mode" in
        vulkan_zink)
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            export MIR_SERVER_GRAPHICS_PLATFORM=mesa
            log "GPU: Vulkan/Zink"
            ;;
        egl_hybris)
            export EGL_PLATFORM=hybris
            export MIR_SERVER_GRAPHICS_PLATFORM=android
            log "GPU: EGL/libhybris"
            ;;
        *)
            export LIBGL_ALWAYS_SOFTWARE=1
            export GALLIUM_DRIVER=llvmpipe
            export MIR_SERVER_GRAPHICS_PLATFORM=mesa
            log "GPU: LLVMpipe (software)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Wayland/XDG Setup
# ---------------------------------------------------------------------------
setup_wayland_env() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=Lomiri
    export QT_QPA_PLATFORM=wayland
    export GDK_BACKEND=wayland
    export CLUTTER_BACKEND=wayland
    export SDL_VIDEODRIVER=wayland

    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"

    log "Wayland env configured (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR)"
}

# ---------------------------------------------------------------------------
# Input / Touchscreen Environment for Mir
# ---------------------------------------------------------------------------
setup_input_env() {
    # Mir uses libinput by default — ensure it can find devices
    export MIR_SERVER_CONSOLE_PROVIDER=auto

    # libinput requires /dev/input access — verify
    if [ -d /dev/input ]; then
        local ts_count=0
        for event_dev in /dev/input/event*; do
            [ -c "$event_dev" ] || continue
            ts_count=$((ts_count + 1))
        done
        log "Input: $ts_count event device(s) available"
    else
        log "WARNING: /dev/input not available — touch input may not work"
    fi

    # Set LIBINPUT_QUIRKS_DIR for Android vendor touchscreen quirks
    if [ -d /etc/libinput ]; then
        export LIBINPUT_QUIRKS_DIR=/etc/libinput
        log "Input: libinput quirks dir set"
    fi
}

# ---------------------------------------------------------------------------
# D-Bus Session Bus
# ---------------------------------------------------------------------------
setup_dbus() {
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        if command -v dbus-daemon >/dev/null 2>&1; then
            eval "$(dbus-launch --sh-syntax)" 2>/dev/null || true
            log "D-Bus session started: $DBUS_SESSION_BUS_ADDRESS"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
setup_gpu_env
setup_wayland_env
setup_input_env

case "${1:-}" in
    --setup)
        # Setup only — called by ExecStartPre
        setup_dbus
        log "Environment setup complete"
        exit 0
        ;;
    *)
        # Full launch
        setup_dbus

        log "Starting Lomiri compositor"
        if command -v lomiri >/dev/null 2>&1; then
            exec lomiri --mode=full-greeter 2>> "$LOG"
        else
            log "FATAL: lomiri binary not found"
            log "Install with: sudo bash /usr/lib/ubuntu-gsi/gui/install_lomiri.sh"
            exit 1
        fi
        ;;
esac
