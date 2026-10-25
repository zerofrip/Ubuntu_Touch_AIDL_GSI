#!/bin/bash
# Run inside Ubuntu chroot. Requires host apt_http_proxy + adb reverse :3128.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export http_proxy=http://127.0.0.1:3128/
export https_proxy=http://127.0.0.1:3128/
export no_proxy=localhost,127.0.0.1

printf '127.0.0.1\tlocalhost\n127.0.1.1\tubuntu-gsi\n::1\tlocalhost ip6-localhost ip6-loopback\n' >/etc/hosts

# Rootfs image was missing hosts: — apt then fails resolving even 127.0.0.1.
cat >/etc/nsswitch.conf <<'EOF'
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
EOF

printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' >/etc/resolv.conf
mkdir -p /etc/apt/apt.conf.d
cat >/etc/apt/apt.conf.d/01proxy <<'EOF'
Acquire::http::Proxy "http://127.0.0.1:3128/";
Acquire::https::Proxy "http://127.0.0.1:3128/";
Acquire::ForceIPv4 "true";
Acquire::Retries "3";
EOF

echo "=== getent ==="
getent hosts 127.0.0.1
getent hosts localhost

echo "=== apt-get update ==="
apt-get update
echo "apt_update_ok=1"

echo "=== apt-get install -y --dry-run hello ==="
apt-get install -y --dry-run hello
echo "apt_dryrun_ok=1"
