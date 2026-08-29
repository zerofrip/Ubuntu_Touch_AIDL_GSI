#!/system/bin/sh
# Detect NVT touch SPI checksum storm (no ABS events despite IRQs).
# Do NOT unbind/bind NVT-ts here — rebind triggers novatek_ts_fw rewrite loops.
# Recovery: reboot the device, then keep HWC2_STUB_SKIP_VENDOR_POWER=1.
setenforce 0 2>/dev/null || true

I1=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
sleep 1
I2=$(grep NVT-ts /proc/interrupts 2>/dev/null | awk '{print $2}')
DELTA=$((I2 - I1))
CS=$(dmesg 2>/dev/null | grep -c 'nvt_ts_point_data_checksum' || echo 0)
RC=$(dmesg 2>/dev/null | grep -c 'Recover for fw reset' || echo 0)

echo "nvt_irq_1s=$DELTA checksum_log=$CS recover_fw=$RC"

if [ "$DELTA" -gt 30 ] 2>/dev/null || [ "$CS" -gt 50 ] 2>/dev/null; then
  echo "nvt_storm=yes"
  echo "nvt_action=reboot_required (SPI rebind forbidden)"
  exit 2
fi
echo "nvt_storm=no"
exit 0
