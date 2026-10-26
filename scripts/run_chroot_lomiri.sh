#!/bin/bash
# Bind-mount start-lomiri.sh and chroot it with root capabilities kept
# (do not background inside `su`; that drops SYS_CHROOT).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO/halium/lomiri/start-lomiri.sh"
DST_TMP="/data/local/tmp/start-lomiri.sh"
DST_MERGED="/mnt/halium/merged/usr/lib/ubuntu-gsi/halium/start-lomiri.sh"
HOST_LOG="$REPO/builder/out/start-lomiri.host.log"
mkdir -p "$(dirname "$HOST_LOG")"

adb push "$SRC" "$DST_TMP"
# Overlay must already exist (ubuntu-gsi-launcher). If missing, assemble now.
if ! adb shell "su -c 'mountpoint -q /mnt/halium/merged'" >/dev/null 2>&1; then
    echo "merged missing — running /system/bin/ubuntu-gsi-launcher first"
    adb shell "su -c 'setenforce 0'" >/dev/null 2>&1 || true
    adb shell "su -c 'setprop persist.ubuntu_gsi.failed 0'" >/dev/null 2>&1 || true
    # Android toybox: adb/su strips quotes from `su 0 sh -c 'nohup ...'`, so nohup
    # gets zero args ("Needs 1 argument"). Use `su -c` + plain background instead.
    adb shell "su -c '/system/bin/ubuntu-gsi-launcher >/data/local/tmp/launcher-pre-chroot.log 2>&1 &'" || true
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if adb shell "su -c 'mountpoint -q /mnt/halium/merged'" >/dev/null 2>&1; then
            echo "merged ready"
            break
        fi
        sleep 1
    done
    if ! adb shell "su -c 'mountpoint -q /mnt/halium/merged'" >/dev/null 2>&1; then
        echo "ERROR: /mnt/halium/merged still missing after launcher; see /data/local/tmp/launcher-pre-chroot.log" >&2
        exit 1
    fi
    # Launcher may have already exec'd stock Lomiri (TLS abort). Kill before TLS bind.
    adb shell "su -c 'killall lomiri'" >/dev/null 2>&1 || true
fi
adb shell su 0 find /data/uhl_overlay/upper/usr/lib/aarch64-linux-gnu -type l -delete >/dev/null 2>&1 || true
adb shell su 0 mkdir -p /mnt/halium/merged/usr/lib/ubuntu-gsi/halium
# File bind-mounts pin the old inode; umount before re-bind after adb push.
adb shell su 0 umount "$DST_MERGED" 2>/dev/null || true
adb shell su 0 mount --bind "$DST_TMP" "$DST_MERGED" || true
adb shell su 0 mkdir -p /mnt/halium/merged/apex /mnt/halium/merged/linkerconfig
adb shell su 0 mount --rbind /apex /mnt/halium/merged/apex || true
adb shell su 0 mount --rbind /linkerconfig /mnt/halium/merged/linkerconfig || true

