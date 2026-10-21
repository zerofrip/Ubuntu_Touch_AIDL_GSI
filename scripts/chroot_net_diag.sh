#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "=== hosts ==="
cat /etc/hosts
echo "=== nss ==="
cat /etc/nsswitch.conf
echo "=== nss libs ==="
ls /lib/aarch64-linux-gnu/libnss* 2>&1 | head
ls /usr/lib/aarch64-linux-gnu/libnss* 2>&1 | head
echo "=== getent ==="
getent hosts 127.0.0.1 || true
getent hosts localhost || true
echo "=== python getaddrinfo ==="
python3 - <<'PY'
import socket
print(socket.getaddrinfo("127.0.0.1", 3128))
print(socket.getaddrinfo("localhost", 3128))
PY
