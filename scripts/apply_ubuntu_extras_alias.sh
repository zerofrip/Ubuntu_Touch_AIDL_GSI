#!/system/bin/sh
# Alias Lomiri.Components.Extras -> Ubuntu.Components.Extras for Terminal click.
SRC=/mnt/halium/merged/usr/lib/aarch64-linux-gnu/qt5/qml/Lomiri/Components/Extras
DST=/mnt/halium/merged/usr/lib/aarch64-linux-gnu/qt5/qml/Ubuntu/Components/Extras
if [ -f "$DST/qmldir" ]; then
  echo ubuntu_extras_alias=yes
  exit 0
fi
[ -f "$SRC/qmldir" ] || exit 0
chroot /mnt/halium/merged /usr/bin/python3 - <<'PY'
import shutil
from pathlib import Path
src = Path("/usr/lib/aarch64-linux-gnu/qt5/qml/Lomiri/Components/Extras")
dst = Path("/usr/lib/aarch64-linux-gnu/qt5/qml/Ubuntu/Components/Extras")
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(src, dst)
q = dst / "qmldir"
q.write_text(q.read_text().replace(
    "module Lomiri.Components.Extras", "module Ubuntu.Components.Extras"))
for p in dst.glob("*/qmldir"):
    p.write_text(p.read_text().replace("module Lomiri", "module Ubuntu"))
print("ubuntu_extras_alias=yes")
PY
