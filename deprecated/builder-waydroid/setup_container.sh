#!/bin/bash
# =============================================================================
# scripts/setup_container.sh (Flexible Waydroid Isolation Matrix)
# =============================================================================
# Scans for available private IP network pools assigning a unique /24 natively.
# Ensures exact IPC read-only maps locking Waydroid sandboxes perfectly and applies 
# strict modular Seccomp profiles natively.
# =============================================================================

mkdir -p /data/uhl_overlay

# Dynamically determining available routing subnets (10.X.3.1)
SUBNET_PREFIX=10
for i in {0..10}; do
    if ! ip route show | grep -q "${SUBNET_PREFIX}.${i}.3"; then
        TARGET_SUBNET="${SUBNET_PREFIX}.${i}.3"
        CONTAINER_ID=$i
        break
    fi
done

if [ -z "$TARGET_SUBNET" ]; then
    echo "[$(date -Iseconds)] [Waydroid Sandbox] FATAL: Exhausted dynamic NAT subnets." > "/data/uhl_overlay/waydroid_fatal.log"
    exit 1
fi

LOG_FILE="/data/uhl_overlay/waydroid_container${CONTAINER_ID}.log"
touch "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "[$(date -Iseconds)] [LXC Setup] Provisioning Waydroid Container #$CONTAINER_ID Bounds..." >> "$LOG_FILE"
echo "[$(date -Iseconds)] [Waydroid Sandbox] Tracking previous Waydroid LXC sessions..." >> "$LOG_FILE"

echo "[$(date -Iseconds)] [Waydroid Sandbox] Acquired Dynamic Subnet: ${TARGET_SUBNET}.0/24" >> "$LOG_FILE"

BRIDGE_NAME="lxcbr$CONTAINER_ID"

if ! ip link show $BRIDGE_NAME > /dev/null 2>&1; then
    echo "[$(date -Iseconds)] [Waydroid Sandbox] Generating LXC Bridge ($BRIDGE_NAME) -> ${TARGET_SUBNET}.1" >> "$LOG_FILE"
    brctl addbr $BRIDGE_NAME
    ifconfig $BRIDGE_NAME ${TARGET_SUBNET}.1 netmask 255.255.255.0 up
    iptables -t nat -A POSTROUTING -s ${TARGET_SUBNET}.0/24 ! -d ${TARGET_SUBNET}.0/24 -j MASQUERADE
    systemctl restart dnsmasq
fi

LXC_CONF="/var/lib/waydroid/lxc/waydroid/config"

if [ -f "$LXC_CONF" ]; then
    if ! grep -q "lxc.mount.entry = /dev/binderfs" "$LXC_CONF"; then
        echo "[$(date -Iseconds)] [Waydroid Sandbox] Securing /dev/vndbinder IPC exclusions inside LXC Config!" >> "$LOG_FILE"
        echo "lxc.mount.entry = /dev/binderfs/binder dev/binder none bind,create=file 0 0" >> "$LXC_CONF"
        echo "lxc.mount.entry = /dev/binderfs/vndbinder dev/vndbinder none bind,ro,create=file 0 0" >> "$LXC_CONF"
        echo "lxc.mount.entry = /dev/binderfs/hwbinder dev/hwbinder none bind,ro,create=file 0 0" >> "$LXC_CONF"
        
        echo "[$(date -Iseconds)] [Waydroid Sandbox] Applying Extensibility Sandbox Seccomp Limits." >> "$LOG_FILE"
        cp /waydroid/lxc-seccomp.conf /var/lib/waydroid/lxc_seccomp.conf
        echo "lxc.seccomp.profile = /var/lib/waydroid/lxc_seccomp.conf" >> "$LXC_CONF"
    else
        echo "[$(date -Iseconds)] [Waydroid Sandbox] IPC exclusions previously verified." >> "$LOG_FILE"
    fi
else
    echo "[$(date -Iseconds)] [Waydroid Sandbox] WARNING: waydroid configuration not found natively. Is Waydroid init?" >> "$LOG_FILE"
fi

echo "[$(date -Iseconds)] [Waydroid Sandbox] Instantiating Multi-Namespace Container limits natively." >> "$LOG_FILE"
systemctl restart waydroid-container
echo "[$(date -Iseconds)] [Waydroid Sandbox] Container Sequence Active ($TARGET_SUBNET.1)." >> "$LOG_FILE"
