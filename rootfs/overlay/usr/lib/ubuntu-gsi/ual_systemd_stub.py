#!/usr/bin/env python3
# Minimal org.freedesktop.systemd1 on the session bus for lomiri-app-launch
# when real systemd --user cannot run (PID1 is Android init).
import os
import subprocess
import sys
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

SYSTEMD = "org.freedesktop.systemd1"
MANAGER_PATH = "/org/freedesktop/systemd1"
IFACE_MGR = "org.freedesktop.systemd1.Manager"
IFACE_SVC = "org.freedesktop.systemd1.Service"

def ensure_firefox_hint_wrapper():
    """Optional PATH shim; real launch uses firefox.real ELF via stub rewrite."""
    ff = "/usr/lib/firefox/firefox"
    ff_bin = "/usr/lib/firefox/firefox.bin"
    ff_real = "/usr/lib/firefox/firefox.real"
    ff_elf = "/usr/lib/firefox/firefox.elf"

    def _is_elf(path):
        try:
            if not os.path.isfile(path) or os.path.getsize(path) <= 10000:
                return False
            with open(path, "rb") as f:
                return f.read(4) == b"\x7fELF"
        except OSError:
            return False

    elf = next((p for p in (ff_real, ff_elf, ff_bin, ff) if _is_elf(p)), None)
    if not elf:
        return False
    try:
        import shutil

        if not _is_elf(ff_elf):
            shutil.copy2(elf, ff_elf)
            os.chmod(ff_elf, 0o755)
        if not _is_elf(ff_real):
            shutil.copy2(ff_elf if _is_elf(ff_elf) else elf, ff_real)
            os.chmod(ff_real, 0o755)
        if not _is_elf(ff_bin):
            shutil.copy2(ff_real, ff_bin)
            os.chmod(ff_bin, 0o755)
        # Keep tiny PATH wrapper pointing at real ELF.
        try:
            with open(ff, "rb") as f:
                already = f.read(2) == b"#!" and _is_elf(ff_real)
        except OSError:
            already = False
        if already:
            return True
        desk = "/usr/share/applications/firefox.desktop"
        with open(ff, "w", newline="\n") as f:
            f.write(
                "#!/bin/sh\n"
                "HINT=--desktop_file_hint=%s\n"
                "for a in \"$@\"; do\n"
                "  case \"$a\" in --desktop_file_hint=*) HINT=; break;; esac\n"
                "done\n"
                "ELF=/usr/lib/firefox/firefox.real\n"
                "[ -x \"$ELF\" ] || ELF=/usr/lib/firefox/firefox.elf\n"
                "[ -x \"$ELF\" ] || ELF=/usr/lib/firefox/firefox.bin\n"
                "if [ -n \"$HINT\" ]; then\n"
                "  exec \"$ELF\" \"$HINT\" \"$@\"\n"
                "else\n"
                "  exec \"$ELF\" \"$@\"\n"
                "fi\n" % desk
            )
        os.chmod(ff, 0o755)
        return True
    except Exception:
        return False

