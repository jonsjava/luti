"""Read the system clipboard, so ctrl+v pastes text copied in other programs.

Textual's own ctrl+v only pastes text copied inside the app, and some terminals
(or embedded terminal panes) do not pass their paste shortcut through. This tries
the usual clipboard tools, then Tk (part of most Python installs), and returns
None when none of them can read the clipboard.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

TIMEOUT = 2.0

_TK = (
    "import sys, tkinter\n"
    "r = tkinter.Tk(); r.withdraw()\n"
    "try:\n"
    "    sys.stdout.write(r.clipboard_get())\n"
    "finally:\n"
    "    r.destroy()\n"
)


def _commands() -> list[list[str]]:
    cmds: list[list[str]] = []
    if os.environ.get("WAYLAND_DISPLAY"):
        cmds.append(["wl-paste", "--no-newline"])
    if os.environ.get("DISPLAY"):
        cmds.append(["xclip", "-selection", "clipboard", "-o"])
        cmds.append(["xsel", "--clipboard", "--output"])
    cmds += [["pbpaste"], ["termux-clipboard-get"], ["powershell.exe", "-NoProfile", "-Command", "Get-Clipboard"]]
    found = [c for c in cmds if shutil.which(c[0])]
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY") or sys.platform in ("darwin", "win32"):
        found.append([sys.executable, "-I", "-c", _TK])
    return found


def read_system_clipboard() -> str | None:
    """The system clipboard's text, or None when it cannot be read."""
    for cmd in _commands():
        try:
            out = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode == 0:
            text = out.stdout.decode("utf-8", "replace")
            if cmd[0] == "powershell.exe":
                text = text.replace("\r\n", "\n").removesuffix("\n")
            return text
    return None


def _write_commands() -> list[list[str]]:
    cmds: list[list[str]] = []
    if os.environ.get("WAYLAND_DISPLAY"):
        cmds.append(["wl-copy"])
    if os.environ.get("DISPLAY"):
        cmds.append(["xclip", "-selection", "clipboard", "-i"])
        cmds.append(["xsel", "--clipboard", "--input"])
    cmds += [["pbcopy"], ["termux-clipboard-set"], ["clip.exe"]]
    return [c for c in cmds if shutil.which(c[0])]


def write_system_clipboard(text: str) -> bool:
    """Put text on the system clipboard; False when no tool could."""
    for cmd in _write_commands():
        try:
            # No pipes on stdout/stderr: wl-copy stays in the background to serve the
            # clipboard and would hold them open until the timeout.
            out = subprocess.run(cmd, input=text.encode("utf-8"), stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, timeout=TIMEOUT)
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode == 0:
            return True
    return False
