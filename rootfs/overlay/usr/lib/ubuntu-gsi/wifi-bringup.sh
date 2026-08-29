#!/bin/sh
# =============================================================================
# wifi-bringup.sh — NetworkManager WiFi bring-up (Halium / GSI)
# =============================================================================
# Runtime evidence (MTK connac2 / gen4m):
#   - Android wpa_supplicant + wificond keep NM state "unavailable"
#   - After stopping them + wmtWifi 0/1/S + Linux wpa_supplicant -u,
#     NM becomes "disconnected" and nmcli wifi list works
# Device-agnostic: skip vendor power node if absent; always reclaim from Android.
# =============================================================================

set -u

# Halium chroot often inherits Android PATH (no /usr/bin) — fix before nmcli/wpa.
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

LOG_TAG="wifi-bringup"

log() { echo "[$LOG_TAG] $*" >&2; }

IFACE="${WIFI_IFACE:-}"
WMT="${WMT_WIFI_DEV:-/dev/wmtWifi}"

_stop_android_wifi() {
    for s in wpa_supplicant wificond vendor.wifi_hal_legacy wlan_assistant hostapd; do
        setprop ctl.stop "$s" 2>/dev/null || true
        stop "$s" 2>/dev/null || true
    done
    killall -9 wpa_supplicant hostapd wificond 2>/dev/null || true
}

# --- 0. Reclaim radio from Android WiFi stack (required for NM) ---
_android_wpa=$(pidof /vendor/bin/hw/wpa_supplicant 2>/dev/null || true)
[ -z "$_android_wpa" ] && _android_wpa=$(pidof wpa_supplicant 2>/dev/null | awk '{print $1}')
_stop_android_wifi
kill -9 $_android_wpa 2>/dev/null || true

# --- 1. Vendor WiFi power (MTK: 0 off, 1 on, S STA) ---
if [ -c "$WMT" ]; then
    for c in 0 1 S; do
        printf '%s' "$c" >"$WMT" 2>/dev/null || true
        sleep 1
    done
    log "vendor wifi node $WMT: power cycle 0/1/S"
else
    log "no vendor wifi power node at $WMT (ok on non-MTK)"
fi

# --- 2. Unblock rfkill ---
for rk in /sys/class/rfkill/rfkill*; do
    [ -e "$rk/type" ] || continue
    typ=$(cat "$rk/type" 2>/dev/null || true)
    if [ "$typ" = "wlan" ] || [ "$typ" = "wifi" ]; then
        echo 1 >"$rk/state" 2>/dev/null || true
        log "rfkill $(basename "$rk") ($typ) -> unblocked"
    fi
done
# phy80211 rfkill soft unblock
for soft in /sys/class/net/wlan*/phy80211/rfkill*/soft; do
    [ -e "$soft" ] || continue
    echo 0 >"$soft" 2>/dev/null || true
done
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null || true

# --- 3. Pick interface ---
if [ -z "$IFACE" ]; then
    for cand in /sys/class/net/wlan*; do
        [ -d "$cand" ] || continue
        IFACE=$(basename "$cand")
        break
    done
fi
IFACE="${IFACE:-wlan0}"

if [ -d "/sys/class/net/$IFACE" ]; then
    ip link set dev "$IFACE" down 2>/dev/null || true
    ip link set dev "$IFACE" up 2>/dev/null || ifconfig "$IFACE" up 2>/dev/null || true
    log "$IFACE: link cycled (operstate=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null))"
else
    log "WARNING: $IFACE not present"
fi

# --- 4. Seed udev for NM ---
if [ -d "/sys/class/net/$IFACE" ]; then
    mkdir -p /run/udev/data
    ifindex=$(cat "/sys/class/net/$IFACE/ifindex" 2>/dev/null || echo "")
    if [ -n "$ifindex" ]; then
        cat >"/run/udev/data/n${ifindex}" <<UDEV
I:$(date +%s)
E:ID_NET_DRIVER=wlan
E:ID_NET_NAME=${IFACE}
E:INTERFACE=${IFACE}
E:SUBSYSTEM=net
E:NM_UNMANAGED=0
E:ID_BUS=platform
UDEV
        log "udev: seeded /run/udev/data/n${ifindex} for $IFACE"
    fi
fi

# --- 5. NM + wpa_supplicant config ---
mkdir -p /etc/wpa_supplicant /etc/NetworkManager/conf.d /run/wpa_supplicant
if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'WPAEOF'
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
p2p_disabled=1
WPAEOF
fi

