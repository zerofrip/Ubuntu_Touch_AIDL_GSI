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
        for ctl in Master Speaker Headphone PCM "Speaker Playback" "Headphone Playback" \
                   Earpiece Receiver "Earpiece Playback" "RX1 Digital" "RX2 Digital" \
                   "SLIM RX0" "SLIM RX1" "Voice Call" "Voice" \
                   Capture "Capture Switch" "ADC" "Internal Mic" "Headset Mic"; do
            amixer -c "$card_num" -q set "$ctl" 80% unmute 2>/dev/null || true
        done
        hal_info "ALSA card $card_num: controls unmuted (incl. voice/earpiece)"
        card_num=$((card_num + 1))
    done
}

# ---------------------------------------------------------------------------
# Voice call audio routing
# ---------------------------------------------------------------------------
VOICE_ROUTE_STATE="/run/ubuntu-gsi/voice_route"
VOICE_ROUTE="speaker"

setup_voice_call_routing() {
    mkdir -p /run/ubuntu-gsi

    # Detect earpiece/receiver device on each ALSA card
    if ! command -v amixer >/dev/null 2>&1; then
        hal_warn "amixer unavailable — cannot configure voice routing"
        return
    fi

    local card_num=0
    while [ -d "/proc/asound/card${card_num}" ]; do
        local card_ctls
        card_ctls=$(amixer -c "$card_num" scontrols 2>/dev/null || true)

        # Check for earpiece/receiver control
        if echo "$card_ctls" | grep -qi "earpiece\|receiver"; then
            hal_info "Earpiece control found on card $card_num"
            echo "earpiece_card=$card_num" > "$VOICE_ROUTE_STATE"
        fi

        # Check for voice call path
        if echo "$card_ctls" | grep -qi "voice.call\|voicecall\|voice_call"; then
            hal_info "Voice call path found on card $card_num"
            echo "voice_call_card=$card_num" >> "$VOICE_ROUTE_STATE"
        fi

        card_num=$((card_num + 1))
    done
}

set_voice_route() {
    local route=$1  # earpiece | speaker | headset
    local earpiece_card=""

    if [ -f "$VOICE_ROUTE_STATE" ]; then
        earpiece_card=$(grep "earpiece_card=" "$VOICE_ROUTE_STATE" 2>/dev/null | cut -d= -f2)
    fi

    case "$route" in
        earpiece)
            if [ -n "$earpiece_card" ]; then
                amixer -c "$earpiece_card" -q set Earpiece 70% unmute 2>/dev/null || \
                amixer -c "$earpiece_card" -q set Receiver 70% unmute 2>/dev/null || true
                amixer -c "$earpiece_card" -q set Speaker 0% mute 2>/dev/null || true
                VOICE_ROUTE="earpiece"
            fi
            ;;
        speaker)
            if [ -n "$earpiece_card" ]; then
                amixer -c "$earpiece_card" -q set Speaker 80% unmute 2>/dev/null || true
                amixer -c "$earpiece_card" -q set Earpiece 0% mute 2>/dev/null || \
                amixer -c "$earpiece_card" -q set Receiver 0% mute 2>/dev/null || true
                VOICE_ROUTE="speaker"
            fi
            ;;
        headset)
            if [ -n "$earpiece_card" ]; then
                amixer -c "$earpiece_card" -q set Headphone 70% unmute 2>/dev/null || true
                amixer -c "$earpiece_card" -q set Speaker 0% mute 2>/dev/null || true
                amixer -c "$earpiece_card" -q set Earpiece 0% mute 2>/dev/null || \
                amixer -c "$earpiece_card" -q set Receiver 0% mute 2>/dev/null || true
                VOICE_ROUTE="headset"
            fi
            ;;
    esac
    hal_info "Voice route set to: $VOICE_ROUTE"
}

monitor_headset_jack() {
    # Monitor headset insertion/removal and switch voice route
    if ! command -v amixer >/dev/null 2>&1; then
        return
    fi

    local earpiece_card=""
    if [ -f "$VOICE_ROUTE_STATE" ]; then
        earpiece_card=$(grep "earpiece_card=" "$VOICE_ROUTE_STATE" 2>/dev/null | cut -d= -f2)
    fi
    [ -n "$earpiece_card" ] || return

    while true; do
        local jack_status
        jack_status=$(amixer -c "$earpiece_card" cget name='Headphone Jack' 2>/dev/null | grep ': values=' | cut -d= -f2 || echo "")
        if [ "$jack_status" = "on" ] && [ "$VOICE_ROUTE" != "headset" ]; then
            set_voice_route headset
        elif [ "$jack_status" = "off" ] && [ "$VOICE_ROUTE" = "headset" ]; then
            set_voice_route earpiece
        fi
        sleep 2
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

    # Setup voice call audio routing (earpiece/speaker/headset detection)
    setup_voice_call_routing

    # Default to earpiece for incoming calls
    set_voice_route earpiece

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

    # Monitor headset jack in background for voice route switching
    monitor_headset_jack &

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

    # Setup voice call routing even in mock mode
    setup_voice_call_routing
    set_voice_route earpiece

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

    # Monitor headset jack in background for voice route switching
    monitor_headset_jack &

    while true; do
        sleep 60
    done
}

aidl_hal_run audio_native audio_mock
