#!/usr/bin/env python3
"""Windows remote screen agent — capture screen and execute control commands."""

from __future__ import annotations

import argparse
import asyncio
import base64
import ctypes
import json
import os
import platform
import re
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import cv2
import mss
import numpy as np
import websockets
from pynput._util.win32 import KeyTranslator
from pynput.keyboard import Controller as KeyboardController
from pynput.keyboard import Key
from pynput.keyboard import KeyCode
from pynput.keyboard import Listener as KeyboardListener
from pynput.mouse import Button
from pynput.mouse import Controller as MouseController

try:
    from _version import VERSION as AGENT_VERSION
except ImportError:
    AGENT_VERSION = "dev"

UPDATE_INITIAL_DELAY = 120
UPDATE_CHECK_INTERVAL = 6 * 3600
CREATE_NO_WINDOW = 0x08000000
CREATE_NEW_PROCESS_GROUP = 0x00000200
TERMINAL_SUBPROCESS_FLAGS = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
MAX_TERMINAL_OUTPUT_BYTES = 65536
_update_exit_requested = False
_terminal_session_cwd: Optional[str] = None

KEY_MAP = {
    "enter": Key.enter,
    "tab": Key.tab,
    "esc": Key.esc,
    "escape": Key.esc,
    "backspace": Key.backspace,
    "delete": Key.delete,
    "space": Key.space,
    "shift": Key.shift,
    "ctrl": Key.ctrl,
    "control": Key.ctrl,
    "alt": Key.alt,
    "up": Key.up,
    "down": Key.down,
    "left": Key.left,
    "right": Key.right,
    "home": Key.home,
    "end": Key.end,
    "pageup": Key.page_up,
    "pagedown": Key.page_down,
    "insert": Key.insert,
    "f1": Key.f1,
    "f2": Key.f2,
    "f3": Key.f3,
    "f4": Key.f4,
    "f5": Key.f5,
    "f6": Key.f6,
    "f7": Key.f7,
    "f8": Key.f8,
    "f9": Key.f9,
    "f10": Key.f10,
    "f11": Key.f11,
    "f12": Key.f12,
}

mouse = MouseController()
keyboard = KeyboardController()

REMOTE_INPUT_IGNORE_SEC = 0.35
remote_input_ignore_until = 0.0
keyboard_chars: list[str] = []
keyboard_last_at = 0.0
ime_last_commit = ""
key_translator = KeyTranslator()
last_keyboard_sent = ""
last_keyboard_sent_at = 0.0

FLUSH_KEYS = frozenset({Key.enter, Key.space, Key.tab})
FLUSH_VKS = frozenset({0x0D, 0x20, 0x09})  # enter, space, tab
IGNORED_KEYS = frozenset({
    Key.shift, Key.shift_l, Key.shift_r,
    Key.ctrl, Key.ctrl_l, Key.ctrl_r,
    Key.alt, Key.alt_l, Key.alt_r, Key.alt_gr,
    Key.caps_lock, Key.num_lock, Key.scroll_lock,
    Key.cmd, Key.cmd_l, Key.cmd_r,
})


def mark_remote_input() -> None:
    global remote_input_ignore_until
    remote_input_ignore_until = time.time() + REMOTE_INPUT_IGNORE_SEC


def is_remote_input() -> bool:
    return time.time() < remote_input_ignore_until


def normalize_char(ch: str) -> str:
    if ch == "\r":
        return "\n"
    return ch


def format_named_key(key: Key) -> str:
    if key == Key.space:
        return " "
    if key == Key.enter:
        return "\n"
    if key == Key.tab:
        return "\t"
    name = str(key).replace("Key.", "")
    return f"[{name}]"


def key_scan_code(key) -> Optional[int]:
    return getattr(key, "_scan", None) or getattr(key, "scan", None)


def key_vk_code(key) -> Optional[int]:
    vk = getattr(key, "vk", None)
    if vk is not None:
        return int(vk)
    if isinstance(key, Key):
        value = getattr(key, "value", None)
        if value is not None:
            return getattr(value, "vk", None)
    return None


def build_keyboard_state() -> ctypes.Array:
    user32 = ctypes.windll.user32
    state = (ctypes.c_ubyte * 256)()
    user32.GetKeyboardState(state)
    for vk in (0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5):
        if user32.GetAsyncKeyState(vk) & 0x8000:
            state[vk] |= 0x80
    if user32.GetKeyState(0x14) & 1:
        state[0x14] = 1
    return state


def vk_to_unicode(vk: Optional[int], scan: Optional[int] = None) -> Optional[str]:
    if vk is None or sys.platform != "win32":
        return None

    user32 = ctypes.windll.user32
    if scan is None:
        scan = user32.MapVirtualKeyW(vk, 0)
    if not scan:
        return None

    state = build_keyboard_state()
    buf = ctypes.create_unicode_buffer(8)
    count = user32.ToUnicode(vk, scan, state, buf, 8, 0)
    if count == 1 and buf[0]:
        ch = normalize_char(buf[0])
        if ch.isprintable() or ch in "\n\t":
            return ch
    return None


def vk_alnum_fallback(vk: int) -> Optional[str]:
    user32 = ctypes.windll.user32
    shift = bool(user32.GetAsyncKeyState(0x10) & 0x8000)
    caps = bool(user32.GetKeyState(0x14) & 1)
    if 0x41 <= vk <= 0x5A:
        upper = shift ^ caps
        ch = chr(vk)
        return ch if upper else ch.lower()
    if 0x30 <= vk <= 0x39:
        return chr(vk)
    if 0x60 <= vk <= 0x69:
        return chr(vk - 0x60 + ord("0"))
    return None


def char_from_scan(scan: int, listener: Optional[KeyboardListener] = None) -> Optional[str]:
    translator = getattr(listener, "_translator", None) if listener else None
    if translator is None:
        translator = key_translator
    try:
        ch = translator.char_from_scan(scan)
    except Exception:
        return None
    if not ch:
        return None
    ch = normalize_char(ch)
    if ch.isprintable() or ch in "\n\t":
        return ch
    return None


