#!/system/bin/sh
# Provide QtQuick Controls via bind OR QML2_IMPORT_PATH fallback (overlay whiteouts
# often block mkdir/bind under merged QtQuick/).
#
# IMPORTANT: do NOT symlink into qml-extra. Qt realpath() of style plugins outside
# the import root yields bogus module URIs (e.g. ata.local.tmp.qml-QtQuick-Controls.Fusion)
# and Morph exits. Copy real trees under EXTRA instead.
DST=/mnt/halium/merged/usr/lib/aarch64-linux-gnu/qt5/qml/QtQuick
UP=/mnt/halium/overlay_rw/upper/usr/lib/aarch64-linux-gnu/qt5/qml/QtQuick
EXTRA=/data/local/tmp/qml-extra/QtQuick
mkdir -p "$EXTRA"
for n in Controls Controls.2 Templates.2 PrivateWidgets; do
  src=/data/local/tmp/qml-QtQuick-$n
  [ -d "$src" ] || continue
  rm -rf "$EXTRA/$n"
  cp -a "$src" "$EXTRA/$n" 2>/dev/null || continue
  # Best-effort bind into system QML tree.
  mkdir -p "$DST" "$UP" 2>/dev/null
  if [ -e "$UP/$n" ] || [ -L "$UP/$n" ]; then
    rm -rf "$UP/$n" 2>/dev/null || true
  fi
  if [ ! -d "$DST/$n" ]; then
    mkdir -p "$DST/$n" 2>/dev/null || true
  fi
  if [ -d "$DST/$n" ]; then
    mountpoint -q "$DST/$n" 2>/dev/null || mount --bind "$src" "$DST/$n" 2>/dev/null || true
  fi
done
# Soname links for Controls2 (plugin DT_NEEDED).
if [ -f /data/local/tmp/libQt5QuickControls2.so.5.12.8 ]; then
  cd /data/local/tmp || exit 0
  ln -sfn libQt5QuickControls2.so.5.12.8 libQt5QuickControls2.so.5
  ln -sfn libQt5QuickControls2.so.5 libQt5QuickControls2.so
fi
if [ -f /data/local/tmp/libQt5QuickTemplates2.so.5.12.8 ]; then
  cd /data/local/tmp || exit 0
  ln -sfn libQt5QuickTemplates2.so.5.12.8 libQt5QuickTemplates2.so.5
  ln -sfn libQt5QuickTemplates2.so.5 libQt5QuickTemplates2.so
fi
if [ -f "$EXTRA/Controls.2/qmldir" ] && [ ! -L "$EXTRA/Controls.2" ]; then
  echo qml_controls_import=yes_copy
fi
if [ -f "$DST/Controls/qmldir" ]; then
  echo qml_controls_ready=yes
fi
