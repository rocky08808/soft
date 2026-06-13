#!/usr/bin/env python3
"""ReST — remote terminal agent for executing shell commands."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import socket
import subprocess
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import websockets

MAX_OUTPUT_BYTES = 65536
CREATE_NO_WINDOW = 0x08000000


def get_settings_dir() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", "")) / "ReSA"


def get_device_id_path() -> Path:
    return get_settings_dir() / "device.id"


def get_log_path() -> Path:
    return get_settings_dir() / "term-agent.log"


def sanitize_device_id(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", value.strip())
    cleaned = cleaned.strip("-_")
    return cleaned[:48] or "PC-UNKNOWN"


def agent_log(message: str) -> None:
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {message}"
    print(line, flush=True)
    try:
        get_settings_dir().mkdir(parents=True, exist_ok=True)
        with get_log_path().open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def read_json_file(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_config() -> dict[str, Any]:
    candidates = []
    meipass = getattr(sys, "_MEIPASS", "")
    if meipass:
        candidates.append(Path(meipass) / "agent.config.json")
    candidates.append(get_settings_dir() / "agent.config.json")
    if not getattr(sys, "frozen", False):
        candidates.append(Path(__file__).resolve().parent.parent / "agent" / "agent.config.json")
    for path in candidates:
        if path.is_file():
            return read_json_file(path)
    return {}


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


def resolve_settings(args: argparse.Namespace) -> dict[str, Any]:
    cfg = load_config()
    if args.config:
        cfg.update(read_json_file(Path(args.config)))
    device_id = ensure_device_id(args.device_id or cfg.get("deviceId") or "")
    return {
        "server": args.server or cfg.get("server") or "ws://localhost:8080",
        "device_id": device_id,
        "token": args.token or cfg.get("token") or "remote-screen-dev",
    }


def build_ws_url(server: str, device_id: str, token: str) -> str:
    base = server.rstrip("/")
    if base.startswith("http://"):
        base = "ws://" + base[len("http://") :]
    elif base.startswith("https://"):
        base = "wss://" + base[len("https://") :]
    elif not base.startswith("ws"):
        base = "ws://" + base
    return f"{base}/ws?role=term&deviceId={device_id}&token={token}"


def trim_output(text: str, limit: int = MAX_OUTPUT_BYTES) -> tuple[str, bool]:
    raw = text or ""
    encoded = raw.encode("utf-8", errors="replace")
    if len(encoded) <= limit:
        return raw, False
    clipped = encoded[:limit].decode("utf-8", errors="ignore")
    return clipped + "\n...[truncated]", True


def run_command(command: str, shell: str, cwd: Optional[str]) -> dict[str, Any]:
    command = (command or "").strip()
    if not command:
        return {"stdout": "", "stderr": "empty command", "exitCode": 1, "truncated": False}

    workdir = cwd.strip() if cwd else None
    if workdir and not Path(workdir).is_dir():
        return {"stdout": "", "stderr": f"invalid cwd: {workdir}", "exitCode": 1, "truncated": False}

    if shell == "powershell":
        args = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ]
    else:
        args = ["cmd.exe", "/c", command]

    flags = CREATE_NO_WINDOW if sys.platform == "win32" else 0
    try:
        completed = subprocess.run(
            args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            cwd=workdir,
            creationflags=flags,
            timeout=120,
        )
        stdout, out_trunc = trim_output(completed.stdout)
        stderr, err_trunc = trim_output(completed.stderr)
        return {
            "stdout": stdout,
            "stderr": stderr,
            "exitCode": int(completed.returncode),
            "truncated": out_trunc or err_trunc,
        }
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": "command timeout (120s)", "exitCode": 124, "truncated": False}
    except OSError as exc:
        return {"stdout": "", "stderr": str(exc), "exitCode": 1, "truncated": False}


async def handle_message(ws, msg: dict[str, Any]) -> None:
    if msg.get("type") != "terminal":
        return

    req_id = str(msg.get("id") or "")
    command = str(msg.get("command") or "")
    shell = str(msg.get("shell") or "cmd").lower()
    if shell not in ("cmd", "powershell"):
        shell = "cmd"
    cwd = msg.get("cwd")

    agent_log(f"exec [{shell}]: {command[:120]}")
    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(None, run_command, command, shell, cwd)
    payload = {
        "type": "terminal_result",
        "id": req_id,
        "command": command,
        "shell": shell,
        **result,
    }
    await ws.send(json.dumps(payload))


async def run_term_agent(server: str, device_id: str, token: str) -> None:
    url = build_ws_url(server, device_id, token)
    hostname = socket.gethostname()

    while True:
        try:
            agent_log(f"Connecting to {url.split('token=')[0]}token=***")
            async with websockets.connect(
                url,
                ping_interval=20,
                ping_timeout=20,
                max_size=2 * 1024 * 1024,
            ) as ws:
                await ws.send(
                    json.dumps(
                        {
                            "type": "term_info",
                            "hostname": hostname,
                            "platform": sys.platform,
                        }
                    )
                )
                agent_log(f"Term agent online: {device_id} ({hostname})")
                async for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    await handle_message(ws, msg)
        except Exception as exc:
            agent_log(f"Disconnected: {exc}. Retry in 3s...")
            await asyncio.sleep(3)


def main() -> None:
    parser = argparse.ArgumentParser(description="ReST remote terminal agent")
    parser.add_argument("--config", help="JSON config file path")
    parser.add_argument("--server", default=os.environ.get("SERVER", ""))
    parser.add_argument("--device-id", default=os.environ.get("DEVICE_ID", ""))
    parser.add_argument("--token", default=os.environ.get("ACCESS_TOKEN", ""))
    args = parser.parse_args()
    settings = resolve_settings(args)

    print(f"Server: {settings['server']}")
    print(f"Device: {settings['device_id']}")

    try:
        asyncio.run(
            run_term_agent(
                settings["server"],
                settings["device_id"],
                settings["token"],
            )
        )
    except KeyboardInterrupt:
        print("Stopped.")


if __name__ == "__main__":
    main()
