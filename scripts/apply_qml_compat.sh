#!/system/bin/sh
# Extract Ubuntu.Components + QtQuick.Templates.2 into merged rootfs.
set -e
LOM=$(pidof lomiri 2>/dev/null | awk '{print $1}')
if [ -n "$LOM" ] && [ -f /proc/$LOM/root/usr/bin/python3 ]; then
  chroot /proc/$LOM/root /usr/bin/python3 -c \
    'import tarfile; tarfile.open("/data/local/tmp/qml-compat.tar").extractall("/")'
else
  tar -C /mnt/halium/merged -xf /data/local/tmp/qml-compat.tar 2>/dev/null || true
fi
test -f /mnt/halium/merged/usr/lib/aarch64-linux-gnu/qt5/qml/Ubuntu/Components/qmldir \
  && echo ubuntu_components_ready=yes
test -f /mnt/halium/merged/usr/lib/aarch64-linux-gnu/qt5/qml/QtQuick/Templates.2/qmldir \
  && echo qt_templates_ready=yes
