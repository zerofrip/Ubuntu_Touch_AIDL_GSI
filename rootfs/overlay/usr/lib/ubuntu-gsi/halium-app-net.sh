#!/bin/sh
# =============================================================================
# halium-app-net.sh — Keep WiFi usable for Ubuntu apps on shared Android netns
# =============================================================================
# Android netd installs "from all unreachable" (pref 32000). NM routes in main
# are then ignored → Morph/Firefox/curl get ENETUNREACH despite "connected".
# Also ensure file-based resolv.conf (no systemd-resolved stub).
# Safe to run repeatedly (NM dispatcher + watchdog + wifi-bringup).
# =============================================================================

set -u
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

IFACE="${WIFI_IFACE:-wlan0}"
LOG_TAG="halium-app-net"
log() { echo "[$LOG_TAG] $*" >&2; }

ensure_dns() {
    # When invoked from Android (watchdog/adb), also patch Ubuntu chroot files.
    _roots="/etc"
    [ -d /mnt/halium/merged/etc ] && _roots="/etc /mnt/halium/merged/etc"

    for _etc in $_roots; do
        if [ ! -f "$_etc/nsswitch.conf" ] || ! grep -qE '^[[:space:]]*hosts:.*dns' "$_etc/nsswitch.conf" 2>/dev/null; then
            cat >"$_etc/nsswitch.conf" 2>/dev/null <<'NSS' || true
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
            [ -f "$_etc/nsswitch.conf" ] && log "nsswitch: hosts files dns ($_etc)"
        fi
        if [ -L "$_etc/resolv.conf" ]; then
            _target=$(readlink -f "$_etc/resolv.conf" 2>/dev/null || true)
            case "$_target" in
                *stub-resolv*|*systemd*)
                    rm -f "$_etc/resolv.conf" 2>/dev/null || true
                    log "resolv.conf: removed stub symlink ($_etc)"
                    ;;
            esac
        fi
        if [ -f "$_etc/resolv.conf" ] && grep -qE 'nameserver[[:space:]]+127\.0\.0\.53' "$_etc/resolv.conf" 2>/dev/null; then
            rm -f "$_etc/resolv.conf" 2>/dev/null || true
            log "resolv.conf: removed 127.0.0.53 stub ($_etc)"
        fi
    done

    _dns=""
    if command -v nmcli >/dev/null 2>&1; then
        _dns=$(nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | tr '|' '\n' | grep -E '^[0-9a-fA-F.:]+$' || true)
    fi
    # Prefer Ubuntu nmcli inside chroot if host has none
    if [ -z "$_dns" ] && [ -x /mnt/halium/merged/usr/bin/nmcli ]; then
        _dns=$(chroot /mnt/halium/merged /usr/bin/nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | tr '|' '\n' | grep -E '^[0-9a-fA-F.:]+$' || true)
    fi

    for _etc in $_roots; do
        if [ -n "$_dns" ]; then
            : >"$_etc/resolv.conf" 2>/dev/null || continue
            for _ns in $_dns; do
                echo "nameserver $_ns" >>"$_etc/resolv.conf"
            done
        fi
        if [ ! -f "$_etc/resolv.conf" ] || ! grep -qE '^[[:space:]]*nameserver[[:space:]]+[0-9a-fA-F.:]+' "$_etc/resolv.conf" 2>/dev/null; then
            printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' >"$_etc/resolv.conf" 2>/dev/null || true
            [ -f "$_etc/resolv.conf" ] && log "resolv.conf: seeded fallback ($_etc)"
        fi
    done
}

ensure_routing() {
    if ip rule show 2>/dev/null | grep -qE '^32000:[[:space:]]*from all unreachable'; then
        ip rule del pref 32000 2>/dev/null && log "removed pref 32000 unreachable" || true
    fi
    if ! ip rule show 2>/dev/null | grep -qE '^9999:'; then
        ip rule add pref 9999 lookup main 2>/dev/null && log "added pref 9999 lookup main" || true
    fi

    if ! ip route show default 2>/dev/null | grep -q .; then
        _gw=""
        if command -v nmcli >/dev/null 2>&1; then
            _gw=$(nmcli -g IP4.GATEWAY device show "$IFACE" 2>/dev/null | head -1 || true)
            case "$_gw" in
                ''|'--'|*/*)
                    _gw=$(nmcli -g IP4.DNS device show "$IFACE" 2>/dev/null | tr '|' '\n' | \
                        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
                    ;;
            esac
        fi
        if [ -n "${_gw:-}" ] && [ "$_gw" != "--" ]; then
            ip route replace default via "$_gw" dev "$IFACE" metric 600 2>/dev/null && \
                log "default via $_gw on $IFACE" || true
        fi
    fi
}

ensure_routing
ensure_dns
exit 0
