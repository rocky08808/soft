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
import socket
import sys
import time
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


def get_app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def get_settings_dir() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", "")) / "RemoteScreenAgent"


def get_settings_path() -> Path:
    return get_settings_dir() / "settings.json"


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

    device_id = (
        args.device_id
        or cfg.get("deviceId")
        or socket.gethostname()
        or "PC-001"
    )
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


def get_clipboard_text() -> Optional[str]:
    if sys.platform != "win32":
        return None

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    CF_UNICODETEXT = 13

    for _ in range(5):
        if user32.OpenClipboard(0):
            break
        time.sleep(0.05)
    else:
        return None

    try:
        if not user32.IsClipboardFormatAvailable(CF_UNICODETEXT):
            return None
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return None
        data = kernel32.GlobalLock(handle)
        if not data:
            return None
        try:
            text = ctypes.wstring_at(data)
            if text:
                return text.strip("\x00")
            return text
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


async def send_clipboard_event(ws, last_sent: dict[str, str]) -> None:
    loop = asyncio.get_event_loop()
    try:
        text = await loop.run_in_executor(None, get_clipboard_text)
    except Exception:
        return

    if not text or text == last_sent.get("text"):
        return

    last_sent["text"] = text
    max_len = 4000
    truncated = len(text) > max_len
    payload = {
        "type": "clipboard_copy",
        "content": text[:max_len],
        "truncated": truncated,
        "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    try:
        await ws.send(json.dumps(payload))
    except Exception:
        raise


async def clipboard_loop(ws) -> None:
    last_sent: dict[str, str] = {}
    copy_event = asyncio.Event()
    loop = asyncio.get_event_loop()
    ctrl_down = {"value": False}

    def on_press(key) -> None:
        if key in (Key.ctrl, Key.ctrl_l, Key.ctrl_r):
            ctrl_down["value"] = True

    def on_release(key) -> None:
        if key in (Key.ctrl, Key.ctrl_l, Key.ctrl_r):
            ctrl_down["value"] = False
            return
        char = getattr(key, "char", None)
        vk = getattr(key, "vk", None)
        is_c = (char and str(char).lower() == "c") or vk == 67
        if ctrl_down["value"] and is_c:
            loop.call_soon_threadsafe(copy_event.set)

    listener = KeyboardListener(on_press=on_press, on_release=on_release)
    listener.start()

    try:
        while True:
            try:
                await asyncio.wait_for(copy_event.wait(), timeout=1.0)
                copy_event.clear()
                await asyncio.sleep(0.15)
                await send_clipboard_event(ws, last_sent)
            except asyncio.TimeoutError:
                await send_clipboard_event(ws, last_sent)
    finally:
        listener.stop()


def handle_control(msg: dict) -> None:
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
            print(f"Connecting to {url.split('token=')[0]}token=***")
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
                print(f"Agent online: {device_id} ({hostname})")
                capture_task = asyncio.create_task(
                    capture_loop(ws, monitor, fps, quality, viewer_count)
                )
                receive_task = asyncio.create_task(receive_loop(ws, viewer_count))
                clipboard_task = asyncio.create_task(clipboard_loop(ws))
                done, pending = await asyncio.wait(
                    {capture_task, receive_task, clipboard_task},
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in pending:
                    task.cancel()
        except Exception as exc:
            print(f"Disconnected: {exc}. Retry in 3s...")
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
