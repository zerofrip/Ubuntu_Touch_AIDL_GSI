#!/bin/bash
set -euo pipefail
sed 's|exec "$LOMIRI_BIN"|exec catchsegv "$LOMIRI_BIN"|' \
  /usr/lib/ubuntu-gsi/halium/start-lomiri.sh > /tmp/sl-catch.sh
chmod +x /tmp/sl-catch.sh
exec /tmp/sl-catch.sh
