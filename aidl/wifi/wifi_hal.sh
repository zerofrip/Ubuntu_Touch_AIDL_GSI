#!/bin/bash
# =============================================================================
# aidl/wifi/wifi_hal.sh — WiFi AIDL HAL Wrapper
# =============================================================================
# Bridges NetworkManager/wpa_supplicant to Android vendor WiFi HAL via
# AIDL binder interface android.hardware.wifi.IWifi.
#
# Native mode: Configures vendor WiFi driver, loads firmware, starts
#              wpa_supplicant with the correct driver interface.
# Mock mode:   WiFi unavailable — logs status for diagnostics.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/aidl_hal_base.sh"

aidl_hal_init "wifi" "android.hardware.wifi.IWifi" "optional"

# ---------------------------------------------------------------------------
# Vendor WiFi firmware/driver detection
# ---------------------------------------------------------------------------

# Common vendor firmware paths on Treble devices
VENDOR_FW_PATHS="
/vendor/firmware
/vendor/firmware/wlan
/vendor/etc/wifi
/odm/firmware
/odm/etc/wifi
"

# Common wpa_supplicant config locations
WPA_CONF_VENDOR="/vendor/etc/wifi/wpa_supplicant.conf"
WPA_CONF_OVERLAY="/vendor/etc/wifi/wpa_supplicant_overlay.conf"
WPA_CONF_SYSTEM="/etc/wpa_supplicant/wpa_supplicant.conf"
WPA_CONF_NM="/etc/NetworkManager/conf.d/wifi.conf"

