#!/usr/bin/env python3
"""ReSA online installer — double-click ReSA-Setup.exe to install."""

from __future__ import annotations

import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

CREATE_NO_WINDOW = 0x08000000
MB_ICON_INFO = 0x40
MB_ICON_ERROR = 0x10


def get_bundle_dir() -> Path:
    meipass = getattr(sys, "_MEIPASS", "")
    if meipass:
        return Path(meipass)
    return Path(__file__).resolve().parent


def get_log_path() -> Path:
    return Path(os.environ.get("TEMP", ".")) / "ReSA-install.log"


def write_log(text: str) -> None:
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {text}"
    try:
        with get_log_path().open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def show_message(text: str, *, error: bool = False) -> None:
    import ctypes

    ctypes.windll.user32.MessageBoxW(
        0,
        text,
        "ReSA",
        MB_ICON_ERROR if error else MB_ICON_INFO,
    )


def read_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def server_to_install_base(server: str) -> str:
    base = (server or "").strip().rstrip("/")
    if base.startswith("wss://"):
        return "https://" + base[len("wss://") :] + "/download"
    if base.startswith("ws://"):
        return "http://" + base[len("ws://") :] + "/download"
    if base.startswith("https://"):
        return base + "/download"
    if base.startswith("http://"):
        return base + "/download"
    return "https://olxp.cc/download"


def load_install_base() -> str:
    cfg = read_json(get_bundle_dir() / "agent.config.json")
    if cfg.get("installBase"):
        return str(cfg["installBase"]).rstrip("/")
    return server_to_install_base(str(cfg.get("server", "wss://olxp.cc")))


def download_file(url: str, dest: Path) -> None:
    ctx = ssl.create_default_context()
    request = urllib.request.Request(url, headers={"User-Agent": "ReSA-Setup/1.0"})
    with urllib.request.urlopen(request, timeout=120, context=ctx) as response:
        data = response.read()
    dest.write_bytes(data)


def run_hidden(args: list[str]) -> None:
    flags = CREATE_NO_WINDOW if sys.platform == "win32" else 0
    subprocess.run(args, creationflags=flags, check=False)


def create_startup_shortcut(exe: Path, workdir: Path) -> None:
    startup = (
        Path(os.environ["APPDATA"])
        / "Microsoft"
        / "Windows"
        / "Start Menu"
        / "Programs"
        / "Startup"
    )
    startup.mkdir(parents=True, exist_ok=True)
    lnk = startup / "ReSA.lnk"
    ps = (
        "$ws = New-Object -ComObject WScript.Shell; "
        f"$sc = $ws.CreateShortcut('{lnk}'); "
        f"$sc.TargetPath = '{exe}'; "
        f"$sc.WorkingDirectory = '{workdir}'; "
        "$sc.WindowStyle = 7; "
        "$sc.Save()"
    )
    run_hidden(
        [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            ps,
        ]
    )


def main() -> None:
    write_log("setup start")
    try:
        base = load_install_base()
        install_dir = Path(os.environ["LOCALAPPDATA"]) / "ReSA"
        install_dir.mkdir(parents=True, exist_ok=True)
        exe = install_dir / "ReSA.exe"
        temp_exe = Path(os.environ["TEMP"]) / "ReSA-download.exe"
        url = f"{base.rstrip('/')}/ReSA.exe"
        write_log(f"download: {url}")

        if temp_exe.is_file():
            temp_exe.unlink()

        download_file(url, temp_exe)
        size = temp_exe.stat().st_size
        write_log(f"download ok: {size} bytes")
        if size < 1_048_576:
            raise RuntimeError(f"file too small: {size} bytes")

        run_hidden(["taskkill", "/F", "/IM", "ReSA.exe"])
        if exe.is_file():
            exe.unlink()
        temp_exe.replace(exe)
        write_log("copy ok")

        create_startup_shortcut(exe, install_dir)
        write_log("autostart ok")

        flags = CREATE_NO_WINDOW if sys.platform == "win32" else 0
        subprocess.Popen([str(exe)], cwd=str(install_dir), creationflags=flags)
        write_log("install complete")
        show_message("安装完成，程序已在后台启动。")
    except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as exc:
        write_log(f"setup error: {exc}")
        show_message(
            f"安装失败：{exc}\n\n请检查网络后重试。\n日志：{get_log_path()}",
            error=True,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
