#!/bin/bash
# =============================================================================
# aidl/telephony/telephony_hal.sh — Telephony/Radio AIDL HAL Wrapper
# =============================================================================
# Bridges oFono/ModemManager to Android vendor Radio HAL via
# AIDL binder interface android.hardware.radio.IRadio.
#
# Manages: SIM card detection, mobile data (RIL), SMS, and voice calls.
#
# Native mode: Detects vendor RIL/modem, configures oFono or ModemManager
#              to communicate via rild/binder, enables mobile data.
# Mock mode:   Telephony unavailable — logs status for diagnostics.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "telephony" "android.hardware.radio.IRadio" "optional"

# ---------------------------------------------------------------------------
# Modem/RIL detection
# ---------------------------------------------------------------------------

RILD_SOCKET="/dev/socket/rild"
RILD_SOCKET_ALT="/dev/socket/rild-debug"
VENDOR_RIL_LIB_PATHS="
/vendor/lib64/libril-qc-hal-qmi.so
/vendor/lib64/libril-samsung.so
/vendor/lib64/libril-mtk.so
/vendor/lib64/libril.so
/vendor/lib/libril-qc-hal-qmi.so
/vendor/lib/libril-samsung.so
/vendor/lib/libril-mtk.so
/vendor/lib/libril.so
"

detect_modem_device() {
    # Check for common modem device nodes
    local modem_devs=""

    # QMI modems (Qualcomm)
    for dev in /dev/cdc-wdm* /dev/qmi* /dev/smd* /dev/rmnet*; do
        if [ -e "$dev" ]; then
            modem_devs="$modem_devs $dev"
            hal_info "Found QMI modem device: $dev"
        fi
    done

    # MBIM modems
    for dev in /dev/cdc-wdm*; do
        if [ -c "$dev" ]; then
            # Check if it's MBIM rather than QMI
            if [ -f "/sys/class/net/wwan0/device/interface" ]; then
                modem_devs="$modem_devs $dev"
                hal_info "Found MBIM modem device: $dev"
            fi
        fi
    done

    # Serial/AT modems (MediaTek, some Samsung)
    for dev in /dev/ttyACM* /dev/ttyUSB* /dev/ttyMT* /dev/ccci_* /dev/eemcs_*; do
        if [ -c "$dev" ]; then
            modem_devs="$modem_devs $dev"
            hal_info "Found serial modem device: $dev"
        fi
    done

    # WWAN network interfaces
    for iface in /sys/class/net/rmnet* /sys/class/net/wwan* /sys/class/net/ccmni*; do
        if [ -d "$iface" ]; then
            hal_info "Found modem network interface: $(basename "$iface")"
        fi
    done

    if [ -n "$modem_devs" ]; then
        echo "$modem_devs"
        return 0
    fi
    return 1
}

detect_sim_card() {
    # Check for SIM presence via sysfs or vendor paths
    local sim_detected=false

    # Check vendor SIM status paths
    for sim_path in \
        /sys/class/misc/sim_detect \
        /sys/devices/virtual/misc/sim_detect \
        /proc/simcard; do
        if [ -e "$sim_path" ]; then
            local status
            status=$(cat "$sim_path" 2>/dev/null)
            hal_info "SIM status ($sim_path): $status"
            sim_detected=true
        fi
    done

    # Check via binder state (if radio HAL reports SIM)
    if [ -f /tmp/binder_state ]; then
        if grep -q "SIM_READY" /tmp/binder_state 2>/dev/null; then
            sim_detected=true
        fi
    fi

    $sim_detected && return 0
    return 1
}

detect_modem_type() {
    # Determine modem vendor/type for correct backend selection
    local modem_type="unknown"

    if [ -f /vendor/build.prop ]; then
        local platform
        platform=$(grep "ro.board.platform" /vendor/build.prop 2>/dev/null | cut -d'=' -f2)

        case "$platform" in
            mt*|MT*)
                modem_type="mediatek"
                ;;
            msm*|sdm*|sm*|lahaina|taro|kalama|crow*)
                modem_type="qualcomm"
                ;;
            exynos*|universal*)
                modem_type="samsung"
                ;;
            *)
                # Check for specific RIL libraries
                for ril in $VENDOR_RIL_LIB_PATHS; do
                    if [ -f "$ril" ]; then
                        case "$ril" in
                            *mtk*) modem_type="mediatek" ;;
                            *qmi*|*qc*) modem_type="qualcomm" ;;
                            *samsung*) modem_type="samsung" ;;
                        esac
                        break
                    fi
                done
                ;;
        esac
    fi

    hal_info "Modem type detected: $modem_type"
    echo "$modem_type"
}

setup_modem_permissions() {
    # Set permissions on modem device nodes
    # QMI devices
    for dev in /dev/cdc-wdm*; do
        [ -e "$dev" ] && chmod 0660 "$dev" 2>/dev/null || true
    done

    # Serial modem devices
    for dev in /dev/ttyACM* /dev/ttyUSB* /dev/ttyMT* /dev/ccci_* /dev/eemcs_*; do
        [ -c "$dev" ] && chmod 0660 "$dev" 2>/dev/null || true
    done

    # RIL sockets
    for sock in /dev/socket/rild*; do
        [ -e "$sock" ] && chmod 0660 "$sock" 2>/dev/null || true
    done
}

configure_ofono() {
    local modem_type="$1"

    mkdir -p /etc/ofono

    # Generate oFono configuration
    cat > /etc/ofono/ofono.conf << 'OFONOEOF'
[General]
# Enable automatic context activation for mobile data
AutoActivation=true
# Modem technology auto-detection
DetectModem=true
OFONOEOF

    # Configure oFono plugins based on modem type
    case "$modem_type" in
        qualcomm)
            cat > /etc/ofono/plugins.conf << 'EOF'