detect_wifi_interface() {
    # Try to find a wireless interface via sysfs
    for iface_path in /sys/class/net/*/wireless; do
        if [ -d "$iface_path" ]; then
            WIFI_IFACE=$(basename "$(dirname "$iface_path")")
            hal_info "Detected WiFi interface: $WIFI_IFACE"
            echo "$WIFI_IFACE"
            return 0
        fi
    done

    # Fallback: check for common WiFi interface names
    for iface in wlan0 wlan1 mlan0 p2p0; do
        if [ -d "/sys/class/net/$iface" ]; then
            hal_info "Found WiFi interface by name: $iface"
            echo "$iface"
            return 0
        fi
    done

    hal_warn "No WiFi interface detected"
    return 1
}

detect_wifi_driver() {
    local iface="$1"
    if [ -L "/sys/class/net/$iface/device/driver" ]; then
        DRIVER=$(basename "$(readlink "/sys/class/net/$iface/device/driver")")
        hal_info "WiFi driver: $DRIVER"
        echo "$DRIVER"
        return 0
    fi
    echo "unknown"
    return 1
}

load_vendor_wifi_firmware() {
    # Symlink vendor firmware into the Linux firmware search path
    for fw_path in $VENDOR_FW_PATHS; do
        if [ -d "$fw_path" ]; then
            hal_info "Found vendor firmware at: $fw_path"

            # Ensure /lib/firmware/vendor exists
            mkdir -p /lib/firmware/vendor

            # Create symlinks for firmware files
            for fw_file in "$fw_path"/*; do
                [ -f "$fw_file" ] || continue
                local base_name
                base_name=$(basename "$fw_file")
                if [ ! -e "/lib/firmware/$base_name" ]; then
                    ln -sf "$fw_file" "/lib/firmware/$base_name" 2>/dev/null || true
                fi
                if [ ! -e "/lib/firmware/vendor/$base_name" ]; then
                    ln -sf "$fw_file" "/lib/firmware/vendor/$base_name" 2>/dev/null || true
                fi
            done
            hal_set_state "firmware_path" "$fw_path"
        fi
    done

    # Also handle WCNSS/WLAN config files (Qualcomm)
    for cfg in \
        /vendor/etc/wifi/WCNSS_qcom_cfg.ini \
        /vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini \
        /vendor/firmware/wlan/prima/WCNSS_qcom_cfg.ini; do
        if [ -f "$cfg" ]; then
            hal_info "Found vendor WiFi config: $cfg"
            mkdir -p /lib/firmware/wlan
            ln -sf "$cfg" "/lib/firmware/wlan/$(basename "$cfg")" 2>/dev/null || true
        fi
    done
}

setup_wpa_supplicant_config() {
    local iface="$1"

    mkdir -p /etc/wpa_supplicant

    # Generate base wpa_supplicant.conf if not present
    if [ ! -f "$WPA_CONF_SYSTEM" ]; then
        cat > "$WPA_CONF_SYSTEM" << 'WPAEOF'
# wpa_supplicant configuration — Ubuntu GSI
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
p2p_disabled=1
WPAEOF
        hal_info "Generated wpa_supplicant.conf"
    fi

    # Append vendor overlay config if available
    if [ -f "$WPA_CONF_OVERLAY" ]; then
        hal_info "Merging vendor wpa_supplicant overlay"
        grep -v "^#" "$WPA_CONF_OVERLAY" 2>/dev/null | \
            grep -v "^$" >> "$WPA_CONF_SYSTEM" 2>/dev/null || true
    fi

    # Configure NetworkManager to use wpa_supplicant backend
    mkdir -p /etc/NetworkManager/conf.d
    cat > "$WPA_CONF_NM" << 'NMEOF'
[device]
wifi.scan-rand-mac-address=no
wifi.backend=wpa_supplicant

[connectivity]
enabled=true
NMEOF
    hal_info "NetworkManager WiFi backend configured"
}

configure_regulatory_domain() {
    # Set regulatory domain from vendor if available
    local regdomain=""

    # Try vendor build.prop
    if [ -f /vendor/build.prop ]; then
        regdomain=$(grep "ro.boot.wificountrycode" /vendor/build.prop 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    fi

    # Fallback to /proc/cmdline
    if [ -z "$regdomain" ]; then
        regdomain=$(sed -n 's/.*wificountrycode=\([A-Z]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    fi

    if [ -n "$regdomain" ]; then
        if command -v iw >/dev/null 2>&1; then
            iw reg set "$regdomain" 2>/dev/null || true
            hal_info "Regulatory domain set to: $regdomain"
        fi
        hal_set_state "regdomain" "$regdomain"
    else
        hal_info "No regulatory domain found — using kernel default"
    fi
}

bring_up_wifi_interface() {
    local iface="$1"

    # Ensure the interface is UP
    if command -v ip >/dev/null 2>&1; then
        ip link set "$iface" up 2>/dev/null || true
        hal_info "WiFi interface $iface brought UP"
    fi
}

# ---------------------------------------------------------------------------
# Native handler — vendor WiFi HAL or kernel WiFi driver available
# ---------------------------------------------------------------------------
wifi_native() {
    hal_info "Initializing WiFi subsystem with vendor HAL support"

    # Step 1: Load vendor firmware
    load_vendor_wifi_firmware

    # Step 2: Detect WiFi interface (retry — driver may need time to probe)
    local wifi_iface=""
    local retries=0
    local max_retries=10

    while [ $retries -lt $max_retries ]; do
        wifi_iface=$(detect_wifi_interface)
        if [ -n "$wifi_iface" ]; then
            break
        fi
        retries=$((retries + 1))
        hal_info "Waiting for WiFi interface... (attempt $retries/$max_retries)"
        sleep 2
    done

    if [ -z "$wifi_iface" ]; then
        hal_warn "No WiFi interface available — falling back to mock"
        wifi_mock
        return
    fi

    hal_set_state "interface" "$wifi_iface"

    # Step 3: Detect driver for diagnostics
    local driver
    driver=$(detect_wifi_driver "$wifi_iface")
    hal_set_state "driver" "$driver"

    # Step 4: Configure wpa_supplicant
    setup_wpa_supplicant_config "$wifi_iface"

    # Step 5: Set regulatory domain
    configure_regulatory_domain

    # Step 6: Bring up interface
    bring_up_wifi_interface "$wifi_iface"

    # Step 7: Start wpa_supplicant if not managed by NetworkManager
    if command -v wpa_supplicant >/dev/null 2>&1; then
        # Determine the driver backend
        local wpa_driver="nl80211,wext"

        wpa_supplicant -B \
            -i "$wifi_iface" \
            -D "$wpa_driver" \
            -c "$WPA_CONF_SYSTEM" \
            -O /run/wpa_supplicant \
            2>/dev/null || true
        hal_info "wpa_supplicant started for $wifi_iface (driver=$wpa_driver)"
    else
        hal_warn "wpa_supplicant not found"
    fi

    # Step 8: Ensure NetworkManager manages the WiFi interface
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set "$wifi_iface" managed yes 2>/dev/null || true
        hal_info "NetworkManager managing $wifi_iface"
    fi

    hal_set_state "status" "active"
    hal_info "WiFi subsystem initialized: iface=$wifi_iface driver=$driver"

    # Keep alive, monitor interface status
    while true; do
        if [ -d "/sys/class/net/$wifi_iface" ]; then
            local operstate
            operstate=$(cat "/sys/class/net/$wifi_iface/operstate" 2>/dev/null || echo "unknown")
            hal_set_state "operstate" "$operstate"
        else
            hal_warn "WiFi interface $wifi_iface disappeared"
            hal_set_state "operstate" "gone"
        fi
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no WiFi available
# ---------------------------------------------------------------------------
wifi_mock() {
    hal_info "WiFi HAL mock: no WiFi hardware detected"
    hal_set_state "status" "mock"
    hal_set_state "interface" "none"

    # Still ensure NetworkManager is running for wired/USB networking
    if command -v nmcli >/dev/null 2>&1; then
        systemctl start NetworkManager 2>/dev/null || true
    fi

    while true; do
        sleep 60
    done
}

aidl_hal_run wifi_native wifi_mock
