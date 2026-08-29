#!/bin/bash
# Quick fix: format metadata ext4 in fastbootd (F8 bootloop after erase)
set -euo pipefail
fastboot devices | grep -q . || { echo "No fastboot device"; exit 1; }
if [ "$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/is-userspace/{print $2; exit}')" != "yes" ]; then
    echo "Entering fastbootd..."
    fastboot reboot fastboot
    sleep 15
fi
echo "Formatting metadata (ext4)..."
fastboot format:ext4 metadata
echo "OK. Reboot: fastboot reboot"
