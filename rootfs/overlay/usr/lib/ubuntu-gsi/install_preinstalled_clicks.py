#!/usr/bin/env python3
"""Install preinstalled .click packages under Halium (best-effort)."""
import os, subprocess, sys, glob, shutil
from pathlib import Path

CLICK_DIR = Path("/usr/share/ubuntu-gsi/preinstalled-clicks")
ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", **os.environ}

def run(cmd):
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, env=ENV)

# Ensure frameworks stubs
fw = Path("/usr/share/click/frameworks")
fw.mkdir(parents=True, exist_ok=True)
for name in ("ubuntu-sdk-20.04", "ubuntu-sdk-16.04", "ubuntu-sdk-16.04.5"):
    (fw / f"{name}.framework").write_text(name + "\n")

# Ensure ubuntu user
subprocess.run(["/usr/sbin/useradd", "-m", "-s", "/bin/bash", "ubuntu"], env=ENV)

opt = Path("/opt/click.ubuntu.com")
opt.mkdir(parents=True, exist_ok=True)
os.chmod(opt, 0o777)

ok = fail = 0
for click in sorted(CLICK_DIR.glob("*.click")):
    cmd = [
        "/usr/bin/click", "install",
        "--force-missing-framework", "--allow-unauthenticated",
        "--user=ubuntu", str(click),
    ]
    rc = run(cmd).returncode
    if rc != 0:
        # Manual register if package dir exists
        # click name is usually before _arm64
        fail += 1
        print("FAIL", click.name, flush=True)
    else:
        ok += 1
        print("OK", click.name, flush=True)

# Copy any desktop files into /usr/share/applications
apps = Path("/usr/share/applications")
apps.mkdir(parents=True, exist_ok=True)
for desk in Path("/opt/click.ubuntu.com").glob("*/*/share/applications/*.desktop"):
    dest = apps / desk.name
    shutil.copy2(desk, dest)
    print("desktop", dest, flush=True)
for desk in Path("/opt/click.ubuntu.com").glob("*/current/share/applications/*.desktop"):
    dest = apps / desk.name
    shutil.copy2(desk, dest)
    print("desktop", dest, flush=True)

print(f"SUMMARY ok={ok} fail={fail}", flush=True)
# list package dirs
print("packages:", [p.name for p in Path("/opt/click.ubuntu.com").iterdir() if p.is_dir() and not p.name.startswith(".")], flush=True)
