from pathlib import Path

p = Path("/usr/lib/python3/dist-packages/click_package/install.py")
text = p.read_text()

# 1) euid_access short-circuit for root
old1 = """    def _euid_access(self, username, path, mode):
        \"\"\"Like os.access, but for the effective UID.\"\"\"
        # TODO: Dropping privileges and calling"""
new1 = """    def _euid_access(self, username, path, mode):
        \"\"\"Like os.access, but for the effective UID.\"\"\"
        # Halium: setresuid+access fails on overlay; root can write via upperdir.
        if os.geteuid() == 0:
            return os.access(path, mode)
        # TODO: Dropping privileges and calling"""
if old1 in text:
    text = text.replace(old1, new1, 1)

# 2) no-op privilege drop under Halium (setresuid fails/breaks in Android su)
old2 = """    def _drop_privileges(self, username):
        if os.geteuid() != 0:
            return
        pw = pwd.getpwnam(username)"""
new2 = """    def _drop_privileges(self, username):
        if os.geteuid() != 0:
            return
        # Halium/Android: dropping to clickpkg breaks unpack on overlay mounts.
        if os.path.exists("/etc/ubuntu-gsi-release"):
            return
        pw = pwd.getpwnam(username)"""
if old2 not in text:
    raise SystemExit("drop_privileges block missing")
text = text.replace(old2, new2, 1)

p.write_text(text)
cache = Path("/usr/lib/python3/dist-packages/click_package/__pycache__")
if cache.is_dir():
    for c in cache.glob("install*.pyc"):
        c.unlink(missing_ok=True)
print("patched_ok")
