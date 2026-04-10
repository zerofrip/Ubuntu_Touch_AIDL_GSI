#!/bin/bash
# =============================================================================
# aidl/audio/audio_hal.sh — Audio AIDL HAL Wrapper
# =============================================================================
# Bridges PulseAudio/PipeWire to Android vendor audio HAL via
# AIDL binder interface android.hardware.audio.core.IModule.
#
# Audio output priority:
#   1. PulseAudio + module-droid-card (vendor HAL via binder)
#   2. PulseAudio + ALSA (direct kernel ALSA driver)
#   3. PipeWire (if installed)
#   4. PulseAudio + null-sink (silent fallback)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "audio" "android.hardware.audio.core.IModule" "optional"

# ---------------------------------------------------------------------------
# ALSA device detection
# ---------------------------------------------------------------------------
detect_alsa_cards() {
    local card_count=0
    if [ -f /proc/asound/cards ]; then
        card_count=$(grep -c '^\s*[0-9]' /proc/asound/cards 2>/dev/null || echo "0")
        while IFS= read -r line; do
            hal_info "ALSA card: $line"
        done < <(grep '^\s*[0-9]' /proc/asound/cards 2>/dev/null)
    fi
    echo "$card_count"
}

unmute_alsa_controls() {
    # Unmute and set reasonable volume on all detected ALSA cards
    if ! command -v amixer >/dev/null 2>&1; then
        return
    fi

    local card_num=0
    while [ -d "/proc/asound/card${card_num}" ]; do
        # Unmute common controls
        for ctl in Master Speaker Headphone PCM "Speaker Playback" "Headphone Playback"; do
            amixer -c "$card_num" -q set "$ctl" 80% unmute 2>/dev/null || true
        done
        hal_info "ALSA card $card_num: controls unmuted"
        card_num=$((card_num + 1))
    done
}

start_pulseaudio_alsa() {
    # Start PulseAudio with ALSA auto-detection (no droid module needed)
    pulseaudio -D \
        --system \
        --disallow-exit \
        --log-target=file:/data/uhl_overlay/pulse.log \
        2>/dev/null &
    hal_info "PulseAudio started with ALSA auto-detection (PID $!)"
}

# ---------------------------------------------------------------------------
# Native handler — vendor audio HAL available
# ---------------------------------------------------------------------------
audio_native() {
    hal_info "Mapping PulseAudio → vendor audio HAL"

    export PULSE_SERVER=unix:/tmp/pulseaudio.socket
    export PULSE_RUNTIME_PATH=/run/pulse
    mkdir -p /run/pulse

    # Unmute ALSA controls regardless of path
    unmute_alsa_controls

    local started=false

    # Priority 1: PulseAudio + module-droid-card
    if command -v pulseaudio >/dev/null 2>&1; then
        # Check if module-droid-card is available
        if pulseaudio --dump-modules 2>/dev/null | grep -q "module-droid-card"; then
            pulseaudio -D \
                --system \
                --disallow-exit \
                --disallow-module-loading \
                --load="module-droid-card" \
                --log-target=file:/data/uhl_overlay/pulse.log \
                2>/dev/null &
            hal_info "PulseAudio started with module-droid-card (PID $!)"
            started=true
        else
            hal_warn "module-droid-card not available — falling back to ALSA"
        fi
    fi

    # Priority 2: PulseAudio + ALSA
    if [ "$started" = false ] && command -v pulseaudio >/dev/null 2>&1; then
        local alsa_cards
        alsa_cards=$(detect_alsa_cards)
        if [ "$alsa_cards" -gt 0 ]; then
            start_pulseaudio_alsa
            started=true
        fi
    fi

    # Priority 3: PipeWire
    if [ "$started" = false ] && command -v pipewire >/dev/null 2>&1; then
        pipewire &
        hal_info "PipeWire started (PID $!)"
        started=true
    fi

    # Priority 4: PulseAudio null-sink
    if [ "$started" = false ] && command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio -D \
            --system \
            --disallow-exit \
            --load="module-null-sink" \
            2>/dev/null &
        hal_info "PulseAudio started with null-sink (silent fallback)"
        started=true
    fi

    if [ "$started" = true ]; then
        hal_set_state "status" "active"
    else
        hal_warn "No audio server could be started"
        hal_set_state "status" "no_audio"
    fi

    # Keep alive
    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor audio HAL
# ---------------------------------------------------------------------------
audio_mock() {
    hal_info "Audio HAL mock: attempting ALSA-only path"

    export PULSE_SERVER=unix:/tmp/pulseaudio.socket
    export PULSE_RUNTIME_PATH=/run/pulse
    mkdir -p /run/pulse

    # Even without vendor HAL, ALSA may still work via kernel drivers
    unmute_alsa_controls

    if command -v pulseaudio >/dev/null 2>&1; then
        local alsa_cards
        alsa_cards=$(detect_alsa_cards)
        if [ "$alsa_cards" -gt 0 ]; then
            start_pulseaudio_alsa
            hal_set_state "status" "alsa_only"
        else
            pulseaudio -D \
                --system \
                --disallow-exit \
                --load="module-null-sink" \
                2>/dev/null &
            hal_info "PulseAudio started with null sink (no ALSA cards)"
            hal_set_state "status" "mock"
        fi
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run audio_native audio_mock
