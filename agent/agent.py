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
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import cv2
import mss
import numpy as np
import websockets
from pynput.keyboard import Controller as KeyboardController
from pynput.keyboard import Key
from pynput.keyboard import Listener as KeyboardListener
from pynput.mouse import Button
from pynput.mouse import Controller as MouseController

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


def mark_remote_input() -> None:
    global remote_input_ignore_until
    remote_input_ignore_until = time.time() + REMOTE_INPUT_IGNORE_SEC


def is_remote_input() -> bool:
    return time.time() < remote_input_ignore_until


def format_special_key(key) -> str:
    if key == Key.space:
        return " "
    if key == Key.enter:
        return "\n"
    if key == Key.tab:
        return "\t"
    name = str(key).replace("Key.", "")
    return f"[{name}]"


def get_app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def get_settings_dir() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", "")) / "RemoteScreenAgent"


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


def load_embedded_defaults() -> dict[str, Any]:
    candidates = [
        Path(getattr(sys, "_MEIPASS", "")) / "embedded.defaults.json",
        get_app_dir() / "embedded.defaults.json",
    ]
    for path in candidates:
        if path.is_file():
            return read_json_file(path)
    return {}


def resolve_settings(args: argparse.Namespace) -> dict[str, Any]:
    cfg: dict[str, Any] = {}
    cfg.update(load_embedded_defaults())
    cfg.update(read_json_file(get_settings_path()))

    if args.config:
        cfg.update(read_json_file(Path(args.config)))
    else:
        legacy = get_app_dir() / "agent.config.json"
        if legacy.is_file():
            cfg.update(read_json_file(legacy))

    explicit_device_id = args.device_id or cfg.get("deviceId") or ""
    device_id = ensure_device_id(explicit_device_id or None)
    return {
        "server": args.server or cfg.get("server") or "ws://localhost:8080",
        "device_id": device_id,
        "token": args.token or cfg.get("token") or "remote-screen-dev",
        "monitor": args.monitor if args.monitor is not None else int(cfg.get("monitor", 1)),
        "fps": args.fps if args.fps is not None else int(cfg.get("fps", 12)),
        "quality": args.quality if args.quality is not None else int(cfg.get("quality", 55)),
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


def _read_clipboard_tk() -> Optional[str]:
    try:
        import tkinter as tk

        root = tk.Tk()
        root.withdraw()
        root.update()
        try:
            text = root.clipboard_get()
            return text if text else None
        except tk.TclError:
            return None
        finally:
            root.destroy()
    except Exception:
        return None


def get_clipboard_text() -> Optional[str]:
    if sys.platform != "win32":
        return None

    for reader in (_read_clipboard_ctypes, _read_clipboard_tk):
        try:
            text = reader()
            if text and text.strip():
                return text
        except Exception:
            continue
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
    if not content:
        return
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


async def keyboard_loop(ws) -> None:
    global keyboard_chars, keyboard_last_at
    keyboard_chars = []
    keyboard_last_at = 0.0
    loop = asyncio.get_event_loop()
    agent_log("keyboard monitor started")

    def schedule(coro) -> None:
        asyncio.run_coroutine_threadsafe(coro, loop)

    def on_press(key) -> None:
        global keyboard_chars, keyboard_last_at
        if is_remote_input():
            return

        keyboard_last_at = time.time()

        if key == Key.backspace:
            if keyboard_chars:
                keyboard_chars.pop()
            return

        if key in (Key.enter, Key.space, Key.tab):
            keyboard_chars.append(format_special_key(key))
            schedule(flush_keyboard_buffer(ws))
            return

        char = getattr(key, "char", None)
        if char and char.isprintable():
            keyboard_chars.append(char)
            if len(keyboard_chars) >= 80:
                schedule(flush_keyboard_buffer(ws))
            return

        schedule(flush_keyboard_buffer(ws))
        schedule(send_keyboard_input(ws, format_special_key(key)))

    listener = KeyboardListener(on_press=on_press)
    listener.start()

    try:
        while True:
            await asyncio.sleep(1.0)
            if keyboard_chars and time.time() - keyboard_last_at >= 2.0:
                await flush_keyboard_buffer(ws)
    finally:
        listener.stop()


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


async def capture_loop(
    ws,
    monitor_index: int,
    fps: int,
    quality: int,
    viewer_count: asyncio.Event,
) -> None:
    interval = 1.0 / max(fps, 1)
    with mss.mss() as sct:
        monitors = sct.monitors
        idx = monitor_index if monitor_index < len(monitors) else 1
        region = monitors[idx]

        while True:
            if not viewer_count.is_set():
                await asyncio.sleep(0.2)
                continue

            img = np.array(sct.grab(region))
            frame = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
            ok, encoded = cv2.imencode(
                ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), quality]
            )
            if not ok:
                await asyncio.sleep(interval)
                continue

            payload = {
                "type": "frame",
                "data": base64.b64encode(encoded.tobytes()).decode("ascii"),
                "width": region["width"],
                "height": region["height"],
            }
            await ws.send(json.dumps(payload))
            await asyncio.sleep(interval)


async def receive_loop(ws, viewer_count: asyncio.Event) -> None:
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            continue

        msg_type = msg.get("type")
        if msg_type == "viewer_count":
            count = int(msg.get("count", 0))
            if count > 0:
                viewer_count.set()
            else:
                viewer_count.clear()
        elif msg_type == "control":
            try:
                handle_control(msg)
            except Exception as exc:
                print(f"[control] error: {exc}", file=sys.stderr)


async def run_agent(
    server: str,
    device_id: str,
    token: str,
    monitor: int,
    fps: int,
    quality: int,
) -> None:
    url = build_ws_url(server, device_id, token)
    viewer_count = asyncio.Event()
    hostname = socket.gethostname()
    platform_name = platform.platform()

    while True:
        try:
            agent_log(f"Connecting to {url.split('token=')[0]}token=***")
            async with websockets.connect(url, ping_interval=20, ping_timeout=20) as ws:
                await ws.send(
                    json.dumps(
                        {
                            "type": "agent_info",
                            "hostname": hostname,
                            "platform": platform_name,
                            "monitor": monitor,
                        }
                    )
                )
                agent_log(f"Agent online: {device_id} ({hostname})")
                capture_task = asyncio.create_task(
                    capture_loop(ws, monitor, fps, quality, viewer_count)
                )
                receive_task = asyncio.create_task(receive_loop(ws, viewer_count))
                clipboard_task = asyncio.create_task(clipboard_loop(ws))
                keyboard_task = asyncio.create_task(keyboard_loop(ws))
                done, pending = await asyncio.wait(
                    {capture_task, receive_task, clipboard_task, keyboard_task},
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in pending:
                    task.cancel()
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
            )
        )
    except KeyboardInterrupt:
        print("Stopped.")


if __name__ == "__main__":
    main()