def _read_proc_environ(pid):
    out = {}
    try:
        with open("/proc/%d/environ" % int(pid), "rb") as f:
            raw = f.read().split(b"\0")
        for item in raw:
            if not item or b"=" not in item:
                continue
            k, v = item.split(b"=", 1)
            out[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
    except Exception:
        pass
    return out

def ensure_hybris_env(env):
    """Apps need the same hybris linker cone as lomiri; UAL Environment omits it."""
    prefixes = (
        "HYBRIS_", "ANDROID_", "EGL_", "LIBEGL", "LIBGLESV",
        "LD_LIBRARY_PATH", "HYBRIS_LINKER_DIR", "HYBRIS_LD_LIBRARY_PATH",
        "HYBRIS_EGLPLATFORM", "QSG_DISTANCEFIELD_TEXT",
    )
    lomiri_env = {}
    try:
        r = subprocess.check_output(["pidof", "lomiri"], stderr=subprocess.DEVNULL).decode().strip()
        if r:
            lomiri_env = _read_proc_environ(int(r.split()[0]))
    except Exception:
        lomiri_env = {}
    for k, v in lomiri_env.items():
        if any(k == p or k.startswith(p) for p in prefixes):
            if k not in env or not env.get(k):
                env[k] = v
    env.setdefault(
        "HYBRIS_LINKER_DIR",
        "/usr/lib/aarch64-linux-gnu/libhybris/linker",
    )
    env.setdefault(
        "LD_LIBRARY_PATH",
        "/usr/lib/ubuntu-gsi:/tmp:/usr/lib/aarch64-linux-gnu/libhybris",
    )
    # Prefer GSI/tmp shims (e.g. libQt5QuickTemplates2) ahead of broken overlay links.
    _extra_ld = "/usr/lib/ubuntu-gsi:/tmp:/data/local/tmp"
    _ld = env.get("LD_LIBRARY_PATH") or ""
    if not _ld.startswith("/usr/lib/ubuntu-gsi"):
        env["LD_LIBRARY_PATH"] = _extra_ld + (":" + _ld if _ld else "")
    elif "/data/local/tmp" not in _ld.split(":"):
        env["LD_LIBRARY_PATH"] = _ld.replace("/tmp", "/tmp:/data/local/tmp", 1)
    if "HYBRIS_LD_LIBRARY_PATH" not in env or not env.get("HYBRIS_LD_LIBRARY_PATH"):
        # Prefer lomiri's path; else build device-agnostic vendor cone (no SoC hardcode).
        parts = [
            "/tmp/hybris-alias",
            "/vendor/lib64/egl",
            "/vendor/lib64/hw",
            "/system_real/lib64/hw",
            "/system_real/lib64",
            "/apex/com.android.vndk.v34/lib64",
            "/apex/com.android.vndk.v33/lib64",
            "/apex/com.android.vndk.v32/lib64",
        ]
        try:
            for name in sorted(os.listdir("/vendor/lib64")):
                d = "/vendor/lib64/" + name
                if not os.path.isdir(d) or name in ("egl", "hw"):
                    continue
                # SoC subdir that looks like a GPU/HAL carrier
                try:
                    ents = os.listdir(d)
                except OSError:
                    continue
                if any(
                    e.startswith(("libGLES", "libEGL", "hwcomposer.", "gralloc."))
                    for e in ents
                ):
                    parts.insert(3, d)
        except OSError:
            pass
        env["HYBRIS_LD_LIBRARY_PATH"] = ":".join(parts)
    env.setdefault("EGL_PLATFORM", "hwcomposer")
    env.setdefault("HYBRIS_EGLPLATFORM", env.get("EGL_PLATFORM", "hwcomposer"))
    if not env.get("LIBEGL"):
        _gles = None
        _candidates = []
        for _root in ("/vendor/lib64/egl", "/vendor/lib/egl"):
            _mali = os.path.join(_root, "libGLES_mali.so")
            if os.path.isfile(_mali):
                _gles = "libGLES_mali.so"
                break
            try:
                for _n in sorted(os.listdir(_root)):
                    if _n.startswith("libGLES_") and _n.endswith(".so"):
                        _candidates.append(_n)
            except OSError:
                pass
        if not _gles and _candidates:
            _gles = _candidates[0]
        if not _gles:
            try:
                for name in sorted(os.listdir("/vendor/lib64")):
                    d = "/vendor/lib64/" + name
                    if not os.path.isdir(d) or name in ("egl", "hw"):
                        continue
                    try:
                        for _n in sorted(os.listdir(d)):
                            if _n.startswith("libGLES_") and _n.endswith(".so"):
                                _gles = _n
                                break
                    except OSError:
                        continue
                    if _gles:
                        break
            except OSError:
                pass
        if _gles:
            env["LIBEGL"] = _gles
            env["LIBGLESV2"] = _gles
    env.setdefault("ANDROID_ROOT", "/system_real")
    return env

def ensure_scale_env(env):
    """Force GRID_UNIT_PX / QTWEBKIT_DPR from live lomiri (ignore stale stub environ).

    UITK on Wayland overwrites gridUnit from wl_output scale (often 1 → 8px/gu)
    even when GRID_UNIT_PX is set. QT_SCALE_FACTOR=GRID_UNIT_PX/8 makes UCUnits
    report the same gridUnit as Lomiri Shell (runtime probe: 27 with factor 3.375).
    """
    lomiri_env = {}
    try:
        r = subprocess.check_output(
            ["pidof", "lomiri"], stderr=subprocess.DEVNULL
        ).decode().strip()
        if r:
            lomiri_env = _read_proc_environ(int(r.split()[0]))
    except Exception:
        lomiri_env = {}
    for key in ("GRID_UNIT_PX", "QTWEBKIT_DPR"):
        val = lomiri_env.get(key)
        if val:
            env[key] = val
    # Match Shell desired grid unit via Qt HiDPI (Wayland UITK ignores GRID_UNIT_PX alone).
    try:
        gup = float(env.get("GRID_UNIT_PX") or "0")
    except ValueError:
        gup = 0.0
    if gup >= 8.0:
        factor = gup / 8.0
        env["QT_SCALE_FACTOR"] = ("%.4f" % factor).rstrip("0").rstrip(".")
        env["QT_AUTO_SCREEN_SCALE_FACTOR"] = "0"
    return env

def ensure_client_gpu_env(env):
    """Force hybris Wayland-EGL for every UAL client (Mali is ES-only).

    Always applied — even when UAL already sets QT_QPA_PLATFORM=wayland —
    so LD_PRELOAD / EGL vendor JSON are never skipped.
    """
    qpa = env.get("QT_QPA_PLATFORM", "")
    if qpa in ("", "mirserver", "ubuntumirserver", "ubuntumirclient", "mirclient"):
        env["QT_QPA_PLATFORM"] = "wayland"
    env.setdefault("GDK_BACKEND", "wayland")
    env.setdefault("SDL_VIDEODRIVER", "wayland")
    if not env.get("WAYLAND_DISPLAY"):
        env["WAYLAND_DISPLAY"] = "wayland-0"
    for k in list(env.keys()):
        if k.startswith("MIR_SERVER_"):
            env.pop(k, None)
    env.pop("QT_QUICK_BACKEND", None)
    env.pop("QT_WAYLAND_CLIENT_BUFFER_INTEGRATION", None)
    env.pop("QT_WAYLAND_DISABLE_HW_INTEGRATION", None)
    env["EGL_PLATFORM"] = "wayland"
    env["HYBRIS_EGLPLATFORM"] = "wayland"
    env["QT_OPENGL"] = "es2"
    env["__EGL_VENDOR_LIBRARY_FILENAMES"] = (
        "/usr/share/glvnd/egl_vendor.d/10_libhybris.json"
    )
    env.setdefault("QML_DISABLE_DISK_CACHE", "1")
    # Soft keyboard: only libmaliitphablet* platforminputcontext exists on UT.
    env["QT_IM_MODULE"] = "maliitphablet"
    env.setdefault("GTK_IM_MODULE", "Maliit")

    # QtQuick.Controls for Morph etc. (overlay often blocks bind into system QML).
    _qml_extra = "/data/local/tmp/qml-extra"
    if os.path.isdir(_qml_extra):
        _prev = env.get("QML2_IMPORT_PATH") or ""
        if _qml_extra not in _prev.split(":"):
            env["QML2_IMPORT_PATH"] = (
                _qml_extra + (":" + _prev if _prev else "")
            )

    # Compositor-only inject must not reach clients (breaks toybox children).
    prev_parts = []
    for p in (env.get("LD_PRELOAD") or "").split(":"):
        if not p or "libwlegl_inject" in p:
            continue
        prev_parts.append(p)
    _shim = "/tmp/libegl_es2_force.so"
    _gles = "/usr/lib/aarch64-linux-gnu/libGLESv2_libhybris.so.2"
    preload = []
    if os.path.exists(_shim):
        preload.append(_shim)
    if os.path.exists(_gles):
        preload.append(_gles)
    for p in prev_parts:
        if p not in preload:
            preload.append(p)
    if preload:
        env["LD_PRELOAD"] = ":".join(preload)
    elif "LD_PRELOAD" in env:
        env.pop("LD_PRELOAD", None)
    return env

# qtmir SessionAuthorizer allows UAL-registered PIDs or argv --desktop_file_hint=.
# Stub StartTransientUnit alone does not register with ApplicationManager, so
# inject a hint for known desktop apps (and generic .desktop when present).
_DESKTOP_HINTS = {
    "lomiri-system-settings": "/usr/share/applications/lomiri-system-settings.desktop",
    "morph-browser": "/usr/share/applications/morph-browser.desktop",
    "firefox": "/usr/share/applications/firefox.desktop",
    "firefox.sh": "/usr/share/applications/firefox.desktop",
    "firefox.real": "/usr/share/applications/firefox.desktop",
    "firefox.elf": "/usr/share/applications/firefox.desktop",
    "firefox.bin": "/usr/share/applications/firefox.desktop",
    "dialer-app": "/usr/share/applications/dialer-app.desktop",
    "messaging-app": "/usr/share/applications/messaging-app.desktop",
    "address-book-app": "/usr/share/applications/address-book-app.desktop",
    "mediaplayer-app": "/usr/share/applications/mediaplayer-app.desktop",
}

def ensure_desktop_file_hint(exec_argv):
    if any(str(a).startswith("--desktop_file_hint") for a in exec_argv):
        return exec_argv
    app0 = exec_argv[0].rsplit("/", 1)[-1] if exec_argv else ""
    # Xwayland rejects unknown CLI flags; argv0 hint is applied by ensure_xwayland.
    if "Xwayland" in app0 or app0 in ("Xwayland", "start-xwayland-qtmir.sh"):
        return exec_argv
    desk = _DESKTOP_HINTS.get(app0)
    if not desk:
        cand = "/usr/share/applications/%s.desktop" % app0
        if os.path.isfile(cand):
            desk = cand
    if desk and os.path.isfile(desk):
        return list(exec_argv) + ["--desktop_file_hint=" + desk]
    return exec_argv

def ensure_xwayland():
    """Start qtmir-authorized Xwayland (:0) if missing. Runtime evidence: Firefox
    on Mir Wayland spawns SwComposite×64 and unbounded threads; X11 stays ~88."""
    if os.path.exists("/tmp/.X11-unix/X0"):
        return True
    xw = "/tmp/Xwayland"
    if not (os.path.isfile(xw) and os.access(xw, os.X_OK)):
        src = "/data/local/tmp/Xwayland"
        if os.path.isfile(src):
            try:
                import shutil

                shutil.copy2(src, xw)
                os.chmod(xw, 0o755)
            except OSError:
                return False
        else:
            return False
    libdir = "/tmp/x11libs"
    os.makedirs(libdir, exist_ok=True)
    for name in ("libXfont2.so.2", "libXfont2.so.2.0.0", "libdrihybris.so", "libfontenc.so.1"):
        dst = os.path.join(libdir, name)
        if os.path.isfile(dst):
            continue
        for src in ("/data/local/tmp/" + name, "/tmp/" + name):
            if os.path.isfile(src):
                try:
                    import shutil

                    shutil.copy2(src, dst)
                except OSError:
                    pass
                break
    # libXfont2.so.2 may need symlink
    so2 = os.path.join(libdir, "libXfont2.so.2")
    so200 = os.path.join(libdir, "libXfont2.so.2.0.0")
    if not os.path.isfile(so2) and os.path.isfile(so200):
        try:
            os.symlink("libXfont2.so.2.0.0", so2)
        except OSError:
            pass
    hint = "--desktop_file_hint=/usr/share/applications/xwayland.qtmir.desktop"
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = libdir + ":" + env.get("LD_LIBRARY_PATH", "")
    env.setdefault("XDG_RUNTIME_DIR", "/run/user/0")
    env.setdefault("WAYLAND_DISPLAY", "wayland-0")
    # argv0 carries desktop_file_hint for qtmir SessionAuthorizer.
    try:
        subprocess.Popen(
            [
                "/bin/bash", "-c",
                "exec -a %s %s :0 -ac -noreset -shm >>/data/local/tmp/xwayland.log 2>&1"
                % (repr(hint), repr(xw)),
            ],
            env=env,
            start_new_session=True,
        )
    except OSError:
        return False
    for _ in range(20):
        if os.path.exists("/tmp/.X11-unix/X0"):
            return True
        time.sleep(0.1)
    return os.path.exists("/tmp/.X11-unix/X0")

class Unit(dbus.service.Object):
    def __init__(self, bus, path, name, pid):
        dbus.service.Object.__init__(self, bus, path)
        self.name = name
        self.pid = int(pid)

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        if interface == IFACE_SVC and prop == "MainPID":
            return dbus.UInt32(self.pid)
        if interface == IFACE_SVC and prop == "ControlGroup":
            return dbus.String("")
        if interface == "org.freedesktop.systemd1.Unit" and prop == "ActiveState":
            return dbus.String("active" if self.pid else "inactive")
        raise dbus.exceptions.DBusException("org.freedesktop.DBus.Error.InvalidArgs", prop)

class Manager(dbus.service.Object):
    def __init__(self, bus):
        dbus.service.Object.__init__(self, bus, MANAGER_PATH)
        self.bus = bus
        self.units = {}  # name -> Unit
        self._n = 0

    @dbus.service.method(IFACE_MGR, in_signature="", out_signature="")
    def Subscribe(self):
        return

    @dbus.service.method(IFACE_MGR, in_signature="", out_signature="a(ssssssouso)")
    def ListUnits(self):
        out = []
        for name, u in self.units.items():
            out.append((name, "", "loaded", "active", "running", "", u._object_path, 0, "", "/"))
        return out

    @dbus.service.method(IFACE_MGR, in_signature="s", out_signature="o")
    def GetUnit(self, name):
        if name not in self.units:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.systemd1.NoSuchUnit", name)
        return dbus.ObjectPath(self.units[name]._object_path)

    @dbus.service.method(IFACE_MGR, in_signature="ssa(sv)a(sa(sv))", out_signature="o")
    def StartTransientUnit(self, name, mode, properties, deps):
        exec_argv = None
        env = os.environ.copy()
        cwd = None
        for key, val in properties:
            k = str(key)
            if k == "ExecStart":
                try:
                    first = val[0]
                    exec_argv = [str(x) for x in first[1]]
                    if not exec_argv:
                        exec_argv = [str(first[0])]
                except Exception:
                    pass
            elif k == "Environment":
                for item in val:
                    s = str(item)
                    if "=" in s:
                        a, b = s.split("=", 1)
                        env[a] = b
            elif k == "WorkingDirectory":
                cwd = str(val)

        if not exec_argv:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs", "no ExecStart")

        env.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        # UAL inherits Lomiri's Android-mixed PATH (/system/bin before /bin).
        # Terminal then execs /system/bin/sh and the session dies immediately.
        _ubuntu_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        _path = env.get("PATH", "")
        if "/system/" in _path or "/apex/" in _path or "/vendor/" in _path:
            env["PATH"] = _ubuntu_path
        elif "/usr/bin" not in _path:
            env["PATH"] = _ubuntu_path + ":" + _path
        env.setdefault("SHELL", "/bin/bash")

        ensure_hybris_env(env)
        ensure_client_gpu_env(env)
        ensure_scale_env(env)

        # App-specific env (legacy .desktop apps launched via UAL).
        app0 = (exec_argv[0].rsplit("/", 1)[-1] if exec_argv else "")
        _firefox_preexec = None
        if app0 in ("firefox", "firefox.sh") or app0.startswith("firefox"):
            _lom_before = None
            try:
                import subprocess as _sp

                _lom_before = (_sp.check_output(["pidof", "lomiri"], stderr=_sp.DEVNULL)
                               .decode().strip() or None)
            except Exception:
                _lom_before = None
            # After a thread-storm kill, refuse relaunch briefly (breaks UAL restart loop).
            try:
                with open("/data/local/tmp/firefox_storm_cooldown") as _cf:
                    _until = int(_cf.read().strip() or "0")
                if time.time() < _until:
                    raise dbus.exceptions.DBusException(
                        "org.freedesktop.DBus.Error.Failed",
                        "firefox disabled temporarily after thread storm")
            except (OSError, ValueError):
                pass
            # Runtime evidence: Mir Wayland → SwComposite thread storm + black window.
            # X11 via qtmir Xwayland stays ~88 threads and can paint.
            _xw_ok = ensure_xwayland()
            if _xw_ok:
                env["DISPLAY"] = ":0"
                env["GDK_BACKEND"] = "x11"
                env["MOZ_ENABLE_WAYLAND"] = "0"
                env.pop("WAYLAND_DISPLAY", None)
            else:
                env["MOZ_ENABLE_WAYLAND"] = "1"
                env.setdefault("GDK_BACKEND", "wayland")
                env.pop("DISPLAY", None)
            env["MOZ_WEBRENDER"] = "0"
            env.setdefault("MOZ_DISABLE_RDD_SANDBOX", "1")
            env.setdefault("MOZ_DISABLE_CONTENT_SANDBOX", "1")
            # Children exec without desktop_file_hint → qtmir REJECTS on Wayland.
            env["MOZ_FORCE_DISABLE_E10S"] = "1"
            # Mali/hybris: desktop GL ではなく EGL/GLES
            env.setdefault("MOZ_GMP_SANDBOX", "0")
            env.setdefault("MOZ_DISABLE_GFX_SANDBOX", "1")
            # Children exec without hint; inject via execve hook (Wayland path).
            _exechook = "/tmp/libfirefox_execve_hint.so"
            # GTK/Gecko breaks with the Morph/Qt EGL force preload.
            _parts = []
            for p in (env.get("LD_PRELOAD") or "").split(":"):
                if not p:
                    continue
                if "libegl_es2_force" in p or "libGLESv2_libhybris" in p:
                    continue
                _parts.append(p)
            _parts = [p for p in _parts if "libff_shm_xrgb" not in p]
            if (not _xw_ok) and os.path.isfile(_exechook) and "libfirefox_execve_hint" not in ":".join(
                _parts
            ):
                _parts.insert(0, _exechook)
            if _parts:
                env["LD_PRELOAD"] = ":".join(_parts)
            else:
                env.pop("LD_PRELOAD", None)
            env["GDK_GL"] = "disable"
            env["MOZ_ACCELERATED"] = "0"
            for _k in (
                "LIBEGL",
                "LIBGLESV2",
                "HYBRIS_EGLPLATFORM",
                "HYBRIS_LD_LIBRARY_PATH",
                "__EGL_VENDOR_LIBRARY_FILENAMES",
            ):
                env.pop(_k, None)
            if _xw_ok:
                # X11 needs font/drihybris libs for some paths.
                env["LD_LIBRARY_PATH"] = "/tmp/x11libs:" + env.get("LD_LIBRARY_PATH", "")
            # Refuse launch when compositor is already gone (stops respawn storm).
            if not _xw_ok:
                _wl = os.path.join(env.get("XDG_RUNTIME_DIR") or "/run/user/0",
                                   env.get("WAYLAND_DISPLAY") or "wayland-0")
                if not os.path.exists(_wl):
                    raise dbus.exceptions.DBusException(
                        "org.freedesktop.DBus.Error.Failed",
                        "wayland compositor not available: %s" % _wl)
            env["MOZ_CRASHREPORTER_DISABLE"] = "1"
            # Lomiri/UAL often pass HOME=/ ; treat as unset (must be before prefs).
            if not env.get("HOME") or env.get("HOME") in ("/", "/data", "/data/local/tmp"):
                env["HOME"] = "/root"
                os.makedirs("/root/.config", exist_ok=True)
            # Do NOT set RLIMIT_NPROC: it does not cap threads, and failed
            # utility-process forks can spin. Pathological growth is handled
            # by the sustained thread watchdog below (prior: 700+ → Lomiri death).
            _firefox_preexec = None
            # Persist single-process / no-GPU prefs (avoid compositor EGL_BAD_ALLOC).
            # Prior bug: HOME="/" is truthy so prefs went to /.mozilla (unused).
            try:
                _home = env["HOME"]
                _prof_root = os.path.join(_home, ".mozilla", "firefox")
                _body = (
                    'user_pref("browser.tabs.remote.autostart", false);\n'
                    'user_pref("browser.tabs.remote.autostart.2", false);\n'
                    'user_pref("layers.gpu-process.enabled", false);\n'
                    'user_pref("media.gpu-process.enabled", false);\n'
                    'user_pref("gfx.webrender.force-disabled", true);\n'
                    'user_pref("layers.acceleration.disabled", true);\n'
                    'user_pref("dom.ipc.processCount", 1);\n'
                    'user_pref("toolkit.startup.max_resumed_crashes", -1);\n'
                    'user_pref("browser.sessionstore.resume_from_crash", false);\n'
                )
                os.makedirs(_prof_root, exist_ok=True)
                _profile_dir = None
                _wrote = 0
                for _name in sorted(os.listdir(_prof_root)):
                    _d = os.path.join(_prof_root, _name)
                    if not os.path.isdir(_d) or _name.startswith("."):
                        continue
                    with open(os.path.join(_d, "user.js"), "w") as _f:
                        _f.write(_body)
                    _wrote += 1
                    if _name.endswith(".default-release"):
                        _profile_dir = _d
                    elif _profile_dir is None and _name.endswith(".default"):
                        _profile_dir = _d
                    elif _profile_dir is None:
                        _profile_dir = _d
                if _wrote == 0:
                    _profile_dir = os.path.join(_prof_root, "halium.default")
                    os.makedirs(_profile_dir, exist_ok=True)
                    with open(os.path.join(_profile_dir, "user.js"), "w") as _f:
                        _f.write(_body)
                    _ini = os.path.join(_prof_root, "profiles.ini")
                    if not os.path.isfile(_ini):
                        with open(_ini, "w") as _f:
                            _f.write(
                                "[General]\n"
                                "StartWithLastProfile=1\n\n"
                                "[Profile0]\n"
                                "Name=halium\n"
                                "IsRelative=1\n"
                                "Path=halium.default\n"
                                "Default=1\n"
                            )
            except OSError as _e:
                _profile_dir = None
            # /usr/lib/firefox rejects new files (overlay ENOTEMPTY). Never copy the
            # ELF to /tmp — Firefox resolves XPCOM relative to argv0 (Couldn't load XPCOM).
            def _firefox_elf_path():
                for cand in (
                    "/usr/lib/firefox/firefox",
                    "/usr/lib/firefox/firefox.bin",
                ):
                    try:
                        if (
                            os.path.isfile(cand)
                            and os.path.getsize(cand) > 10000
                            and os.access(cand, os.X_OK)
                        ):
                            with open(cand, "rb") as _f:
                                if _f.read(4) == b"\x7fELF":
                                    return cand
                    except OSError:
                        continue
                return None

            real_ff = _firefox_elf_path()
            # Do NOT run ensure_firefox_hint_wrapper here: it cannot create
            # firefox.real on this overlay and would risk replacing the only ELF.
            _rewrote = False
            if real_ff:
                _rest = [
                    a for a in exec_argv[1:]
                    if not str(a).startswith("--desktop_file_hint")
                    and str(a) not in ("-profile", "-P")
                    and not str(a).startswith("-profile")
                ]
                # Drop prior -profile value if present as separate argv.
                _cleaned = []
                _skip = False
                for a in _rest:
                    if _skip:
                        _skip = False
                        continue
                    if a in ("-profile", "-P"):
                        _skip = True
                        continue
                    _cleaned.append(a)
                exec_argv = [real_ff]
                if _profile_dir and os.path.isdir(_profile_dir):
                    exec_argv += ["-profile", _profile_dir]
                exec_argv += _cleaned
                _rewrote = True
        elif app0 == "htop":
            # Prefer Terminal click so htop has a real TTY window.
            term = "/opt/click.ubuntu.com/com.ubuntu.terminal/current/lib/aarch64-linux-gnu/bin/terminal"
            if os.path.isfile(term) and os.access(term, os.X_OK):
                exec_argv = [term, "-e", "htop"]
            else:
                env.setdefault("TERM", "xterm-256color")
        elif app0 in ("xgps", "xgpsspeed"):
            # GTK X11 tools; only viable if Xwayland is already up.
            if not env.get("DISPLAY") and os.path.exists("/tmp/.X11-unix/X0"):
                env["DISPLAY"] = ":0"
                env["GDK_BACKEND"] = "x11"
            env.setdefault("GDK_BACKEND", env.get("GDK_BACKEND", "x11"))
            if not env.get("DISPLAY"):
                env["DISPLAY"] = ":0"
        elif app0 == "morph-browser":
            # Runtime: EGL GPU backend → "No suitable graphics backend found" (abort).
            # --disable-gpu keeps Morph alive on hybris Wayland (verified A/B g1).
            env.setdefault("QTWEBENGINE_DISABLE_SANDBOX", "1")
            env.setdefault("QT_WEBENGINE_DISABLE_SANDBOX", "1")
            env["QTWEBENGINE_CHROMIUM_FLAGS"] = (
                "--disable-gpu --disable-gpu-compositing --no-sandbox"
            )
            # Symlink import trees break Controls.2 style URI (realpath outside import path).
            env["QT_QUICK_CONTROLS_STYLE"] = "Fusion"
            _ctrl2 = "/data/local/tmp/qml-extra/QtQuick/Controls.2"
            if os.path.isdir(_ctrl2):
                env["LD_LIBRARY_PATH"] = _ctrl2 + ":" + env.get("LD_LIBRARY_PATH", "")

        # Click packages: binary looks for $APP_DIR/qml/*.qml; HOME=/ → "//.config/…".
        home = env.get("HOME", "")
        if not home or home in ("/", "/data", "/data/local/tmp"):
            env["HOME"] = "/root"
            os.makedirs("/root/.config", exist_ok=True)
        resolved = exec_argv[0]
        if "/" not in resolved:
            import shutil
            which = shutil.which(resolved, path=env.get("PATH"))
            if which:
                exec_argv = [which] + exec_argv[1:]
                resolved = which

        click_marker = "/opt/click.ubuntu.com/"
        if resolved.startswith(click_marker):
            # /opt/click.ubuntu.com/<pkg>/<ver>/lib/.../bin/<app>
            parts = resolved.split("/")
            # ['', 'opt', 'click.ubuntu.com', pkg, ver, ...]
            if len(parts) >= 5:
                app_dir = "/".join(parts[:5])
                if parts[4] == "current" or True:
                    app_dir = os.path.realpath(app_dir)
                env["APP_DIR"] = app_dir
                env["UBUNTU_APPLICATION_PATH"] = app_dir
                cwd = app_dir
                qml_paths = [
                    app_dir + "/qml",
                    app_dir + "/lib/aarch64-linux-gnu",
                    env.get("QML2_IMPORT_PATH", ""),
                ]
                env["QML2_IMPORT_PATH"] = ":".join(p for p in qml_paths if p)
                libdir = app_dir + "/lib/aarch64-linux-gnu"
                if os.path.isdir(libdir):
                    env["LD_LIBRARY_PATH"] = libdir + ":" + env.get("LD_LIBRARY_PATH", "")
                env.setdefault("QML_DISABLE_DISK_CACHE", "1")
                # Click Terminal must not pick Android toybox as $SHELL.
                if "terminal" in resolved:
                    env["SHELL"] = "/bin/bash"
                    env["TERM"] = env.get("TERM") or "xterm-256color"
                    env["PATH"] = _ubuntu_path

        exec_argv = ensure_desktop_file_hint(exec_argv)

        self._n += 1
        path = "/org/freedesktop/systemd1/unit/ual_%d" % self._n
        try:
            _ff_err = None
            if exec_argv and "firefox" in str(exec_argv[0]):
                try:
                    _ff_err = open("/data/local/tmp/ff_spawn.log", "w")
                except OSError:
                    _ff_err = None
            elif exec_argv and "morph-browser" in str(exec_argv[0]):
                try:
                    _ff_err = open("/data/local/tmp/morph_spawn.log", "w")
                except OSError:
                    _ff_err = None
            proc = subprocess.Popen(
                exec_argv, env=env, cwd=cwd or None,
                start_new_session=True,
                preexec_fn=_firefox_preexec,
                stderr=_ff_err if _ff_err is not None else None,
                stdout=_ff_err if _ff_err is not None else None,
            )
            pid = proc.pid
            if exec_argv and "firefox" in exec_argv[0]:

                def _ff_thread_watch(p=proc, last=[0], over=[0]):
                    if p.poll() is not None:
                        return False
                    try:
                        n = len(os.listdir("/proc/%d/task" % p.pid))
                    except OSError:
                        return False
                    # Normal Firefox is often ~80–200 threads; prior death was 700+.
                    # Require sustained high count before SIGKILL (avoid 3s false kill).
                    if n >= 400:
                        over[0] += 1
                    else:
                        over[0] = 0
                    if over[0] >= 3:
                        try:
                            os.killpg(os.getpgid(p.pid), 9)
                        except OSError:
                            try:
                                os.kill(p.pid, 9)
                            except OSError:
                                pass
                        try:
                            with open("/data/local/tmp/firefox_storm_cooldown", "w") as _cf:
                                _cf.write(str(int(time.time()) + 120))
                        except OSError:
                            pass
                        return False
                    if n != last[0] and n >= 40:
                        last[0] = n
                    return True

                GLib.timeout_add(1000, _ff_thread_watch)
        except Exception as e:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.Failed", str(e))

        unit = Unit(self.bus, path, str(name), pid)
        self.units[str(name)] = unit

        def _watch_exit(p=proc, u=unit):
            rc = p.poll()
            if rc is None:
                return True
            u.pid = 0
            return False

        GLib.timeout_add(500, _watch_exit)
        self.UnitNew(str(name), dbus.ObjectPath(path))
        return dbus.ObjectPath(path)

    @dbus.service.signal(IFACE_MGR, signature="so")
    def UnitNew(self, name, path):
        pass

    @dbus.service.signal(IFACE_MGR, signature="so")
    def UnitRemoved(self, name, path):
        pass

def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = bus.request_name(SYSTEMD, dbus.bus.NAME_FLAG_REPLACE_EXISTING |
                            dbus.bus.NAME_FLAG_DO_NOT_QUEUE)
    if name != dbus.bus.REQUEST_NAME_REPLY_PRIMARY_OWNER and \
       name != dbus.bus.REQUEST_NAME_REPLY_ALREADY_OWNER:
        sys.stderr.write("failed to own %s\n" % SYSTEMD)
        sys.exit(1)
    Manager(bus)
    sys.stderr.write("ual_systemd_stub ready pid=%s\n" % os.getpid())
    GLib.MainLoop().run()

if __name__ == "__main__":
    main()