# Hotfix TLS-capable libhybris q linker + common (focal-compatible, zig-built).
# Never adb-push over an active bind source (nlink→0 → remount ENOENT).
# adb eats nested quotes — use one-shot su commands, not sh -c 'multiline'.
TLS_DIR="$REPO/builder/out/libhybris-tls"
Q_DST="/mnt/halium/merged/usr/lib/aarch64-linux-gnu/libhybris/linker/q.so"
C_DST="/mnt/halium/merged/usr/lib/aarch64-linux-gnu/libhybris-common.so.1.0.0"
Q_SRC="/data/local/tmp/q-tls.so"
C_SRC="/data/local/tmp/libhybris-common-tls.so"
if [ -f "$TLS_DIR/q.so" ] && [ -f "$TLS_DIR/libhybris-common.so.1.0.0" ]; then
    adb shell su 0 killall -9 lomiri mir_demo_server >/dev/null 2>&1 || true
    sleep 0.4
    adb shell su 0 umount -l "$Q_DST" >/dev/null 2>&1 || true
    adb shell su 0 umount -l "$C_DST" >/dev/null 2>&1 || true
    adb shell su 0 umount -l /mnt/halium/merged/mnt/halium/merged/usr/lib/aarch64-linux-gnu/libhybris/linker/q.so >/dev/null 2>&1 || true
    adb shell su 0 umount -l /mnt/halium/merged/mnt/halium/merged/usr/lib/aarch64-linux-gnu/libhybris-common.so.1.0.0 >/dev/null 2>&1 || true
    # Wait until file bind is gone (lazy umount is async).
    for _ in 1 2 3 4 5 6 7 8; do
        if adb shell su 0 cat /proc/mounts 2>/dev/null | grep -q 'libhybris/linker/q.so'; then
            sleep 0.25
        else
            break
        fi
    done
    adb shell su 0 mkdir -p /mnt/halium/merged/usr/lib/aarch64-linux-gnu/libhybris/linker
    # Push only after umount so we do not replace a live bind source inode.
    adb push "$TLS_DIR/q.so" "$Q_SRC"
    adb push "$TLS_DIR/libhybris-common.so.1.0.0" "$C_SRC"
    adb shell su 0 chmod 755 "$Q_SRC" "$C_SRC"
    if ! adb shell su 0 mount --bind "$Q_SRC" "$Q_DST"; then
        echo "ERROR: TLS bind failed for $Q_DST" >&2
        adb shell su 0 ls -la "$Q_SRC" "$Q_DST" >&2 || true
        adb shell su 0 cat /proc/mounts >&2 | grep q.so || true
        exit 1
    fi
    adb shell su 0 mount --bind "$C_SRC" "$C_DST" || {
        echo "ERROR: TLS bind failed for $C_DST" >&2
        exit 1
    }
    tls_abort="$(adb shell su 0 strings "$Q_DST" | grep -c 'TLS relocations not yet' || true)"
    tls_desc="$(adb shell su 0 strings "$Q_DST" | grep -c 'RELO TLSDESC' || true)"
    echo "hybris_tls_bind abort_string=${tls_abort:-0} tlsdesc_string=${tls_desc:-0}"
else
    echo "WARN: $TLS_DIR missing — using stock libhybris (TLS abort likely)" >&2
fi

# Halium-13 / stub android-side HWC2/UI compat (Mir android2).
COMPAT_DIR="$REPO/builder/out/halium13-compat"
if [ -f "$COMPAT_DIR/libhwc2_compat_layer.so" ]; then
    adb shell su 0 mkdir -p /data/local/tmp/halium13-compat
    # Prefer binder-free stubs when present; avoid pushing full Halium libui stack (heap corruption).
    for f in libhwc2_compat_layer.so libui_compat_layer.so libui_lock_shim.so \
             android.hardware.graphics.composer3-V1-ndk.so hwc2_present_probe; do
        [ -f "$COMPAT_DIR/$f" ] || continue
        adb push "$COMPAT_DIR/$f" /data/local/tmp/halium13-compat/"$f" >/dev/null
    done
    echo "halium13_compat_pushed"
if [ -f "$REPO/builder/out/egl_warmup" ]; then adb push "$REPO/builder/out/egl_warmup" /data/local/tmp/egl_warmup >/dev/null; fi
if [ -f "$REPO/builder/out/ual_systemd_stub.py" ]; then
  adb push "$REPO/builder/out/ual_systemd_stub.py" /data/local/tmp/ual_systemd_stub.py >/dev/null
  echo "ual_systemd_stub_pushed"
fi
if [ -f "$REPO/builder/out/maliit_im_force/libmaliit_im_force.so" ]; then
  adb push "$REPO/builder/out/maliit_im_force/libmaliit_im_force.so" /data/local/tmp/libmaliit_im_force.so >/dev/null
  echo "maliit_im_force_pushed"