cat >/etc/NetworkManager/conf.d/99-wlan-halium.conf <<'NMEOF'
[main]
dns=default
rc-manager=file

[keyfile]
unmanaged-devices=

[device]
wifi.scan-rand-mac-address=no
wifi.backend=wpa_supplicant
NMEOF

cat >/etc/NetworkManager/conf.d/10-globally-managed-devices.conf <<NMEOF
[keyfile]
unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma,except:type:wwan,except:interface-name:${IFACE}
NMEOF

# Apps (Morph/Firefox/curl) need file DNS + Android policy routing bypass.
# Canonical implementation: halium-app-net.sh (usr or uhl_overlay).
_halium_app_net_bin() {
    for _p in /usr/lib/ubuntu-gsi/halium-app-net.sh /data/uhl_overlay/ubuntu-gsi-bin/halium-app-net.sh; do
        [ -x "$_p" ] && { printf '%s' "$_p"; return 0; }
    done
    return 1
}
ensure_app_dns() {
    _han=$(_halium_app_net_bin) || _han=""
    if [ -n "$_han" ]; then
        WIFI_IFACE="$IFACE" "$_han" >/dev/null 2>&1 || true
        return 0
    fi
    if [ ! -f /etc/nsswitch.conf ] || ! grep -qE '^[[:space:]]*hosts:.*dns' /etc/nsswitch.conf 2>/dev/null; then
        cat >/etc/nsswitch.conf <<'NSS'
passwd:         files
group:          files
shadow:         files
gshadow:        files
hosts:          files dns
networks:       files
protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
netgroup:       nis
NSS
        log "nsswitch: hosts files dns"
    fi
    if [ -L /etc/resolv.conf ]; then
        _target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
        case "$_target" in
            *stub-resolv*|*systemd*)
                rm -f /etc/resolv.conf
                log "resolv.conf: removed stub symlink ($_target)"
                ;;
        esac
    fi
    if [ -f /etc/resolv.conf ] && grep -qE 'nameserver[[:space:]]+127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        rm -f /etc/resolv.conf
        log "resolv.conf: removed 127.0.0.53 stub content"
    fi
    if [ ! -f /etc/resolv.conf ] || ! grep -qE '^[[:space:]]*nameserver[[:space:]]+[0-9]' /etc/resolv.conf 2>/dev/null; then
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' >/etc/resolv.conf
        log "resolv.conf: seeded fallback 8.8.8.8 / 1.1.1.1"
    fi
}

