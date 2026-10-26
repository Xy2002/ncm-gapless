"""Launch or control the verified macOS client without changing its app bundle."""
import argparse
import importlib
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import sys
import time

from cdp_probe import evaluate, get_page

ROOT = Path(__file__).resolve().parents[1]
CLIENT_VERSION = "3.1.12.3444"


def ensure_runtime():
    try:
        importlib.import_module("websocket")
        return
    except ImportError:
        pass
    environment = ROOT / ".venv"
    python = environment / "bin/python3"
    command = [str(python), str(Path(__file__).resolve()), *sys.argv[1:]]
    if python.is_file() and Path(sys.prefix).resolve() != environment.resolve():
        return os.execv(str(python), command)
    print("首次运行：正在准备本目录的 Python 环境和 WebSocket 依赖。", file=sys.stderr, flush=True)
    try:
        if not python.is_file():
            subprocess.run([sys.executable, "-m", "venv", str(environment)], check=True, stdout=sys.stderr)
        subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                        "-r", str(ROOT / "requirements-macos.txt")], check=True, stdout=sys.stderr)
        subprocess.run([str(python), "-c", "import websocket"], check=True, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("NCM_DEPENDENCY_SETUP_FAILED") from None
    return os.execv(str(python), command)


def find_client(client_path=None):
    candidates = [Path(client_path).expanduser()] if client_path else [
        app for base in (Path("/Applications"), Path.home() / "Applications")
        for app in base.glob("*.app")
    ]
    clients = {}
    for app in candidates:
        try:
            app = app.resolve()
            with (app / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException):
            continue
        if info.get("CFBundleIdentifier") != "com.netease.163music":
            continue
        if info.get("CFBundleExecutable") != "NeteaseMusic":
            raise RuntimeError("NCM_EXECUTABLE_UNVERIFIED")
        version = f'{info.get("CFBundleShortVersionString")}.{info.get("CFBundleVersion")}'
        if version != CLIENT_VERSION:
            raise RuntimeError("CLIENT_VERSION_UNVERIFIED")
        if not (app / "Contents/MacOS/NeteaseMusic").is_file():
            raise RuntimeError("NCM_EXECUTABLE_MISSING")
        clients[app] = version
    if len(clients) != 1:
        raise RuntimeError("NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENT_PATH")
    return next(iter(clients))


def running_commands():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "NeteaseMusic"], capture_output=True, text=True)
    if result.returncode == 1:
        return []
    result.check_returncode()
    pids = result.stdout.split()
    if not pids or any(not pid.isdigit() for pid in pids):
        raise RuntimeError("NCM_PROCESS_DISCOVERY_FAILED")
    result = subprocess.run(["/bin/ps", "-ww", "-p", ",".join(pids), "-o", "args="],
                            capture_output=True, text=True)
    if result.returncode == 1:
        return []
    result.check_returncode()
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def available_port():
    for port in (9222, 0):
        with socket.socket() as listener:
            try:
                listener.bind(("127.0.0.1", port))
                return listener.getsockname()[1]
            except OSError:
                if port == 0:
                    raise RuntimeError("NCM_NO_FREE_PORT") from None


def find_port(*, launch=False, client_path=None):
    app = find_client(client_path)
    commands = running_commands()
    executable = str(app / "Contents/MacOS/NeteaseMusic")
    for command in commands:
        if command != executable and not command.startswith(executable + " "):
            continue
        match = re.search(r"(?:^|\s)--remote-debugging-port(?:=|\s+)(\d+)(?:\s|$)", command)
        if match:
            port = int(match[1])
            try:
                get_page(port)
                return port
            except (OSError, ValueError, RuntimeError):
                pass
    if commands:
        raise RuntimeError("NCM_EXIT_AND_RESTART_WITH_LAUNCHER")
    if not launch:
        raise RuntimeError("NCM_NOT_RUNNING")
    port = available_port()
    subprocess.run(["/usr/bin/open", "-a", str(app), "--args",
                    "--remote-debugging-address=127.0.0.1",
                    f"--remote-debugging-port={port}"], check=True, capture_output=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            get_page(port)
            return port
        except (OSError, ValueError, RuntimeError):
            time.sleep(.25)
    raise RuntimeError("NCM_START_TIMEOUT")


def value(port, expression, *, user_gesture=False):
    response = evaluate(port, expression, user_gesture=user_gesture)
    result = response.get("result", {})
    if response.get("error") or result.get("exceptionDetails") or "value" not in result.get("result", {}):
        raise RuntimeError("NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE")
    return result["result"]["value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "disable"))
    parser.add_argument("--client-path", type=Path, help="Path to NeteaseMusic.app")
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("NCM_MACOS_REQUIRED")
    ensure_runtime()
    port = find_port(launch=arguments.action == "install", client_path=arguments.client_path)
    if arguments.action == "install":
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if value(port, "Boolean(document.readyState === 'complete' && window.ncmChannelOSX && window.webpackJsonp && document.getElementById('root')?._reactRootContainer)"):
                    break
            except (OSError, ValueError, RuntimeError):
                pass
            time.sleep(.25)
        else:
            raise RuntimeError("NCM_STARTUP_NOT_READY")
        source = "\n".join((ROOT / "src" / name).read_text(encoding="utf-8") for name in (
            "client-adapter.js", "aac-timing.js", "gapless-engine.js", "netease-gapless.js"))
        expression = source + "\n;if (!window.NcmGapless.installed) window.NcmGapless.install();\nwindow.NcmGapless.status();"
    elif arguments.action == "status":
        expression = "window.NcmGapless?.status?.() || ({installed:false})"
    else:
        expression = "window.NcmGapless?.uninstall ? window.NcmGapless.uninstall() : ({installed:false})"
    report = value(port, expression, user_gesture=arguments.action != "status")
    print(json.dumps({"port": port, **report}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Native/CDP errors can contain private paths or request data.
        message = str(error)
        print(message if re.fullmatch(r"[A-Z][A-Z0-9_]+", message)
              else "NCM_OPERATION_FAILED", file=sys.stderr)
        raise SystemExit(1)