fi
# morph-browser needs QtQuick.Controls (not always installed as Depends).
QML_CTRL_CACHE="$REPO/builder/cache/qml-debs/extract/usr/lib/aarch64-linux-gnu/qt5/qml/QtQuick"
if [ ! -d "$QML_CTRL_CACHE/Controls" ] && [ -d "$REPO/builder/cache/qml-debs" ]; then
    mkdir -p "$REPO/builder/cache/qml-debs/extract"
    for d in "$REPO/builder/cache/qml-debs"/*.deb; do
        [ -f "$d" ] || continue
        dpkg-deb -x "$d" "$REPO/builder/cache/qml-debs/extract/" 2>/dev/null || true
    done
fi
if [ -d "$QML_CTRL_CACHE/Controls" ]; then
    adb shell su 0 mkdir -p /data/local/tmp/qml-QtQuick-Controls \
        /data/local/tmp/qml-QtQuick-Controls.2 /data/local/tmp/qml-QtQuick-PrivateWidgets
    adb push "$QML_CTRL_CACHE/Controls/." /data/local/tmp/qml-QtQuick-Controls/ >/dev/null
    adb push "$QML_CTRL_CACHE/Controls.2/." /data/local/tmp/qml-QtQuick-Controls.2/ >/dev/null
    [ -d "$QML_CTRL_CACHE/PrivateWidgets" ] && \
      adb push "$QML_CTRL_CACHE/PrivateWidgets/." /data/local/tmp/qml-QtQuick-PrivateWidgets/ >/dev/null
    # adb strips multiline bodies of `su 0 sh -c '...'` — use a pushed script.
    adb push "$REPO/scripts/apply_qml_controls.sh" /data/local/tmp/apply_qml_controls.sh >/dev/null
    adb shell "su -c 'chmod 755 /data/local/tmp/apply_qml_controls.sh; /data/local/tmp/apply_qml_controls.sh'" \
        || echo "WARN: qml controls apply failed" >&2
fi
# Ubuntu.Components compat (Terminal click) + QtQuick.Templates.2 (Morph/Controls.2)
QML_ROOT_CACHE="$REPO/builder/cache/qml-debs/extract/usr/lib/aarch64-linux-gnu/qt5/qml"
if [ -f "$QML_ROOT_CACHE/Ubuntu/Components/qmldir" ] || [ -f "$QML_ROOT_CACHE/QtQuick/Templates.2/qmldir" ]; then
    _qml_tar_args=""
    [ -d "$QML_ROOT_CACHE/Ubuntu" ] && _qml_tar_args="$_qml_tar_args usr/lib/aarch64-linux-gnu/qt5/qml/Ubuntu"
    [ -d "$QML_ROOT_CACHE/QtQuick/Templates.2" ] && _qml_tar_args="$_qml_tar_args usr/lib/aarch64-linux-gnu/qt5/qml/QtQuick/Templates.2"
    # shellcheck disable=SC2086
    tar -C "$REPO/builder/cache/qml-debs/extract" -cf /tmp/qml-compat-push.tar $_qml_tar_args \
        2>/dev/null || true
    if [ -s /tmp/qml-compat-push.tar ]; then
        adb push /tmp/qml-compat-push.tar /data/local/tmp/qml-compat.tar >/dev/null
        adb push "$REPO/scripts/apply_qml_compat.sh" /data/local/tmp/apply_qml_compat.sh >/dev/null
        adb shell "su -c 'chmod 755 /data/local/tmp/apply_qml_compat.sh; /data/local/tmp/apply_qml_compat.sh'" \
            || echo "WARN: qml compat apply failed" >&2
    fi
fi
# Terminal needs Ubuntu.Components.Extras (alias of Lomiri.Components.Extras).
adb push "$REPO/scripts/apply_ubuntu_extras_alias.sh" /data/local/tmp/apply_ubuntu_extras_alias.sh >/dev/null
adb shell "su -c 'chmod 755 /data/local/tmp/apply_ubuntu_extras_alias.sh; /data/local/tmp/apply_ubuntu_extras_alias.sh'" \
    || echo "WARN: ubuntu extras alias failed" >&2
# Xwayland (hybris) + Terminal click unpack for this boot / until rootfs rebuild.
XW_CACHE="$REPO/builder/cache/xwayland-hybris"
if [ -x "$XW_CACHE/extract/usr/bin/Xwayland" ] || [ -f "$XW_CACHE/xwayland-hybris.deb" ]; then
    if [ ! -x "$XW_CACHE/extract/usr/bin/Xwayland" ] && [ -f "$XW_CACHE/xwayland-hybris.deb" ]; then
        mkdir -p "$XW_CACHE/extract"
        dpkg-deb -x "$XW_CACHE/xwayland-hybris.deb" "$XW_CACHE/extract/"
    fi
    if [ -x "$XW_CACHE/extract/usr/bin/Xwayland" ]; then
        adb push "$XW_CACHE/extract/usr/bin/Xwayland" /data/local/tmp/Xwayland >/dev/null
        adb shell "su -c 'test -x /mnt/halium/merged/usr/bin/Xwayland || { cat /data/local/tmp/Xwayland > /mnt/halium/merged/usr/bin/Xwayland; chmod 755 /mnt/halium/merged/usr/bin/Xwayland; }; test -x /mnt/halium/merged/usr/bin/Xwayland && echo xwayland_ready=yes'" \
            || echo "WARN: xwayland install failed" >&2
    fi
fi
TERM_CLICK="$REPO/builder/cache/openstore-clicks/com.ubuntu.terminal_arm64.click"
if [ -f "$TERM_CLICK" ]; then
    adb push "$TERM_CLICK" /data/local/tmp/com.ubuntu.terminal_arm64.click >/dev/null
    adb push "$REPO/scripts/write_terminal_desktops.py" /data/local/tmp/write_desktops.py >/dev/null
    adb shell su 0 sh -c '
CLICK=/data/local/tmp/com.ubuntu.terminal_arm64.click
DEST=/mnt/halium/merged/opt/click.ubuntu.com/com.ubuntu.terminal
if [ ! -x "$DEST/current/lib/aarch64-linux-gnu/bin/terminal" ]; then
  tmp=$(mktemp -d)
  cd "$tmp" && ar x "$CLICK" data.tar.gz control.tar.gz
  ver=$(tar -xOf control.tar.gz ./control | awk -F": " "/^Version:/{print \$2; exit}")
  mkdir -p "$DEST/$ver"
  tar -xzf data.tar.gz -C "$DEST/$ver"
  ln -sfn "$ver" "$DEST/current"
  rm -rf "$tmp"
fi
LOM=$(pidof lomiri | awk "{print \$1}")
if [ -n "$LOM" ]; then
  cp /data/local/tmp/write_desktops.py /proc/$LOM/root/tmp/write_desktops.py
  chroot /proc/$LOM/root /usr/bin/python3 /tmp/write_desktops.py && echo terminal_ready=yes
else
  echo terminal_bin_only=yes
fi
'
fi
if [ -f "$REPO/builder/out/libegl_es2_force.so" ]; then
    adb push "$REPO/builder/out/libegl_es2_force.so" /data/local/tmp/libegl_es2_force.so >/dev/null
    adb shell su 0 cp /data/local/tmp/libegl_es2_force.so /mnt/halium/merged/tmp/libegl_es2_force.so
    echo "libegl_es2_force_pushed"
fi
if [ -f "$REPO/builder/out/libwlegl_inject.so" ]; then
    adb push "$REPO/builder/out/libwlegl_inject.so" /data/local/tmp/libwlegl_inject.so >/dev/null
    adb shell su 0 cp /data/local/tmp/libwlegl_inject.so /mnt/halium/merged/tmp/libwlegl_inject.so
    echo "libwlegl_inject_pushed"
fi
# Qt apps need wayland QPA (qtubuntu/mirclient is deprecated); overlay may lack it.
if [ -d "$REPO/builder/out/qtwayland/usr" ]; then
    tar -C "$REPO/builder/out/qtwayland" -cf /tmp/qtwayland-rootfs.tar usr
    adb push /tmp/qtwayland-rootfs.tar /data/local/tmp/qtwayland-rootfs.tar >/dev/null
    # Avoid `adb shell su 0 sh -c 'multiline'` — adb strips the script body
    # ("sh: -c: requires an argument") and chroot then runs without root (EPERM).
    cat > /tmp/apply_qtwayland.sh << 'QTEOF'
#!/system/bin/sh
set -e
MERGED=/mnt/halium/merged
PLUGIN=$MERGED/usr/lib/aarch64-linux-gnu/qt5/plugins/platforms/libqwayland-egl.so
if [ ! -f "$PLUGIN" ]; then
  cp /data/local/tmp/qtwayland-rootfs.tar $MERGED/tmp/qtwayland-rootfs.tar
  chroot $MERGED /bin/tar -C / -xf /tmp/qtwayland-rootfs.tar
fi
if [ -f "$PLUGIN" ]; then
  echo qtwayland_overlay_applied=yes
fi
QTEOF
    adb push /tmp/apply_qtwayland.sh /data/local/tmp/apply_qtwayland.sh >/dev/null
    adb shell "su -c 'chmod 755 /data/local/tmp/apply_qtwayland.sh; /data/local/tmp/apply_qtwayland.sh'" \
        || echo "WARN: qtwayland apply failed" >&2
fi
else
    echo "WARN: $COMPAT_DIR missing — EGL_NOT_INITIALIZED likely" >&2
fi

# Detect NVT SPI storm (zero ABS events). Rebind is forbidden — reboot to clear.
HEAL_NVT="$REPO/scripts/heal_nvt_touch.sh"
if [ -f "$HEAL_NVT" ]; then
    adb push "$HEAL_NVT" /data/local/tmp/heal_nvt_touch.sh >/dev/null
    adb shell su 0 chmod 755 /data/local/tmp/heal_nvt_touch.sh
    if ! adb shell su 0 /data/local/tmp/heal_nvt_touch.sh; then
        echo "ERROR: NVT touch SPI storm detected — reboot the device, then re-run." >&2
        echo "       (Do not unbind NVT-ts; that triggers firmware rewrite loops.)" >&2
        exit 2
    fi
fi

# GPU prep: prefer system.img hal-gpu-bringup (via thin device_prep wrapper).
# Optional HWC inproc/patched blobs still pushed when built for this device.
PREP="$REPO/scripts/device_prep_lomiri_gpu.sh"
GPU_BRINGUP="$REPO/rootfs/overlay/usr/lib/ubuntu-gsi/hal-gpu-bringup.sh"
HWC_INPROC="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.inproc.so"
HWC_PATCH="$REPO/builder/out/hwc-patches/hwcomposer.mtk_common.patched.so"
adb shell su 0 mkdir -p /data/uhl_overlay/ubuntu-gsi-bin /data/uhl_overlay/halium-compat
if [ -f "$GPU_BRINGUP" ]; then
    adb push "$GPU_BRINGUP" /data/uhl_overlay/ubuntu-gsi-bin/hal-gpu-bringup.sh >/dev/null
    adb shell su 0 chmod 755 /data/uhl_overlay/ubuntu-gsi-bin/hal-gpu-bringup.sh
    adb push "$GPU_BRINGUP" /data/local/tmp/hal-gpu-bringup.sh >/dev/null
    adb shell su 0 chmod 755 /data/local/tmp/hal-gpu-bringup.sh
fi
if [ -f "$HWC_INPROC" ]; then
    adb push "$HWC_INPROC" /data/local/tmp/hwc_inproc.so >/dev/null
    adb push "$HWC_INPROC" /data/uhl_overlay/halium-compat/hwc_inproc.so >/dev/null
    echo "hwc_inproc_pushed"
fi
if [ -f "$HWC_PATCH" ]; then
    adb push "$HWC_PATCH" /data/local/tmp/hwc_patched.so >/dev/null
    adb push "$HWC_PATCH" /data/uhl_overlay/halium-compat/hwc_patched.so >/dev/null
fi
# Ship compat stubs into overlay path used by start-lomiri when img lacks them.
COMPAT_DIR="$REPO/builder/out/halium13-compat"
if [ -d "$COMPAT_DIR" ]; then
    for f in libui_compat_layer.so libhwc2_compat_layer.so; do
        [ -f "$COMPAT_DIR/$f" ] || continue
        adb push "$COMPAT_DIR/$f" /data/uhl_overlay/halium-compat/"$f" >/dev/null
    done
fi
if [ -f "$REPO/builder/out/egl_warmup" ]; then
    adb push "$REPO/builder/out/egl_warmup" /data/uhl_overlay/halium-compat/egl_warmup >/dev/null
    adb shell su 0 chmod 755 /data/uhl_overlay/halium-compat/egl_warmup
fi
adb push "$PREP" /data/local/tmp/device_prep_lomiri_gpu.sh >/dev/null
adb shell su 0 chmod 755 /data/local/tmp/device_prep_lomiri_gpu.sh
adb shell su 0 /data/local/tmp/device_prep_lomiri_gpu.sh

# Always bind Shell.qml bring-up fixes (forcedUnlock, wizard defer for full-greeter).
# noise patches only when LOMIRI_QML_NOISE_PATCHES=1.
QML_PATCH_DIR="$REPO/builder/out/qml-patches"
SH_DST="/mnt/halium/merged/usr/share/lomiri/Shell.qml"
if [ -f "$QML_PATCH_DIR/Shell.qml" ]; then
    adb push "$QML_PATCH_DIR/Shell.qml" /data/local/tmp/Shell.qml >/dev/null
    adb shell su 0 umount -l "$SH_DST" >/dev/null 2>&1 || true
    adb shell su 0 mount --bind /data/local/tmp/Shell.qml "$SH_DST" && echo "qml_shell_patched=yes"
fi
OS_DST="/mnt/halium/merged/usr/share/lomiri/OrientedShell.qml"
if [ -f "$QML_PATCH_DIR/OrientedShell.qml" ]; then
    adb push "$QML_PATCH_DIR/OrientedShell.qml" /data/local/tmp/OrientedShell.qml >/dev/null
    adb shell su 0 umount -l "$OS_DST" >/dev/null 2>&1 || true
    adb shell su 0 mount --bind /data/local/tmp/OrientedShell.qml "$OS_DST" && echo "qml_oriented_shell_patched=yes"
fi
if [ "${LOMIRI_QML_NOISE_PATCHES:-0}" = "1" ] && [ -f "$QML_PATCH_DIR/GreeterView.qml" ]; then
    adb push "$QML_PATCH_DIR/GreeterView.qml" /data/local/tmp/GreeterView.qml >/dev/null
    GV_DST="/mnt/halium/merged/usr/share/lomiri/Greeter/GreeterView.qml"
    adb shell su 0 umount -l "$GV_DST" >/dev/null 2>&1 || true
    adb shell su 0 mount --bind /data/local/tmp/GreeterView.qml "$GV_DST" && echo "qml_greeterview_patched=yes"
    if [ -f "$QML_PATCH_DIR/Clock.qml" ]; then
        adb push "$QML_PATCH_DIR/Clock.qml" /data/local/tmp/Clock.qml >/dev/null
        CK_DST="/mnt/halium/merged/usr/share/lomiri/Greeter/Clock.qml"
        adb shell su 0 umount -l "$CK_DST" >/dev/null 2>&1 || true
        adb shell su 0 mount --bind /data/local/tmp/Clock.qml "$CK_DST" && echo "qml_clock_patched=yes"
    fi
    if [ -f "$QML_PATCH_DIR/Wallpaper.qml" ]; then
        adb push "$QML_PATCH_DIR/Wallpaper.qml" /data/local/tmp/Wallpaper.qml >/dev/null
        WP_DST="/mnt/halium/merged/usr/share/lomiri/Components/Wallpaper.qml"
        adb shell su 0 umount -l "$WP_DST" >/dev/null 2>&1 || true
        adb shell su 0 mount --bind /data/local/tmp/Wallpaper.qml "$WP_DST" && echo "qml_wallpaper_patched=yes"
    fi
    if [ -f "$QML_PATCH_DIR/CoverPage.qml" ]; then
        adb push "$QML_PATCH_DIR/CoverPage.qml" /data/local/tmp/CoverPage.qml >/dev/null
        CP_DST="/mnt/halium/merged/usr/share/lomiri/Greeter/CoverPage.qml"
        adb shell su 0 umount -l "$CP_DST" >/dev/null 2>&1 || true
        adb shell su 0 mount --bind /data/local/tmp/CoverPage.qml "$CP_DST" && echo "qml_coverpage_patched=yes"
    fi
fi

# Patch Mir android2 EGL: RECORDABLE/0x3147 → DONT_CARE (keep fmt pref {2,3,1,4,5}).
# Prefer cached patched binary; adb pull of /mnt/halium/merged often fails without root
# (Permission denied) and previously continued into patch_mir_android2_egl.py with no file.
MIR_A2_SRC="$REPO/builder/out/mir-patches/graphics-android2.so.15"
MIR_A2_DST="/mnt/halium/merged/usr/lib/aarch64-linux-gnu/mir/server-platform/graphics-android2.so.15"
MIR_A2_CLEAN="/data/local/tmp/mirplat-a2/graphics-android2.so.15"
adb root >/dev/null 2>&1 || true
adb shell su 0 umount "$MIR_A2_DST" 2>/dev/null || true
NEED_PATCH=1
if [ -f "$MIR_A2_SRC" ] && [ "$(stat -c '%s' "$MIR_A2_SRC" 2>/dev/null || echo 0)" -gt 100000 ]; then
    NEED_PATCH=0
    echo "mir_android2_using_cache=$MIR_A2_SRC"
fi
if [ "$NEED_PATCH" = 1 ]; then
    rm -f /tmp/graphics-android2.so.15
    adb pull "$MIR_A2_CLEAN" /tmp/graphics-android2.so.15 >/dev/null 2>&1 || true
    if [ ! -s /tmp/graphics-android2.so.15 ]; then
        adb pull "$MIR_A2_DST" /tmp/graphics-android2.so.15 >/dev/null 2>&1 || true
    fi
    if [ ! -s /tmp/graphics-android2.so.15 ]; then
        # root-backed copy when pull is denied on the mount path
        adb exec-out su 0 cat "$MIR_A2_DST" > /tmp/graphics-android2.so.15 2>/dev/null || true
    fi
    if [ ! -s /tmp/graphics-android2.so.15 ]; then
        echo "ERROR: could not fetch graphics-android2.so.15 for EGL patch" >&2
        exit 1
    fi
    python3 "$REPO/scripts/patch_mir_android2_egl.py" /tmp/graphics-android2.so.15
fi
if [ -f "$MIR_A2_SRC" ]; then
    adb push "$MIR_A2_SRC" /data/local/tmp/graphics-android2.so.15 >/dev/null
    adb shell su 0 mount --bind /data/local/tmp/graphics-android2.so.15 "$MIR_A2_DST" && echo "mir_android2_egl_patched=yes"
fi

# Mir 1.8: is_output_active() drops all TOUCH_FRAME when touchscreen maps to output_id=0.
EVDEV_PATCH="$REPO/builder/out/mir-patches/input-evdev.so.7"
EVDEV_DST="/mnt/halium/merged/usr/lib/aarch64-linux-gnu/mir/server-platform/input-evdev.so.7"
if [ -f "$EVDEV_PATCH" ]; then
    adb push "$EVDEV_PATCH" /data/local/tmp/input-evdev.so.7 >/dev/null
    adb shell su 0 umount -l "$EVDEV_DST" >/dev/null 2>&1 || true
    adb shell su 0 mount --bind /data/local/tmp/input-evdev.so.7 "$EVDEV_DST" && echo "mir_evdev_output_active_patched=yes"
fi

# Power key → backlight toggle (Qt reports mtk-pmic-keys as Unknown).
adb push "$REPO/scripts/powerkey_blank.sh" /data/local/tmp/powerkey_blank.sh >/dev/null
adb shell "su -c 'chmod 755 /data/local/tmp/powerkey_blank.sh'"
adb shell "su -c '/data/local/tmp/powerkey_blank.sh --stop'" >/dev/null 2>&1 || true
adb shell "su -c 'rm -f /data/local/tmp/lomiri_fill_ct'" || true
adb shell "su -c '/data/local/tmp/powerkey_blank.sh >/data/local/tmp/powerkey_blank.out 2>&1 &'" || true
echo "powerkey_blank_started"
# HH-wallpaper: rootfs backgrounds/ is not writable (overlay upper denied). Skip mkdir.
# Default candidate Constants.defaultWallpaper (/usr/share/backgrounds/warty-*.png) still loads.

sz="$(adb shell su 0 wc -c "$DST_MERGED" | tr -d '\r' | awk '{print $1}')"
echo "merged_size=$sz"
if ! adb shell su 0 grep -F egl_hybris "$DST_MERGED" >/dev/null; then
    echo "ERROR: bound start-lomiri.sh is stale (missing egl_hybris)" >&2
    exit 1
fi
if [ "${sz:-0}" -lt 7400 ]; then
    echo "ERROR: merged still has old start-lomiri.sh ($sz bytes)" >&2
    exit 1
fi

# /dev/binderfs may be covered by empty tmpfs (often after lazy umount of
# shared /dev rbind) → Lomiri dies with "Binder driver could not be opened".
cat > /tmp/ensure_binderfs.sh << 'BEOF'
#!/system/bin/sh
# Do NOT `mount -t binder` here. That creates a fresh empty IPC domain while
# Android servicemanager still holds the old one → "Not able to get context
# object on /dev/binder" and Mir hangs. If nodes are gone, reboot is required.
set -e
if [ ! -c /dev/binderfs/binder ]; then
  echo "binderfs_ok=no"
  echo "ERROR: /dev/binderfs/binder missing (empty cover or unmounted)."
  echo "Reboot the device to restore Android binderfs, then re-run."
  ls -la /dev/binderfs 2>&1 || true
  exit 1
fi
if [ -d /mnt/halium/merged/dev ] && [ ! -c /mnt/halium/merged/dev/binderfs/binder ]; then
  # Shared mounts often already mirror host; only bind if needed.
  # NEVER umount -l merged binderfs (tears down host via peer group).
  mkdir -p /mnt/halium/merged/dev/binderfs
  mount --make-private /dev/binderfs 2>/dev/null || true
  mount --bind /dev/binderfs /mnt/halium/merged/dev/binderfs \
    || mount --rbind /dev/binderfs /mnt/halium/merged/dev/binderfs
  echo merged_binder_bound=yes
fi
if [ -c /dev/binderfs/binder ] && { [ -c /mnt/halium/merged/dev/binderfs/binder ] || [ ! -d /mnt/halium/merged/dev ]; }; then
  echo binderfs_ok=yes
  ls /dev/binderfs/binder /mnt/halium/merged/dev/binderfs/binder 2>/dev/null || true
else
  echo binderfs_ok=no
  ls -la /dev/binderfs /mnt/halium/merged/dev/binderfs 2>&1 || true
  exit 1
fi
BEOF
adb push /tmp/ensure_binderfs.sh /data/local/tmp/ensure_binderfs.sh >/dev/null
BINDER_OUT=$(adb shell "su -c 'chmod 755 /data/local/tmp/ensure_binderfs.sh; /data/local/tmp/ensure_binderfs.sh'" 2>&1) || {
    echo "$BINDER_OUT" >&2
    echo "ERROR: binderfs restore failed" >&2
    exit 1
}
echo "$BINDER_OUT"

: > "$HOST_LOG"
# Keep su in the foreground of adb; background only the host adb process.
# Use su -c (not `su 0 …`) so capabilities/chroot stay with root under adb quoting.
adb shell "su -c 'chroot /mnt/halium/merged /bin/bash /usr/lib/ubuntu-gsi/halium/start-lomiri.sh'" \
    >"$HOST_LOG" 2>&1 &
ADB_CHROOT_PID=$!
echo "chroot started (host pid $ADB_CHROOT_PID); waiting 25s"
sleep 25
echo "=== host log (startup) ==="
rg -n 'Pages\.qml|ReferenceError|Selected input|Output 1|Fatal signal|mode=|Mir failed|Binder driver|context object' "$HOST_LOG" || true
echo "=== pidof lomiri ==="
adb shell "su -c 'pidof lomiri || true'" || true
echo "=== logcat start-lomiri ==="
adb shell "su -c 'logcat -d -s start-lomiri'" | tail -30 || true
echo "=== key mir/egl ==="
adb shell "su -c 'logcat -d'" | grep -iE 'Selected driver|hwc2_compat|libui_compat|EGL_|CreateDisplay|library "|Fatal signal|not found|matching egl|display format|lcd-backlight|setPowerMode|context object|Mir failed' | tail -40 || true

# Leave lomiri running (adb chroot pid $ADB_CHROOT_PID); do not kill on script exit.