[Plugins]
Enable=qmimodem,rilmodem,gobi
EOF
            hal_info "oFono configured for Qualcomm QMI modem"
            ;;
        mediatek)
            cat > /etc/ofono/plugins.conf << 'EOF'
[Plugins]
Enable=rilmodem,mtk,mtk2
EOF
            hal_info "oFono configured for MediaTek modem"
            ;;
        samsung)
            cat > /etc/ofono/plugins.conf << 'EOF'
[Plugins]
Enable=rilmodem,samsungmodem
EOF
            hal_info "oFono configured for Samsung modem"
            ;;
        *)
            cat > /etc/ofono/plugins.conf << 'EOF'
[Plugins]
Enable=rilmodem,qmimodem,gobi,atmodem
EOF
            hal_info "oFono configured with generic plugin set"
            ;;
    esac
}

configure_modemmanager() {
    local modem_type="$1"

    mkdir -p /etc/ModemManager

    # ModemManager filter rules for Android vendor modems
    cat > /etc/ModemManager/fcc-unlock.d/README << 'EOF'
# FCC unlock scripts for vendor modems (if needed)
# Place custom unlock scripts here named by vid:pid
EOF

    # Configure NetworkManager to use ModemManager for WWAN
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/modem.conf << 'NMEOF'
[main]
# Enable ModemManager integration
plugins=keyfile

[keyfile]
unmanaged-devices=none
NMEOF
    hal_info "NetworkManager configured for ModemManager integration"
}

setup_ril_bridge() {
    local modem_type="$1"

    # For Android-based modems, we need to bridge the RIL socket
    # Some vendor RILs expose /dev/socket/rild for AT/RIL commands

    if [ -S "$RILD_SOCKET" ] || [ -S "$RILD_SOCKET_ALT" ]; then
        hal_info "Android RIL socket detected — configuring bridge"

        # Ensure the socket is accessible
        chmod 0660 "$RILD_SOCKET" 2>/dev/null || true

        hal_set_state "ril_socket" "$RILD_SOCKET"
        return 0
    fi

    hal_info "No Android RIL socket found — using direct modem access"
    return 1
}

start_telephony_backend() {
    local modem_type="$1"

    # Prefer oFono for Ubuntu Touch compatibility, fall back to ModemManager
    if command -v ofonod >/dev/null 2>&1; then
        configure_ofono "$modem_type"

        ofonod -n -d 2>/dev/null &
        hal_info "oFono daemon started (PID $!)"
        hal_set_state "backend" "ofono"
        return 0
    fi

    if command -v ModemManager >/dev/null 2>&1; then
        configure_modemmanager "$modem_type"

        ModemManager --debug 2>/dev/null &
        hal_info "ModemManager started (PID $!)"
        hal_set_state "backend" "modemmanager"
        return 0
    fi

    hal_warn "Neither oFono nor ModemManager available"
    hal_set_state "backend" "none"
    return 1
}

# ---------------------------------------------------------------------------
# Native handler — vendor modem/RIL available
# ---------------------------------------------------------------------------
telephony_native() {
    hal_info "Initializing telephony subsystem with vendor Radio HAL"

    # Step 1: Detect modem type
    local modem_type
    modem_type=$(detect_modem_type)
    hal_set_state "modem_type" "$modem_type"

    # Step 2: Detect modem device nodes (retry — modem may need time to enumerate)
    local modem_devs=""
    local retries=0
    local max_retries=15

    while [ $retries -lt $max_retries ]; do
        modem_devs=$(detect_modem_device)
        if [ -n "$modem_devs" ]; then
            break
        fi
        retries=$((retries + 1))
        hal_info "Waiting for modem device... (attempt $retries/$max_retries)"
        sleep 2
    done

    if [ -z "$modem_devs" ]; then
        hal_warn "No modem device detected — falling back to mock"
        telephony_mock
        return
    fi

    hal_set_state "modem_devices" "$modem_devs"

    # Step 3: Setup permissions
    setup_modem_permissions

    # Step 4: Try RIL bridge for Android vendor modems
    setup_ril_bridge "$modem_type" || true

    # Step 5: Start telephony backend (oFono or ModemManager)
    if ! start_telephony_backend "$modem_type"; then
        hal_warn "Could not start telephony backend"
        telephony_mock
        return
    fi

    # Step 6: Detect SIM card
    sleep 3  # Give modem time to initialize
    if detect_sim_card; then
        hal_info "SIM card detected"
        hal_set_state "sim_status" "present"
    else
        hal_info "No SIM card detected (insert SIM and restart)"
        hal_set_state "sim_status" "absent"
    fi

    hal_set_state "status" "active"
    hal_info "Telephony subsystem initialized: type=$modem_type"

    # Keep alive, monitor modem status
    while true; do
        # Check if backend is still running
        local backend
        backend=$(hal_get_state "backend")

        case "$backend" in
            ofono)
                if ! pgrep -x ofonod >/dev/null 2>&1; then
                    hal_warn "oFono died — restarting"
                    ofonod -n -d 2>/dev/null &
                fi
                ;;
            modemmanager)
                if ! pgrep -x ModemManager >/dev/null 2>&1; then
                    hal_warn "ModemManager died — restarting"
                    ModemManager --debug 2>/dev/null &
                fi
                ;;
        esac
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no modem/telephony available
# ---------------------------------------------------------------------------
telephony_mock() {
    hal_info "Telephony HAL mock: no modem hardware detected"
    hal_set_state "status" "mock"
    hal_set_state "modem_type" "none"
    hal_set_state "sim_status" "absent"
    hal_set_state "backend" "none"

    while true; do
        sleep 60
    done
}

aidl_hal_run telephony_native telephony_mock