def read_ime_commit() -> Optional[str]:
    if sys.platform != "win32":
        return None

    try:
        imm32 = ctypes.windll.imm32
        user32 = ctypes.windll.user32
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return None

        himc = imm32.ImmGetContext(hwnd)
        if not himc:
            return None

        try:
            gcs_result = 0x0800
            size = imm32.ImmGetCompositionStringW(himc, gcs_result, None, 0)
            if size <= 0:
                return None
            buf = ctypes.create_unicode_buffer(size // 2 + 1)
            copied = imm32.ImmGetCompositionStringW(himc, gcs_result, buf, size + 2)
            if copied <= 0:
                return None
            return buf.value or None
        finally:
            imm32.ImmReleaseContext(hwnd, himc)
    except Exception:
        return None


def poll_ime_commit() -> Optional[str]:
    global ime_last_commit
    text = read_ime_commit()
    if not text or text == ime_last_commit:
        return None
    ime_last_commit = text
    return text


def key_press_to_text(key, listener: Optional[KeyboardListener] = None) -> Optional[str]:
    if key is None or key in IGNORED_KEYS:
        return None

    if listener is not None:
        try:
            key = listener.canonical(key)
        except Exception:
            pass

    if isinstance(key, Key):
        return format_named_key(key)

    char = getattr(key, "char", None)
    if char:
        ch = normalize_char(char)
        if ch.isprintable() or ch in "\n\t":
            return ch

    scan = key_scan_code(key)
    if scan is not None:
        resolved = char_from_scan(scan, listener)
        if resolved:
            return resolved

    vk = key_vk_code(key)
    if vk is not None:
        if vk in FLUSH_VKS:
            return {0x0D: "\n", 0x20: " ", 0x09: "\t"}[vk]
        resolved = vk_to_unicode(vk, scan)
        if resolved:
            return resolved
        resolved = vk_alnum_fallback(vk)
        if resolved:
            return resolved

    return None


def should_flush_key(key) -> bool:
    if key in FLUSH_KEYS:
        return True
    vk = key_vk_code(key)
    return vk in FLUSH_VKS if vk is not None else False


def get_app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def get_settings_dir() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", "")) / "ReSA"


def get_settings_path() -> Path:
    return get_settings_dir() / "settings.json"


def get_log_path() -> Path:
    return get_settings_dir() / "agent.log"


def get_device_id_path() -> Path:
    return get_settings_dir() / "device.id"


def sanitize_device_id(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", value.strip())
    cleaned = cleaned.strip("-_")
    return cleaned[:48] or "PC-UNKNOWN"


def agent_log(message: str) -> None:
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {message}"
    print(line, flush=True)
    try:
        log_dir = get_settings_dir()
        log_dir.mkdir(parents=True, exist_ok=True)
        with get_log_path().open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def ensure_device_id(explicit: Optional[str] = None) -> str:
    if explicit and explicit.strip():
        device_id = sanitize_device_id(explicit)
        get_settings_dir().mkdir(parents=True, exist_ok=True)
        get_device_id_path().write_text(device_id, encoding="utf-8")
        return device_id

    saved_path = get_device_id_path()
    if saved_path.is_file():
        saved = saved_path.read_text(encoding="utf-8").strip()
        if saved:
            return sanitize_device_id(saved)

    host = sanitize_device_id(socket.gethostname())[:16]
    suffix = uuid.uuid4().hex[:8].upper()
    device_id = sanitize_device_id(f"{host}-{suffix}" if host else f"PC-{suffix}")

    get_settings_dir().mkdir(parents=True, exist_ok=True)
    saved_path.write_text(device_id, encoding="utf-8")
    agent_log(f"Generated device ID: {device_id}")
    return device_id


def read_json_file(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def normalize_auto_screenshot_interval(value: Any) -> int:
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return 0
    if seconds <= 0:
        return 0
    return max(10, min(seconds, 3600))


class AutoScreenshotState:
    def __init__(self, interval: int = 0) -> None:
        self.interval = normalize_auto_screenshot_interval(interval)
        self.changed = asyncio.Event()

    def update(self, interval: int) -> int:
        self.interval = normalize_auto_screenshot_interval(interval)
        self.changed.set()
        return self.interval


def load_bundled_config() -> dict[str, Any]:
    candidates = []
    meipass = getattr(sys, "_MEIPASS", "")
    if meipass:
        candidates.append(Path(meipass) / "agent.config.json")
    candidates.append(get_app_dir() / "agent.config.json")
    for path in candidates:
        if path.is_file():
            return read_json_file(path)
    return {}


def resolve_settings(args: argparse.Namespace) -> dict[str, Any]:
    cfg: dict[str, Any] = {}
    cfg.update(load_bundled_config())
    cfg.update(read_json_file(get_settings_path()))

    if args.config:
        cfg.update(read_json_file(Path(args.config)))

    explicit_device_id = args.device_id or cfg.get("deviceId") or ""
    device_id = ensure_device_id(explicit_device_id or None)
    return {
        "server": args.server or cfg.get("server") or "ws://localhost:8080",
        "device_id": device_id,
        "token": args.token or cfg.get("token") or "remote-screen-dev",
        "monitor": args.monitor if args.monitor is not None else int(cfg.get("monitor", 1)),
        "fps": args.fps if args.fps is not None else int(cfg.get("fps", 12)),
        "quality": args.quality if args.quality is not None else int(cfg.get("quality", 55)),
        "stream_width": (
            args.stream_width
            if args.stream_width is not None
            else int(cfg.get("streamWidth", cfg.get("stream_width", 0)))
        ),
    }


def build_ws_url(server: str, device_id: str, token: str) -> str:
    base = server.rstrip("/")
    if base.startswith("http://"):
        base = "ws://" + base[len("http://") :]
    elif base.startswith("https://"):
        base = "wss://" + base[len("https://") :]
    elif not base.startswith("ws"):
        base = "ws://" + base
    return (
        f"{base}/ws?role=agent&deviceId={device_id}"
        f"&token={token}"
    )


def resolve_key(value: str | int):
    if isinstance(value, int):
        return value
    text = str(value).lower()
    if text in KEY_MAP:
        return KEY_MAP[text]
    if len(str(value)) == 1:
        return value
    return None


def _read_clipboard_ctypes() -> Optional[str]:
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    CF_UNICODETEXT = 13
    CF_TEXT = 1

    for _ in range(8):
        if user32.OpenClipboard(0):
            break
        time.sleep(0.05)
    else:
        return None

    try:
        if user32.IsClipboardFormatAvailable(CF_UNICODETEXT):
            handle = user32.GetClipboardData(CF_UNICODETEXT)
            if handle:
                data = kernel32.GlobalLock(handle)
                if data:
                    try:
                        text = ctypes.wstring_at(data)
                        if text:
                            return text.strip("\x00")
                    finally:
                        kernel32.GlobalUnlock(handle)

        if user32.IsClipboardFormatAvailable(CF_TEXT):
            handle = user32.GetClipboardData(CF_TEXT)
            if handle:
                data = kernel32.GlobalLock(handle)
                if data:
                    try:
                        raw = ctypes.string_at(data)
                        for enc in ("gbk", "utf-8", "latin-1"):
                            try:
                                return raw.decode(enc).strip("\x00")
                            except UnicodeDecodeError:
                                continue
                    finally:
                        kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()
    return None


def get_clipboard_text() -> Optional[str]:
    if sys.platform != "win32":
        return None

    try:
        text = _read_clipboard_ctypes()
        if text and text.strip():
            return text
    except Exception:
        pass
    return None


async def clipboard_loop(ws) -> None:
    last_sent = ""
    max_len = 4000
    agent_log("clipboard monitor started")

    while True:
        await asyncio.sleep(0.5)
        try:
            text = get_clipboard_text()
        except Exception as exc:
            agent_log(f"clipboard read error: {exc}")
            continue

        if not text or text == last_sent:
            continue

        last_sent = text
        truncated = len(text) > max_len
        payload = {
            "type": "clipboard_copy",
            "content": text[:max_len],
            "truncated": truncated,
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        try:
            await ws.send(json.dumps(payload))
            preview = text[:40].replace("\n", " ")
            agent_log(f"clipboard sent: {preview}")
        except Exception as exc:
            agent_log(f"clipboard send error: {exc}")
            return


async def send_keyboard_input(ws, content: str) -> None:
    global last_keyboard_sent, last_keyboard_sent_at
    if not content:
        return
    now = time.time()
    if content == last_keyboard_sent and now - last_keyboard_sent_at < 1.0:
        return
    last_keyboard_sent = content
    last_keyboard_sent_at = now
    max_len = 2000
    truncated = len(content) > max_len
    payload = {
        "type": "keyboard_input",
        "content": content[:max_len],
        "truncated": truncated,
        "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    await ws.send(json.dumps(payload))
    preview = content[:40].replace("\n", "\\n")
    agent_log(f"keyboard sent: {preview}")


async def flush_keyboard_buffer(ws) -> None:
    global keyboard_chars
    if not keyboard_chars:
        return
    content = "".join(keyboard_chars)
    keyboard_chars = []
    await send_keyboard_input(ws, content)


async def check_ime_after_press(ws) -> None:
    await asyncio.sleep(0.05)
    ime_text = poll_ime_commit()
    if not ime_text:
        return
    global keyboard_last_at
    keyboard_last_at = time.time()
    await send_keyboard_input(ws, ime_text)


def append_keyboard_text(ws, loop, text: str, key) -> None:
    global keyboard_chars, keyboard_last_at

    def schedule(coro) -> None:
        asyncio.run_coroutine_threadsafe(coro, loop)

    keyboard_last_at = time.time()
    if should_flush_key(key):
        keyboard_chars.append(text)
        schedule(flush_keyboard_buffer(ws))
        return

    if len(text) == 1:
        keyboard_chars.append(text)
        if len(keyboard_chars) >= 80:
            schedule(flush_keyboard_buffer(ws))
        return

    schedule(flush_keyboard_buffer(ws))
    schedule(send_keyboard_input(ws, text))


async def keyboard_loop(ws) -> None:
    global keyboard_chars, keyboard_last_at, last_keyboard_sent, last_keyboard_sent_at
    keyboard_chars = []
    keyboard_last_at = 0.0
    last_keyboard_sent = ""
    last_keyboard_sent_at = 0.0
    loop = asyncio.get_event_loop()
    agent_log("keyboard monitor started")

    def schedule(coro) -> None:
        asyncio.run_coroutine_threadsafe(coro, loop)

    def on_press(key, injected: bool = False) -> None:
        if injected or is_remote_input() or key is None:
            return

        if key == Key.backspace:
            if keyboard_chars:
                keyboard_chars.pop()
            return

        text = key_press_to_text(key, listener)
        if text:
            append_keyboard_text(ws, loop, text, key)

        if should_flush_key(key):
            schedule(check_ime_after_press(ws))

    listener = KeyboardListener(on_press=on_press)
    listener.start()

    try:
        while True:
            await asyncio.sleep(1.0)
            if keyboard_chars and time.time() - keyboard_last_at >= 1.5:
                await flush_keyboard_buffer(ws)
    finally:
        listener.stop()


FILE_MAX_ENTRIES = 500
FILE_MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024


def file_list_drives() -> list[dict]:
    entries = []
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        root = f"{letter}:\\"
        if os.path.isdir(root):
            entries.append({"name": root, "dir": True, "size": 0, "mtime": 0})
    return entries


def file_normalize_path(path: str) -> Path:
    raw = str(path or "").strip()
    if not raw:
        raise ValueError("empty path")
    return Path(raw)


def file_list_directory(path: str) -> dict:
    target = file_normalize_path(path)
    if not target.exists():
        raise FileNotFoundError("path not found")
    if not target.is_dir():
        raise NotADirectoryError("not a directory")
    entries = []
    try:
        items = sorted(
            target.iterdir(),
            key=lambda item: (not item.is_dir(), item.name.lower()),
        )
    except OSError as exc:
        raise PermissionError(str(exc)) from exc
    for item in items[:FILE_MAX_ENTRIES]:
        try:
            stat = item.stat()
            entries.append(
                {
                    "name": item.name,
                    "dir": item.is_dir(),
                    "size": stat.st_size if item.is_file() else 0,
                    "mtime": stat.st_mtime,
                }
            )
        except OSError:
            entries.append(
                {
                    "name": item.name,
                    "dir": item.is_dir(),
                    "size": 0,
                    "mtime": 0,
                }
            )
    return {"path": str(target.resolve()), "entries": entries}


def file_read_download(path: str) -> dict:
    target = file_normalize_path(path)
    if not target.is_file():
        raise FileNotFoundError("not a file")
    size = target.stat().st_size
    if size > FILE_MAX_DOWNLOAD_BYTES:
        raise ValueError(
            f"file too large ({size} bytes, max {FILE_MAX_DOWNLOAD_BYTES})"
        )
    data = base64.b64encode(target.read_bytes()).decode("ascii")
    return {
        "name": target.name,
        "path": str(target.resolve()),
        "size": size,
        "data": data,
    }


def file_handle_action(action: str, path: str) -> dict:
    if action == "drives":
        return {"ok": True, "entries": file_list_drives()}
    if action == "list":
        result = file_list_directory(path)
        return {"ok": True, **result}
    if action == "download":
        result = file_read_download(path)
        return {"ok": True, **result}
    return {"ok": False, "error": "unknown action"}


def terminal_default_cwd() -> str:
    global _terminal_session_cwd
    if _terminal_session_cwd:
        return _terminal_session_cwd
    for candidate in (
        os.environ.get("USERPROFILE"),
        (os.environ.get("HOMEDRIVE", "") + os.environ.get("HOMEPATH", "")) or None,
        os.path.expanduser("~"),
    ):
        if candidate:
            path = Path(candidate)
            if path.is_dir():
                _terminal_session_cwd = str(path.resolve())
                return _terminal_session_cwd
    system_drive = os.environ.get("SystemDrive", "C:")
    _terminal_session_cwd = f"{system_drive}\\"
    return _terminal_session_cwd


def terminal_set_session_cwd(path: str) -> None:
    global _terminal_session_cwd
    _terminal_session_cwd = str(Path(path).resolve())


def terminal_resolve_cd_target(base: str, target: str) -> Optional[Path]:
    raw = target.strip().strip('"').strip("'")
    if not raw:
        return Path(base)
    if re.match(r"^[a-zA-Z]:$", raw):
        root = f"{raw[0].upper()}:\\"
        return Path(root) if Path(root).is_dir() else None
    path = Path(raw)
    if not path.is_absolute():
        path = Path(base) / path
    try:
        resolved = path.resolve()
    except OSError:
        return None
    return resolved if resolved.is_dir() else None


def terminal_split_command_lines(command: str) -> list[str]:
    normalized = (command or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    if not normalized:
        return []
    return [line.strip() for line in normalized.split("\n") if line.strip()]


def terminal_resolve_initial_workdir(cwd: Optional[str]) -> str:
    if cwd and str(cwd).strip():
        path = str(cwd).strip()
        if Path(path).is_dir():
            terminal_set_session_cwd(path)
    return terminal_default_cwd()


def terminal_apply_cd_command(
    command: str, shell: str, current: str
) -> tuple[Optional[str], bool, Optional[str]]:
    cmd = command.strip()
    if not cmd or "\n" in cmd or "\r" in cmd:
        return None, False, None

    lower = cmd.lower()
    if lower in ("pwd", "cwd", "echo %cd%"):
        return current, True, None

    if shell == "powershell":
        if lower in ("get-location", "gl"):
            return current, True, None
        if lower == "cd":
            home = os.environ.get("USERPROFILE") or current
            return home, True, None
        match = re.match(r"^(?:cd|set-location|sl)\s+(.+)$", cmd, re.I)
        if match:
            target = terminal_resolve_cd_target(current, match.group(1))
            if target:
                return str(target), True, None
            return None, True, "Cannot find path because it does not exist.\n"
        return None, False, None

    if lower == "cd":
        home = os.environ.get("USERPROFILE") or current
        return home, True, None

    drive_match = re.match(r"^([a-zA-Z]:)\s*$", cmd)
    if drive_match:
        root = f"{drive_match.group(1).upper()}\\"
        if Path(root).is_dir():
            return root, True, None
        return None, True, "The system cannot find the drive specified.\n"

    match = (
        re.match(r"^cd\s+/d\s+(.+)$", cmd, re.I)
        or re.match(r"^cd\s+(.+)$", cmd, re.I)
        or re.match(r"^chdir\s+(.+)$", cmd, re.I)
    )
    if match:
        target = terminal_resolve_cd_target(current, match.group(1))
        if target:
            return str(target), True, None
        return None, True, "The system cannot find the path specified.\n"

    return None, False, None


def terminal_subprocess_startupinfo() -> Optional[subprocess.STARTUPINFO]:
    if sys.platform != "win32":
        return None
    info = subprocess.STARTUPINFO()
    info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    info.wShowWindow = subprocess.SW_HIDE
    return info


def terminal_trim_output(text: str, limit: int = MAX_TERMINAL_OUTPUT_BYTES) -> tuple[str, bool]:
    raw = text or ""
    encoded = raw.encode("utf-8", errors="replace")
    if len(encoded) <= limit:
        return raw, False
    clipped = encoded[:limit].decode("utf-8", errors="ignore")
    return clipped + "\n...[truncated]", True


def terminal_run_single_line(line: str, shell: str) -> dict[str, Any]:
    command = (line or "").strip()
    if not command:
        return {
            "stdout": "",
            "stderr": "empty command",
            "exitCode": 1,
            "truncated": False,
            "cwd": terminal_default_cwd(),
        }

    workdir = terminal_default_cwd()
    if not Path(workdir).is_dir():
        return {
            "stdout": "",
            "stderr": f"invalid cwd: {workdir}",
            "exitCode": 1,
            "truncated": False,
            "cwd": terminal_default_cwd(),
        }

    new_cwd, handled, cd_error = terminal_apply_cd_command(command, shell, workdir)
    if handled:
        if cd_error:
            return {
                "stdout": "",
                "stderr": cd_error,
                "exitCode": 1,
                "truncated": False,
                "cwd": workdir,
            }
        if new_cwd:
            terminal_set_session_cwd(new_cwd)
            if command.strip().lower() in (
                "pwd",
                "cwd",
                "get-location",
                "gl",
                "echo %cd%",
            ):
                return {
                    "stdout": new_cwd + "\n",
                    "stderr": "",
                    "exitCode": 0,
                    "truncated": False,
                    "cwd": new_cwd,
                }
            return {
                "stdout": "",
                "stderr": "",
                "exitCode": 0,
                "truncated": False,
                "cwd": new_cwd,
            }

    workdir = terminal_default_cwd()
    if shell == "powershell":
        args = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ]
    else:
        args = ["cmd.exe", "/c", command]

    flags = TERMINAL_SUBPROCESS_FLAGS if sys.platform == "win32" else 0
    startupinfo = terminal_subprocess_startupinfo()
    try:
        completed = subprocess.run(
            args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            cwd=workdir,
            creationflags=flags,
            startupinfo=startupinfo,
            timeout=120,
        )
        stdout, out_trunc = terminal_trim_output(completed.stdout)
        stderr, err_trunc = terminal_trim_output(completed.stderr)
        return {
            "stdout": stdout,
            "stderr": stderr,
            "exitCode": int(completed.returncode),
            "truncated": out_trunc or err_trunc,
            "cwd": terminal_default_cwd(),
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": "command timeout (120s)",
            "exitCode": 124,
            "truncated": False,
            "cwd": terminal_default_cwd(),
        }
    except OSError as exc:
        return {
            "stdout": "",
            "stderr": str(exc),
            "exitCode": 1,
            "truncated": False,
            "cwd": terminal_default_cwd(),
        }


def terminal_run_command(command: str, shell: str, cwd: Optional[str]) -> dict[str, Any]:
    terminal_resolve_initial_workdir(cwd)
    lines = terminal_split_command_lines(command)
    if not lines:
        return {
            "stdout": "",
            "stderr": "empty command",
            "exitCode": 1,
            "truncated": False,
            "cwd": terminal_default_cwd(),
        }

    if len(lines) == 1:
        return terminal_run_single_line(lines[0], shell)

    stdout_parts: list[str] = []
    stderr_parts: list[str] = []
    exit_code = 0
    truncated = False
    final = terminal_default_cwd()

    for index, line in enumerate(lines, start=1):
        result = terminal_run_single_line(line, shell)
        final = result.get("cwd") or final
        exit_code = int(result.get("exitCode", 1))
        truncated = truncated or bool(result.get("truncated"))

        if result.get("stdout"):
            stdout_parts.append(result["stdout"])
        if result.get("stderr"):
            stderr_parts.append(result["stderr"])
        if exit_code != 0:
            if index < len(lines):
                stderr_parts.append(f"[line {index}] command failed, stopped.\n")
            break

    stdout, out_trunc = terminal_trim_output("".join(stdout_parts))
    stderr, err_trunc = terminal_trim_output("".join(stderr_parts))
    return {
        "stdout": stdout,
        "stderr": stderr,
        "exitCode": exit_code,
        "truncated": truncated or out_trunc or err_trunc,
        "cwd": final,
    }


async def handle_terminal_message(ws, msg: dict[str, Any]) -> None:
    req_id = str(msg.get("id") or "")
    command = str(msg.get("command") or "")
    shell = str(msg.get("shell") or "cmd").lower()
    if shell not in ("cmd", "powershell"):
        shell = "cmd"
    cwd = msg.get("cwd")

    agent_log(f"terminal [{shell}]: {command[:120]}")
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            None, terminal_run_command, command, shell, cwd
        )
        payload = {
            "type": "terminal_result",
            "id": req_id,
            "command": command,
            "shell": shell,
            **result,
        }
        await ws.send(json.dumps(payload))
        agent_log(f"terminal done [{shell}] exit={result.get('exitCode')}")
    except Exception as exc:
        agent_log(f"terminal failed: {exc}")
        await ws.send(
            json.dumps(
                {
                    "type": "terminal_result",
                    "id": req_id,
                    "command": command,
                    "shell": shell,
                    "stdout": "",
                    "stderr": f"agent error: {exc}",
                    "exitCode": 1,
                    "truncated": False,
                    "cwd": terminal_default_cwd(),
                }
            )
        )


def handle_control(msg: dict) -> None:
    mark_remote_input()
    action = msg.get("action")
    if action == "mouse_move":
        x = int(msg["x"])
        y = int(msg["y"])
        mouse.position = (x, y)
        return

    if action == "mouse_click":
        button_name = msg.get("button", "left")
        down = bool(msg.get("down", True))
        button = {
            "left": Button.left,
            "right": Button.right,
            "middle": Button.middle,
        }.get(button_name, Button.left)
        if down:
            mouse.press(button)
        else:
            mouse.release(button)
        return

    if action == "scroll":
        mouse.scroll(int(msg.get("dx", 0)), int(msg.get("dy", 0)))
        return

    if action == "key":
        key = resolve_key(msg.get("key", ""))
        if key is None:
            return
        down = bool(msg.get("down", True))
        if down:
            keyboard.press(key)
        else:
            keyboard.release(key)


def prepare_stream_frame(frame: np.ndarray, stream_width: int) -> np.ndarray:
    height, width = frame.shape[:2]
    if stream_width > 0 and width > stream_width:
        scale = stream_width / width
        new_width = stream_width
        new_height = max(1, int(height * scale))
        return cv2.resize(
            frame,
            (new_width, new_height),
            interpolation=cv2.INTER_LINEAR,
        )
    return frame


SCREENSHOT_MAX_WIDTH = 1280
SCREENSHOT_MAX_JPEG_BYTES = 450_000
RECORD_FPS = 5
RECORD_MAX_WIDTH = 960
RECORD_SEGMENT_DEFAULT = 30


def normalize_record_segment_seconds(value: Any) -> int:
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return RECORD_SEGMENT_DEFAULT
    return max(30, min(seconds, 600))


class ScreenRecordingState:
    def __init__(self) -> None:
        self.enabled = False
        self.segment_seconds = RECORD_SEGMENT_DEFAULT
        self.changed = asyncio.Event()

    def set_recording(self, enabled: bool, segment_seconds: int = RECORD_SEGMENT_DEFAULT) -> tuple[bool, int]:
        self.enabled = bool(enabled)
        self.segment_seconds = normalize_record_segment_seconds(segment_seconds)
        self.changed.set()
        return self.enabled, self.segment_seconds


def server_http_base(server: str) -> str:
    base = server.rstrip("/")
    if base.startswith("wss://"):
        return "https://" + base[len("wss://") :]
    if base.startswith("ws://"):
        return "http://" + base[len("ws://") :]
    if base.startswith("https://") or base.startswith("http://"):
        return base
    return "http://" + base


def get_local_version() -> str:
    if AGENT_VERSION != "dev":
        return AGENT_VERSION
    version_file = get_settings_dir() / "version.txt"
    if version_file.is_file():
        saved = version_file.read_text(encoding="utf-8").strip()
        if saved:
            return saved
    return AGENT_VERSION


def save_local_version(version: str) -> None:
    cleaned = str(version or "").strip()
    if not cleaned:
        return
    get_settings_dir().mkdir(parents=True, exist_ok=True)
    (get_settings_dir() / "version.txt").write_text(cleaned, encoding="utf-8")
    parts: list[int] = []
    for piece in str(value or "").strip().split("."):
        try:
            parts.append(int(piece))
        except ValueError:
            parts.append(0)
    return tuple(parts) or (0,)


def version_is_newer(remote: str, local: str) -> bool:
    return parse_version(remote) > parse_version(local)


def http_get_bytes(url: str, timeout: float = 120.0) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": f"ReSA/{AGENT_VERSION}"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def fetch_versions_manifest_sync(server: str) -> dict[str, Any]:
    url = f"{server_http_base(server)}/download/versions.json"
    raw = http_get_bytes(url, timeout=30)
    return json.loads(raw.decode("utf-8"))


async def fetch_versions_manifest(server: str) -> dict[str, Any]:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, fetch_versions_manifest_sync, server)


def download_file_sync(url: str, dest: Path, min_size: int = 0) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file():
        dest.unlink()
    raw = http_get_bytes(url, timeout=300)
    if min_size and len(raw) < min_size:
        raise ValueError(f"download too small: {len(raw)} bytes")
    dest.write_bytes(raw)


def launch_resa_updater(new_exe: Path, target_exe: Path, work_dir: Path) -> None:
    ps1 = work_dir / "update.ps1"
    pid = os.getpid()
    script = "\n".join(
        [
            "param()",
            "$ErrorActionPreference = 'SilentlyContinue'",
            f"$pidToWait = {pid}",
            f'$newExe = "{new_exe}"',
            f'$targetExe = "{target_exe}"',
            f'$workDir = "{work_dir}"',
            "Wait-Process -Id $pidToWait -ErrorAction SilentlyContinue",
            "Start-Sleep -Seconds 2",
            "Get-Process -Name 'ReSA' -ErrorAction SilentlyContinue | Stop-Process -Force",
            "Start-Sleep -Seconds 1",
            "if (Test-Path -LiteralPath $newExe) {",
            "    Remove-Item -LiteralPath $targetExe -Force -ErrorAction SilentlyContinue",
            "    Move-Item -LiteralPath $newExe -Destination $targetExe -Force",
            "    Unblock-File -LiteralPath $targetExe -ErrorAction SilentlyContinue",
            "    Start-Process -FilePath $targetExe -WorkingDirectory $workDir -WindowStyle Hidden",
            "}",
            f'Remove-Item -LiteralPath "{ps1}" -Force -ErrorAction SilentlyContinue',
            "",
        ]
    )
    ps1.write_text(script, encoding="utf-8")
    subprocess.Popen(
        [
            "powershell.exe",
            "-NoProfile",
            "-WindowStyle",
            "Hidden",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ps1),
        ],
        creationflags=CREATE_NO_WINDOW,
        cwd=str(work_dir),
    )


def apply_resa_update_sync(server: str, info: dict[str, Any]) -> bool:
    global _update_exit_requested
    base = server_http_base(server)
    url_path = str(info.get("url", "/download/ReSA.exe"))
    download_url = url_path if url_path.startswith("http") else base + url_path
    min_size = int(info.get("minSize", 1_048_576))
    work_dir = get_settings_dir()
    work_dir.mkdir(parents=True, exist_ok=True)
    target_exe = work_dir / "ReSA.exe"
    new_exe = work_dir / "ReSA.new.exe"
    download_file_sync(download_url, new_exe, min_size)
    remote_version = str(info.get("version", "")).strip()
    if remote_version:
        save_local_version(remote_version)
    launch_resa_updater(new_exe, target_exe, work_dir)
    _update_exit_requested = True
    return True


async def maybe_auto_update(server: str) -> bool:
    if not getattr(sys, "frozen", False):
        return False
    if os.environ.get("RESA_SKIP_UPDATE") == "1":
        return False
    try:
        manifest = await fetch_versions_manifest(server)
    except Exception as exc:
        agent_log(f"update manifest error: {exc}")
        return False
    info = manifest.get("resa") or {}
    remote_version = str(info.get("version", "")).strip()
    if not remote_version or not version_is_newer(remote_version, get_local_version()):
        return False
    agent_log(f"update available: {get_local_version()} -> {remote_version}")
    loop = asyncio.get_running_loop()
    try:
        applied = await loop.run_in_executor(
            None, apply_resa_update_sync, server, info
        )
        if applied:
            agent_log("update staged, restarting...")
        return applied
    except Exception as exc:
        agent_log(f"update failed: {exc}")
        return False


async def auto_update_loop(server: str) -> None:
    await asyncio.sleep(UPDATE_INITIAL_DELAY)
    while not _update_exit_requested:
        if await maybe_auto_update(server):
            return
        await asyncio.sleep(UPDATE_CHECK_INTERVAL)


async def handle_update_request(ws, server: str, req_id: str) -> None:
    result: dict[str, Any] = {
        "type": "update_result",
        "id": req_id,
        "product": "resa",
        "localVersion": get_local_version(),
    }
    if not getattr(sys, "frozen", False):
        result.update(
            {"ok": False, "status": "failed", "error": "dev build cannot update"}
        )
        await ws.send(json.dumps(result))
        return
    if os.environ.get("RESA_SKIP_UPDATE") == "1":
        result.update(
            {"ok": False, "status": "failed", "error": "update disabled"}
        )
        await ws.send(json.dumps(result))
        return
    try:
        manifest = await fetch_versions_manifest(server)
        info = manifest.get("resa") or {}
        remote = str(info.get("version", "")).strip()
        result["remoteVersion"] = remote
        if not remote:
            result.update(
                {"ok": False, "status": "failed", "error": "server version missing"}
            )
            await ws.send(json.dumps(result))
            return
        if not version_is_newer(remote, get_local_version()):
            result.update({"ok": True, "status": "up_to_date"})
            await ws.send(json.dumps(result))
            return
        agent_log(f"manual update: {get_local_version()} -> {remote}")
        result.update({"ok": True, "status": "updating"})
        await ws.send(json.dumps(result))
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, apply_resa_update_sync, server, info)
        agent_log("update staged, exiting...")
        os._exit(0)
    except Exception as exc:
        result.update({"ok": False, "status": "failed", "error": str(exc)})
        try:
            await ws.send(json.dumps(result))
        except Exception:
            pass


async def upload_screenshot_http(
    server: str,
    device_id: str,
    token: str,
    payload: dict[str, Any],
) -> bool:
    url = f"{server_http_base(server)}/api/screenshots/upload"
    body = json.dumps(
        {
            "deviceId": device_id,
            "data": payload["data"],
            "width": payload["width"],
            "height": payload["height"],
            "time": payload["time"],
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )

    def do_upload() -> None:
        with urllib.request.urlopen(request, timeout=45) as response:
            response.read()

    loop = asyncio.get_event_loop()
    try:
        await loop.run_in_executor(None, do_upload)
        return True
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        agent_log(f"screenshot http upload error: {exc}")
        return False


async def capture_and_send_screenshot(
    ws,
    server: str,
    device_id: str,
    token: str,
    monitor_index: int,
    quality: int = 80,
) -> None:
    with mss.mss() as sct:
        monitors = sct.monitors
        idx = monitor_index if monitor_index < len(monitors) else 1
        region = monitors[idx]
        img = np.array(sct.grab(region))
        frame = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
        frame = prepare_stream_frame(frame, SCREENSHOT_MAX_WIDTH)

        encoded = None
        used_q = quality
        for try_q in range(min(quality, 85), 39, -10):
            ok, candidate = cv2.imencode(
                ".jpg",
                frame,
                [int(cv2.IMWRITE_JPEG_QUALITY), try_q],
            )
            if not ok:
                continue
            used_q = try_q
            encoded = candidate
            if len(encoded.tobytes()) <= SCREENSHOT_MAX_JPEG_BYTES:
                break

        if encoded is None:
            agent_log("screenshot encode failed")
            return

        out_h, out_w = frame.shape[:2]
        jpeg_bytes = encoded.tobytes()
        payload = {
            "type": "screenshot",
            "data": base64.b64encode(jpeg_bytes).decode("ascii"),
            "width": out_w,
            "height": out_h,
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        if await upload_screenshot_http(server, device_id, token, payload):
            agent_log(
                f"screenshot uploaded: {out_w}x{out_h} q={used_q} size={len(jpeg_bytes)}"
            )
            return

        raw = json.dumps(payload)
        try:
            await ws.send(raw)
            agent_log(
                f"screenshot sent via ws: {out_w}x{out_h} q={used_q} size={len(jpeg_bytes)}"
            )
        except Exception as exc:
            agent_log(f"screenshot send error: {exc} ({len(raw)} bytes)")


async def auto_screenshot_loop(
    ws,
    server: str,
    device_id: str,
    token: str,
    monitor: int,
    quality: int,
    state: AutoScreenshotState,
) -> None:
    shot_quality = min(max(quality + 10, 60), 75)
    while True:
        state.changed.clear()
        interval = state.interval
        if interval <= 0:
            await state.changed.wait()
            continue
        try:
            await capture_and_send_screenshot(
                ws, server, device_id, token, monitor, shot_quality
            )
        except Exception as exc:
            agent_log(f"auto screenshot error: {exc}")
        try:
            await asyncio.wait_for(state.changed.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass


async def upload_recording_http(
    server: str,
    device_id: str,
    token: str,
    file_path: Path,
    duration: float,
    width: int,
    height: int,
) -> bool:
    url = f"{server_http_base(server)}/api/recordings/upload"

    def read_file() -> bytes:
        return file_path.read_bytes()

    loop = asyncio.get_event_loop()
    try:
        raw = await loop.run_in_executor(None, read_file)
    except OSError as exc:
        agent_log(f"recording read error: {exc}")
        return False

    body = json.dumps(
        {
            "deviceId": device_id,
            "data": base64.b64encode(raw).decode("ascii"),
            "duration": round(duration, 1),
            "width": width,
            "height": height,
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )

    def do_upload() -> None:
        with urllib.request.urlopen(request, timeout=120) as response:
            response.read()

    try:
        await loop.run_in_executor(None, do_upload)
        return True
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        agent_log(f"recording http upload error: {exc}")
        return False


async def finalize_recording_segment(
    writer: Optional[cv2.VideoWriter],
    path: Optional[Path],
    duration: float,
    width: int,
    height: int,
    server: str,
    device_id: str,
    token: str,
) -> None:
    if writer is not None:
        writer.release()
    if path is None or not path.is_file():
        return
    try:
        size = path.stat().st_size
        if size < 128:
            return
        if await upload_recording_http(
            server, device_id, token, path, duration, width, height
        ):
            agent_log(
                f"recording uploaded: {width}x{height} {duration:.0f}s size={size}"
            )
    finally:
        try:
            path.unlink()
        except OSError:
            pass


async def screen_record_loop(
    server: str,
    device_id: str,
    token: str,
    monitor_index: int,
    state: ScreenRecordingState,
) -> None:
    interval = 1.0 / RECORD_FPS
    writer: Optional[cv2.VideoWriter] = None
    segment_path: Optional[Path] = None
    segment_start = 0.0
    frame_w = 0
    frame_h = 0
    loop = asyncio.get_event_loop()

    async def close_segment(duration: float) -> None:
        nonlocal writer, segment_path, frame_w, frame_h
        current_writer = writer
        current_path = segment_path
        current_w = frame_w
        current_h = frame_h
        writer = None
        segment_path = None
        frame_w = 0
        frame_h = 0
        await finalize_recording_segment(
            current_writer,
            current_path,
            duration,
            current_w,
            current_h,
            server,
            device_id,
            token,
        )

    with mss.mss() as sct:
        monitors = sct.monitors
        idx = monitor_index if monitor_index < len(monitors) else 1
        region = monitors[idx]

        while True:
            if not state.enabled:
                if writer is not None:
                    duration = max(0.1, time.monotonic() - segment_start)
                    await close_segment(duration)
                state.changed.clear()
                await state.changed.wait()
                continue

            loop_start = time.monotonic()
            try:
                img = await loop.run_in_executor(None, lambda: np.array(sct.grab(region)))
                frame = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
                frame = prepare_stream_frame(frame, RECORD_MAX_WIDTH)
                h, w = frame.shape[:2]

                if writer is None:
                    segment_path = Path(tempfile.gettempdir()) / (
                        f"ReSA-rec-{int(time.time())}.mp4"
                    )
                    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                    new_writer = cv2.VideoWriter(
                        str(segment_path), fourcc, RECORD_FPS, (w, h)
                    )
                    if not new_writer.isOpened():
                        agent_log("recording writer open failed")
                        segment_path.unlink(missing_ok=True)
                        segment_path = None
                        await asyncio.sleep(1)
                        continue
                    writer = new_writer
                    segment_start = time.monotonic()
                    frame_w = w
                    frame_h = h
                    agent_log(f"recording segment started: {w}x{h}")

                await loop.run_in_executor(None, writer.write, frame)

                elapsed_segment = time.monotonic() - segment_start
                if elapsed_segment >= state.segment_seconds:
                    await close_segment(elapsed_segment)
            except Exception as exc:
                agent_log(f"recording capture error: {exc}")
                if writer is not None:
                    duration = max(0.1, time.monotonic() - segment_start)
                    await close_segment(duration)
                await asyncio.sleep(1)
                continue

            spent = time.monotonic() - loop_start
            await asyncio.sleep(max(0.0, interval - spent))


def build_frame_payload(frame: np.ndarray, encode_q: int) -> Optional[str]:
    ok, encoded = cv2.imencode(
        ".jpg",
        frame,
        [int(cv2.IMWRITE_JPEG_QUALITY), encode_q],
    )
    if not ok:
        return None
    out_h, out_w = frame.shape[:2]
    return json.dumps(
        {
            "type": "frame",
            "data": base64.b64encode(encoded.tobytes()).decode("ascii"),
            "width": out_w,
            "height": out_h,
        }
    )


async def capture_loop(
    ws,
    monitor_index: int,
    fps: int,
    quality: int,
    stream_width: int,
    viewer_count: asyncio.Event,
) -> None:
    interval = 1.0 / max(fps, 1)
    encode_q = max(20, min(quality, 95))
    frames_sent = 0
    loop = asyncio.get_event_loop()

    with mss.mss() as sct:
        monitors = sct.monitors
        idx = monitor_index if monitor_index < len(monitors) else 1
        region = monitors[idx]
        stream_desc = stream_width if stream_width > 0 else "native"
        agent_log(
            f"capture region: {region['width']}x{region['height']} stream_width={stream_desc}"
        )

        while True:
            if not viewer_count.is_set():
                await asyncio.sleep(0.2)
                continue

            loop_start = time.perf_counter()
            try:
                img = np.array(sct.grab(region))
                frame = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
                frame = prepare_stream_frame(frame, stream_width)
                payload = await loop.run_in_executor(
                    None, build_frame_payload, frame, encode_q
                )
                if not payload:
                    await asyncio.sleep(interval)
                    continue
                await ws.send(payload)
                frames_sent += 1
                if frames_sent == 1:
                    first = json.loads(payload)
                    agent_log(
                        f"first frame sent: {first['width']}x{first['height']}"
                    )
            except Exception as exc:
                agent_log(f"capture error: {exc}")
                await asyncio.sleep(1)
                continue

            elapsed = time.perf_counter() - loop_start
            await asyncio.sleep(max(0.0, interval - elapsed))


async def receive_loop(
    ws,
    viewer_count: asyncio.Event,
    server: str,
    device_id: str,
    token: str,
    monitor: int,
    quality: int,
    auto_screenshot_state: AutoScreenshotState,
    screen_recording_state: ScreenRecordingState,
) -> None:
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            continue

        msg_type = msg.get("type")
        if msg_type == "registered":
            remote_version = str(msg.get("latestVersion", "")).strip()
            if remote_version and version_is_newer(remote_version, get_local_version()):
                asyncio.create_task(maybe_auto_update(server))
        elif msg_type == "update_available":
            asyncio.create_task(maybe_auto_update(server))
        elif msg_type == "update":
            asyncio.create_task(
                handle_update_request(ws, server, str(msg.get("id", "")))
            )
        elif msg_type == "terminal":
            asyncio.create_task(handle_terminal_message(ws, msg))
        elif msg_type == "viewer_count":
            count = int(msg.get("count", 0))
            if count > 0:
                viewer_count.set()
                agent_log(f"viewer connected: {count}")
            else:
                viewer_count.clear()
                agent_log("viewer disconnected")
        elif msg_type == "control":
            if msg.get("action") == "screenshot":
                agent_log("screenshot requested")
                shot_quality = min(max(quality + 10, 60), 75)

                async def run_screenshot() -> None:
                    try:
                        await capture_and_send_screenshot(
                            ws, server, device_id, token, monitor, shot_quality
                        )
                    except Exception as exc:
                        agent_log(f"screenshot error: {exc}")

                asyncio.create_task(run_screenshot())
                continue
            if msg.get("action") == "set_auto_screenshot":
                interval = auto_screenshot_state.update(
                    msg.get("interval", 0)
                )
                if interval > 0:
                    agent_log(f"auto screenshot enabled: every {interval}s")
                else:
                    agent_log("auto screenshot disabled")
                continue
            if msg.get("action") == "set_screen_recording":
                enabled, segment = screen_recording_state.set_recording(
                    msg.get("enabled", False),
                    msg.get("segmentSeconds", RECORD_SEGMENT_DEFAULT),
                )
                if enabled:
                    agent_log(f"screen recording enabled: segment {segment}s")
                else:
                    agent_log("screen recording disabled")
                continue
            try:
                handle_control(msg)
            except Exception as exc:
                print(f"[control] error: {exc}", file=sys.stderr)
        elif msg_type == "file":
            req_id = msg.get("id")
            action = str(msg.get("action", ""))
            path = str(msg.get("path", ""))

            async def run_file_request() -> None:
                result: dict[str, Any] = {
                    "type": "file_result",
                    "id": req_id,
                    "action": action,
                }
                try:
                    loop = asyncio.get_running_loop()
                    payload = await loop.run_in_executor(
                        None,
                        lambda: file_handle_action(action, path),
                    )
                    result.update(payload)
                except Exception as exc:
                    result["ok"] = False
                    result["error"] = str(exc)
                try:
                    await ws.send(json.dumps(result))
                except Exception as exc:
                    agent_log(f"file_result send error: {exc}")

            asyncio.create_task(run_file_request())


async def run_agent(
    server: str,
    device_id: str,
    token: str,
    monitor: int,
    fps: int,
    quality: int,
    stream_width: int,
) -> None:
    url = build_ws_url(server, device_id, token)
    viewer_count = asyncio.Event()
    auto_screenshot_state = AutoScreenshotState(0)
    screen_recording_state = ScreenRecordingState()
    hostname = socket.gethostname()
    platform_name = platform.platform()

    while True:
        try:
            agent_log(f"Connecting to {url.split('token=')[0]}token=***")
            async with websockets.connect(
                url,
                ping_interval=20,
                ping_timeout=20,
                max_size=16 * 1024 * 1024,
            ) as ws:
                await ws.send(
                    json.dumps(
                        {
                            "type": "agent_info",
                            "hostname": hostname,
                            "platform": platform_name,
                            "monitor": monitor,
                            "version": get_local_version(),
                        }
                    )
                )
                agent_log(
                    f"Agent online: {device_id} ({hostname}) v{get_local_version()}"
                )
                capture_task = asyncio.create_task(
                    capture_loop(ws, monitor, fps, quality, stream_width, viewer_count)
                )
                receive_task = asyncio.create_task(
                    receive_loop(
                        ws,
                        viewer_count,
                        server,
                        device_id,
                        token,
                        monitor,
                        quality,
                        auto_screenshot_state,
                        screen_recording_state,
                    )
                )
                screen_record_task = asyncio.create_task(
                    screen_record_loop(
                        server,
                        device_id,
                        token,
                        monitor,
                        screen_recording_state,
                    )
                )
                auto_screenshot_task = asyncio.create_task(
                    auto_screenshot_loop(
                        ws,
                        server,
                        device_id,
                        token,
                        monitor,
                        quality,
                        auto_screenshot_state,
                    )
                )
                clipboard_task = asyncio.create_task(clipboard_loop(ws))
                keyboard_task = asyncio.create_task(keyboard_loop(ws))
                update_task = asyncio.create_task(auto_update_loop(server))
                done, pending = await asyncio.wait(
                    {
                        capture_task,
                        receive_task,
                        screen_record_task,
                        auto_screenshot_task,
                        clipboard_task,
                        keyboard_task,
                        update_task,
                    },
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in pending:
                    task.cancel()
                if _update_exit_requested:
                    agent_log("exiting for update")
                    os._exit(0)
        except Exception as exc:
            agent_log(f"Disconnected: {exc}. Retry in 3s...")
            await asyncio.sleep(3)


def main() -> None:
    parser = argparse.ArgumentParser(description="Remote screen agent")
    parser.add_argument("--config", help="JSON config file path")
    parser.add_argument(
        "--server",
        default=os.environ.get("SERVER", ""),
        help="Server URL (ws://host:port or http://host:port)",
    )
    parser.add_argument(
        "--device-id",
        default=os.environ.get("DEVICE_ID", ""),
        help="Unique device id",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("ACCESS_TOKEN", ""),
        help="Access token (must match server ACCESS_TOKEN)",
    )
    parser.add_argument(
        "--monitor",
        type=int,
        default=None,
        help="Monitor index (1=primary, 0=all)",
    )
    parser.add_argument("--fps", type=int, default=None, help="Capture frames per second")
    parser.add_argument(
        "--quality", type=int, default=None, help="JPEG quality 1-100"
    )
    parser.add_argument(
        "--stream-width",
        type=int,
        default=None,
        help="Max stream width in pixels (0 = native resolution)",
    )
    args = parser.parse_args()
    settings = resolve_settings(args)

    print(f"Server: {settings['server']}")
    print(f"Device: {settings['device_id']}")

    try:
        asyncio.run(
            run_agent(
                settings["server"],
                settings["device_id"],
                settings["token"],
                settings["monitor"],
                settings["fps"],
                settings["quality"],
                settings["stream_width"],
            )
        )
    except KeyboardInterrupt:
        print("Stopped.")


if __name__ == "__main__":
    main()