ensure_app_routing() {
    # Prefer shared helper (persistent Android policy routing fix).
    _han=$(_halium_app_net_bin) || _han=""
    if [ -n "$_han" ]; then
        WIFI_IFACE="$IFACE" "$_han" >/dev/null 2>&1 || true
        return 0
    fi
    if ip rule show 2>/dev/null | grep -qE '^32000:[[:space:]]*from all unreachable'; then
        ip rule del pref 32000 2>/dev/null && log "ip rule: removed pref 32000 unreachable" || true
    fi
    if ! ip rule show 2>/dev/null | grep -qE '^9999:'; then
        ip rule add pref 9999 lookup main 2>/dev/null && \
            log "ip rule: pref 9999 lookup main" || true
    fi
    if ! ip route show default 2>/dev/null | grep -q .; then
        _gw=$(nmcli -g IP4.GATEWAY device show "$IFACE" 2>/dev/null | head -1 || true)
        case "$_gw" in
            ''|'--'|*/*)
                _gw=$(nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | tr '|' '\n' | \
                    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
                ;;
        esac
        if [ -n "${_gw:-}" ] && [ "$_gw" != "--" ]; then
            ip route replace default via "$_gw" dev "$IFACE" metric 600 2>/dev/null && \
                log "route: default via $_gw on $IFACE" || true
        fi
    fi
}
ensure_app_dns
ensure_app_routing

# --- 6. Linux wpa_supplicant with D-Bus (-u) for NetworkManager ---
# Must run inside Ubuntu chroot (needs /usr/sbin/wpa_supplicant + writable /run).
if [ ! -w /run ] 2>/dev/null; then
    log "WARNING: /run not writable — run this script inside the Ubuntu chroot"
fi
if [ -x /sbin/wpa_supplicant ] || [ -x /usr/sbin/wpa_supplicant ]; then
    WPA_BIN=$(command -v wpa_supplicant || true)
    [ -z "$WPA_BIN" ] && [ -x /usr/sbin/wpa_supplicant ] && WPA_BIN=/usr/sbin/wpa_supplicant
    [ -z "$WPA_BIN" ] && [ -x /sbin/wpa_supplicant ] && WPA_BIN=/sbin/wpa_supplicant
    # Drop any remaining non-dbus Android/Linux instance
    killall -9 wpa_supplicant 2>/dev/null || true
    sleep 1
    if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
        "$WPA_BIN" -B -u -s -O /run/wpa_supplicant \
            -i "$IFACE" -c /etc/wpa_supplicant/wpa_supplicant.conf \
            >/data/local/tmp/wpa_linux.log 2>&1 || \
        "$WPA_BIN" -B -u -s -O /run/wpa_supplicant \
            >/data/local/tmp/wpa_linux.log 2>&1 || true
        log "linux wpa_supplicant started (-u dbus) bin=$WPA_BIN"
    fi
fi

# --- 7. NetworkManager ---
if ! pgrep -x NetworkManager >/dev/null 2>&1; then
    if [ -x /usr/sbin/NetworkManager ]; then
        /usr/sbin/NetworkManager 2>/dev/null &
        sleep 2
        log "NetworkManager started"
    fi
fi

if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi on 2>/dev/null || true
    nmcli device set "$IFACE" managed no 2>/dev/null || true
    sleep 1
    nmcli device set "$IFACE" managed yes 2>/dev/null || true
fi

# NM often stays "unavailable" for a few seconds after reclaim; poll.
_i=0
NMDEV=""
while [ "$_i" -lt 12 ]; do
    NMDEV=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep "^${IFACE}:" | head -1 | tr '\n' '|' || true)
    case "$NMDEV" in
        *:unavailable:*) ;;
        *:disconnected:*|*:connected:*|*:connecting*) break ;;
        *) ;;
    esac
    _i=$((_i + 1))
    sleep 1
done
nmcli device wifi rescan 2>/dev/null || true
sleep 2

# Android init may restart wificond during settle — reclaim again.
_stop_android_wifi
# Keep Linux wpa if we killed it with killall above
if ! pgrep -x wpa_supplicant >/dev/null 2>&1; then
    WPA_BIN=$(command -v wpa_supplicant || true)
    [ -z "$WPA_BIN" ] && [ -x /usr/sbin/wpa_supplicant ] && WPA_BIN=/usr/sbin/wpa_supplicant
    if [ -n "${WPA_BIN:-}" ]; then
        "$WPA_BIN" -B -u -s -O /run/wpa_supplicant \
            -i "$IFACE" -c /etc/wpa_supplicant/wpa_supplicant.conf \
            >/data/local/tmp/wpa_linux.log 2>&1 || true
    fi
fi

OPER=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo missing)
NMDEV=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep "^${IFACE}:" | head -1 | tr '\n' '|' || true)
SCAN_N=$(nmcli -t -f SSID device wifi list 2>/dev/null | grep -c . 2>/dev/null || true)
SCAN_N=$(printf '%s' "$SCAN_N" | tr -d '\n'); SCAN_N=${SCAN_N:-0}

# After DHCP: routing (Android policy) + resolv.conf for apps.
ensure_app_routing
ensure_app_dns
if command -v nmcli >/dev/null 2>&1; then
    case "$NMDEV" in
        *:connected:*)
            ensure_app_routing
            # Prefer DHCP DNS from NM over the fallback seed.
            _dns=$(nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | tr '|' '\n' | grep -E '^[0-9a-fA-F.:]+$' || true)
            if [ -n "$_dns" ]; then
                : >/etc/resolv.conf
                for _ns in $_dns; do
                    echo "nameserver $_ns" >>/etc/resolv.conf
                done
                log "resolv.conf: wrote NM DHCP DNS"
            fi
            ;;
    esac
fi
if [ -f /etc/resolv.conf ] && ! grep -qE '^[[:space:]]*nameserver[[:space:]]+[0-9a-fA-F.:]+' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' >/etc/resolv.conf
    log "resolv.conf: post-connect fallback nameservers"
fi

log "done: operstate=$OPER nm=$NMDEV scan_count=$SCAN_N settle=${_i}s wificond=$(getprop init.svc.wificond 2>/dev/null) resolv=$(grep -c nameserver /etc/resolv.conf 2>/dev/null || echo 0)"
case "$NMDEV" in
    *:unavailable:*|'') exit 1 ;;
esac
exit 0
