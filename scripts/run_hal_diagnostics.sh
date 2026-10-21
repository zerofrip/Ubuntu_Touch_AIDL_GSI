#!/usr/bin/env bash
# Host convenience: refresh inventory + AIDL probe + lower-layer verify.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
bash "$REPO/scripts/diag_vendor_hal_inventory.sh"
python3 - <<PY
from pathlib import Path
raw = Path("$REPO/builder/out/hal-inventory/inventory_latest.raw.txt").read_text(errors="replace")
out, in_svc = [], False
for line in raw.splitlines():
    if line.startswith("===SERVICE_LIST==="):
        in_svc = True
        continue
    if line.startswith("===") and in_svc:
        break
    if in_svc and line.strip():
        out.append(line)
Path("$REPO/builder/out/hal-inventory/service_list_from_inventory.txt").write_text("\n".join(out) + "\n")
print(f"service_list lines={len(out)}")
PY
# Seed probe input from inventory (avoids hanging `adb shell service list` on some OEM builds)
cp -f "$REPO/builder/out/hal-inventory/service_list_from_inventory.txt" \
  "$REPO/builder/out/hal-inventory/service_list_seed.txt"
# probe_aidl_hals.sh pushes its own capture; override by pre-pushing seed
adb push "$REPO/builder/out/hal-inventory/service_list_from_inventory.txt" \
  /data/local/tmp/service_list.txt >/dev/null
bash "$REPO/scripts/probe_aidl_hals.sh"
bash "$REPO/scripts/verify_lower_layer_display.sh"
echo "All HAL diagnostics refreshed under builder/out/{hal-inventory,lower-layer-display}/"
