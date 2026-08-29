#!/usr/bin/env python3
from pathlib import Path
apps = Path("/usr/share/applications")
term_bin = "/opt/click.ubuntu.com/com.ubuntu.terminal/current/lib/aarch64-linux-gnu/bin/terminal"
term = f"""[Desktop Entry]
Name=Terminal
Comment=Terminal Emulator
Exec={term_bin} %u
Icon=utilities-terminal
Type=Application
Terminal=false
Categories=Utility;TerminalEmulator;
X-Lomiri-Touch=true
"""
htop = f"""[Desktop Entry]
Name=Htop
Exec={term_bin} -e htop
Icon=htop
Type=Application
Terminal=false
Categories=System;
"""
for name, body in (("ubuntu-terminal-app.desktop", term), ("htop.desktop", htop)):
    p = apps / name
    try:
        p.write_text(body)
        print("ok", name, p.stat().st_size)
    except OSError as e:
        print("fail", name, e)
        alt = Path("/data/local/tmp") / name
        alt.write_text(body)
        print("alt", alt)
print("xwayland", Path("/usr/bin/Xwayland").is_file())
print("termbin", Path(term_bin).is_file())
