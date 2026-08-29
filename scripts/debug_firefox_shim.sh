#!/system/bin/sh
LOM=$(pidof lomiri | awk '{print $1}')
rm -f /data/local/tmp/ff_cmds.txt /data/local/tmp/ff_post2.strace /data/local/tmp/ff_shim_test.txt
timeout 7 strace -f -e write -s 220 -p "$LOM" -o /data/local/tmp/ff_post2.strace >/dev/null 2>&1 &
SP=$!
sleep 0.5
(
  i=0
  while [ $i -lt 12 ]; do
    i=$((i+1))
    for p in $(ps -A -o PID,NAME,CMDLINE | grep -F /usr/lib/firefox | grep -v grep | awk '{print $1}'); do
      cmd=$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null)
      echo "t=$i pid=$p cmd=$cmd" >> /data/local/tmp/ff_cmds.txt
    done
    sleep 0.25
  done
) &
timeout 5 chroot /proc/$LOM/root /usr/bin/env \
  XDG_RUNTIME_DIR=/run/user/0 HOME=/root WAYLAND_DISPLAY=wayland-0 \
  MOZ_ENABLE_WAYLAND=1 GDK_BACKEND=wayland MOZ_WEBRENDER=0 \
  LD_PRELOAD=/tmp/libegl_es2_force.so:/usr/lib/aarch64-linux-gnu/libGLESv2_libhybris.so.2 \
  /usr/lib/firefox/firefox --desktop_file_hint=/usr/share/applications/firefox.desktop \
  >/data/local/tmp/ff_shim_test.txt 2>&1
echo rc=$?
kill $SP 2>/dev/null
wait $SP 2>/dev/null
echo '=== STDERR ==='
cat /data/local/tmp/ff_shim_test.txt
echo '=== CMDS ==='
sort -u /data/local/tmp/ff_cmds.txt 2>/dev/null | head -40
echo '=== MIR ==='
grep -E 'REJECTED|connection_is_allowed' /data/local/tmp/ff_post2.strace 2>/dev/null | head -25
