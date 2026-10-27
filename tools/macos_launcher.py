"""Launch or control the verified macOS client without changing its app bundle."""
import argparse
from contextlib import contextmanager
import importlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from cdp_probe import evaluate, get_page

ROOT = Path(__file__).resolve().parents[1]
CLIENT_VERSION = "3.1.12.3444"
AUTOMATION_DIR = Path.home() / "Library/Application Support/NcmGapless"
SHORTCUT_NAME = "NCM Gapless 自动启用"


def atomic_write(path, data, *, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


def automation_settings():
    try:
        data = json.loads((AUTOMATION_DIR / "enabled.json").read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (ValueError, UnicodeError):
        raise RuntimeError("NCM_AUTOMATION_STATE_INVALID") from None
    if (not isinstance(data, dict) or
            any(not isinstance(data.get(key), str) for key in ("root", "clientPath", "token")) or
            not Path(data["root"]).is_absolute() or not Path(data["clientPath"]).is_absolute() or
            not re.fullmatch(r"[0-9a-f]{32}", data["token"])):
        raise RuntimeError("NCM_AUTOMATION_STATE_INVALID")
    return data


@contextmanager
def operation(*, wait=True):
    import fcntl
    AUTOMATION_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (AUTOMATION_DIR / "operation.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def check_automation(settings):
    if automation_settings() != settings:
        raise RuntimeError("NCM_AUTO_ENABLE_CANCELLED")
    if settings["root"] != str(ROOT):
        raise RuntimeError("NCM_AUTOMATION_SOURCE_CHANGED")


def shortcut_installed():
    result = subprocess.run(["/usr/bin/shortcuts", "list"], check=True, capture_output=True,
                            text=True, timeout=15)
    count = result.stdout.splitlines().count(SHORTCUT_NAME)
    if count > 1:
        raise RuntimeError("NCM_AUTOMATION_SHORTCUT_NOT_UNIQUE")
    return count == 1


def prepare_shortcut(settings):
    if shortcut_installed():
        return True
    workflow = json.loads((ROOT / "tools/macos_automation.json").read_text(encoding="utf-8"))
    workflow["WFWorkflowTriggers"][0]["WFTriggerUUID"] = str(uuid.uuid4()).upper()
    workflow["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["UUID"] = str(uuid.uuid4()).upper()
    source = AUTOMATION_DIR / "automation-unsigned.shortcut"
    output = AUTOMATION_DIR / f"{SHORTCUT_NAME}.shortcut"
    atomic_write(source, plistlib.dumps(workflow))
    try:
        subprocess.run(["/usr/bin/shortcuts", "sign", "--mode", "anyone", "--input", str(source),
                        "--output", str(output)], check=True, capture_output=True, timeout=60)
        check_automation(settings)
        subprocess.run(["/usr/bin/open", "-a", "/System/Applications/Shortcuts.app", str(output)],
                       check=True, capture_output=True, timeout=10)
    except subprocess.SubprocessError:
        raise RuntimeError("NCM_AUTOMATION_IMPORT_FAILED") from None
    print("首次配置：在快捷指令中完成导入，展开网易云 App 条件并打开自动化；在设置中允许脚本操作。", file=sys.stderr)
    return False


def automatic_status():
    settings = automation_settings()
    result = {"automaticEnabled": settings is not None}
    if settings:
        result["shortcutImported"] = shortcut_installed()
        try:
            last = json.loads((AUTOMATION_DIR / "last-run.json").read_text(encoding="utf-8"))
            if isinstance(last, dict) and last.get("token") == settings["token"]:
                result["automaticLastRun"] = {key: last[key] for key in ("at", "installed", "error") if key in last}
        except (FileNotFoundError, ValueError, UnicodeError):
            pass
    return result


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


def quit_client(app, *, check=None):
    if check:
        check()
    script = '''function run(paths) {
        ObjC.import('AppKit');
        const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.netease.163music');
        let found = false;
        for (let i = 0; i < apps.count; i++) {
            const app = apps.objectAtIndex(i);
            if (ObjC.unwrap(app.bundleURL.path) === paths[0]) {
                found = true;
                if (!app.terminate) throw new Error('NCM_CLIENT_QUIT_FAILED');
            }
        }
        return found;
    }'''
    try:
        result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(app)],
                                check=True, capture_output=True, text=True, timeout=10)
    except subprocess.SubprocessError:
        raise RuntimeError("NCM_CLIENT_QUIT_FAILED") from None
    if result.stdout.strip() != "true":
        raise RuntimeError("NCM_NOT_RUNNING")
    executable = str(app / "Contents/MacOS/NeteaseMusic")
    deadline = time.monotonic() + 15
    while any(command == executable or command.startswith(executable + " ") for command in running_commands()):
        if check:
            check()
        if time.monotonic() >= deadline:
            raise RuntimeError("NCM_CLIENT_QUIT_TIMEOUT")
        time.sleep(.25)


def find_port(*, launch=False, client_path=None, restart=False, check=None):
    app = find_client(client_path)
    commands = running_commands()
    executable = str(app / "Contents/MacOS/NeteaseMusic")
    for command in commands:
        if command != executable and not command.startswith(executable + " "):
            continue
        match = re.search(r"(?:^|\s)--remote-debugging-port(?:=|\s+)(\d+)(?:\s|$)", command)
        if match:
            port = int(match[1])
            deadline = time.monotonic() + (30 if restart else 0)
            while True:
                if check:
                    check()
                try:
                    get_page(port)
                    return port
                except (OSError, ValueError, RuntimeError):
                    if not restart:
                        break
                    if time.monotonic() >= deadline:
                        raise RuntimeError("NCM_DEBUG_PORT_NOT_READY") from None
                    if command not in running_commands():
                        raise RuntimeError("NCM_NOT_RUNNING") from None
                    time.sleep(.25)
    if commands:
        if not restart:
            raise RuntimeError("NCM_EXIT_AND_RESTART_WITH_LAUNCHER")
        if any(command != executable and not command.startswith(executable + " ") for command in commands):
            raise RuntimeError("NCM_OTHER_CLIENT_RUNNING")
        quit_client(app, check=check)
    elif not launch:
        raise RuntimeError("NCM_NOT_RUNNING")
    if check:
        check()
    port = available_port()
    subprocess.run(["/usr/bin/open", "-a", str(app), "--args",
                    "--remote-debugging-address=127.0.0.1",
                    f"--remote-debugging-port={port}"], check=True, capture_output=True, timeout=10)
    deadline = time.monotonic() + 30
    appeared = False
    while time.monotonic() < deadline:
        if check:
            check()
        try:
            get_page(port)
            return port
        except (OSError, ValueError, RuntimeError):
            pass
        if restart:
            current = any(command == executable or command.startswith(executable + " ") for command in running_commands())
            if appeared and not current:
                raise RuntimeError("NCM_NOT_RUNNING")
            appeared = appeared or current
        time.sleep(.25)
    raise RuntimeError("NCM_START_TIMEOUT")


def value(port, expression, *, user_gesture=False):
    response = evaluate(port, expression, user_gesture=user_gesture)
    result = response.get("result", {})
    if response.get("error") or result.get("exceptionDetails") or "value" not in result.get("result", {}):
        raise RuntimeError("NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE")
    return result["result"]["value"]


def install_patch(port, *, check=None):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if check:
            check()
        try:
            if value(port, "Boolean(document.readyState === 'complete' && window.ncmChannelOSX && window.webpackJsonp && document.getElementById('root')?._reactRootContainer)"):
                break
        except (OSError, ValueError, RuntimeError):
            pass
        time.sleep(.25)
    else:
        raise RuntimeError("NCM_STARTUP_NOT_READY")
    if check:
        check()
    source = "\n".join((ROOT / "src" / name).read_text(encoding="utf-8") for name in (
        "client-adapter.js", "aac-timing.js", "gapless-engine.js", "netease-gapless.js"))
    expression = source + "\n;if (!window.NcmGapless.installed) window.NcmGapless.install();\nwindow.NcmGapless.status();"
    return value(port, expression, user_gesture=True)


def uninstall_patch(port):
    try:
        return value(port, "window.NcmGapless?.uninstall ? window.NcmGapless.uninstall() : ({installed:false})",
                     user_gesture=True)
    except RuntimeError as error:
        if str(error) != "NCM_CDP_CONNECTION_FAILED":
            raise
        report = value(port, "window.NcmGapless?.status?.() || ({installed:false})")
        if report.get("installed"):
            raise error
        return report


def enable_automatic(app):
    settings = {"root": str(ROOT), "clientPath": str(app), "token": uuid.uuid4().hex}
    with operation():
        entry = "#!/bin/sh\nexec " + " ".join(shlex.quote(str(arg)) for arg in (
            sys.executable, Path(__file__).resolve(), "on-open")) + "\n"
        atomic_write(AUTOMATION_DIR / "on-open.command", entry.encode(), mode=0o700)
        atomic_write(AUTOMATION_DIR / "enabled.json", json.dumps(settings).encode())
        check = lambda: check_automation(settings)
        try:
            port = find_port(launch=True, client_path=app, restart=True, check=check)
            report = value(port, "window.NcmGapless?.status?.() || ({installed:false})")
            if not report.get("installed"):
                report = install_patch(port, check=check)
            imported = prepare_shortcut(settings)
            check()
        except BaseException:
            if automation_settings() == settings:
                (AUTOMATION_DIR / "enabled.json").unlink(missing_ok=True)
                (AUTOMATION_DIR / "on-open.command").unlink(missing_ok=True)
            raise
    return {"port": port, **report, "automaticEnabled": True, "shortcutImported": imported,
            "shortcutImportRequired": not imported}


def on_open():
    settings = automation_settings()
    if not settings:
        return {"automaticEnabled": False}
    with operation(wait=False) as acquired:
        if not acquired:
            return {"busy": True}
        report = {"installed": False}
        error_code = None
        try:
            check = lambda: check_automation(settings)
            check()
            try:
                importlib.import_module("websocket")
            except ImportError:
                raise RuntimeError("NCM_DEPENDENCY_MISSING") from None
            port = find_port(client_path=settings["clientPath"], restart=True, check=check)
            report = value(port, "window.NcmGapless?.status?.() || ({installed:false})")
            if not report.get("installed"):
                report = install_patch(port, check=check)
            return {"port": port, **report}
        except RuntimeError as error:
            if str(error) in ("NCM_NOT_RUNNING", "NCM_AUTO_ENABLE_CANCELLED"):
                return {"installed": False}
            error_code = str(error) if re.fullmatch(r"[A-Z][A-Z0-9_]+", str(error)) else "NCM_OPERATION_FAILED"
            raise
        except (OSError, ValueError, subprocess.SubprocessError):
            error_code = "NCM_OPERATION_FAILED"
            raise
        finally:
            if automation_settings() == settings:
                atomic_write(AUTOMATION_DIR / "last-run.json", json.dumps({
                    "token": settings["token"], "at": int(time.time()),
                    "installed": report.get("installed", False), "error": error_code,
                }).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "install", "status", "disable", "on-open"))
    parser.add_argument("--client-path", type=Path, help="Path to NeteaseMusic.app")
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("NCM_MACOS_REQUIRED")
    if arguments.action == "on-open":
        report = on_open()
    elif arguments.action == "enable":
        if int((platform.mac_ver()[0] or "0").split(".")[0]) < 27:
            raise RuntimeError("NCM_AUTOMATION_REQUIRES_MACOS_27")
        ensure_runtime()
        report = enable_automatic(find_client(arguments.client_path))
    else:
        settings = None
        if arguments.action == "disable":
            try:
                settings = automation_settings()
            except (OSError, RuntimeError):
                pass
            finally:
                (AUTOMATION_DIR / "enabled.json").unlink(missing_ok=True)
                (AUTOMATION_DIR / "on-open.command").unlink(missing_ok=True)
        elif arguments.action == "status":
            settings = automation_settings()
        if settings and arguments.client_path is None:
            arguments.client_path = Path(settings["clientPath"])
        with operation():
            try:
                port = find_port(launch=arguments.action == "install", client_path=arguments.client_path)
            except RuntimeError as error:
                if arguments.action == "install" or str(error) not in ("NCM_NOT_RUNNING", "NCM_EXIT_AND_RESTART_WITH_LAUNCHER"):
                    raise
                report = {"installed": False, "running": bool(running_commands())}
            else:
                ensure_runtime()
                if arguments.action == "install":
                    report = install_patch(port)
                elif arguments.action == "status":
                    report = value(port, "window.NcmGapless?.status?.() || ({installed:false})")
                else:
                    report = uninstall_patch(port)
                report = {"port": port, **report}
        report = {**report, **automatic_status()}
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Native/CDP errors can contain private paths or request data.
        message = str(error)
        print(message if re.fullmatch(r"[A-Z][A-Z0-9_]+", message)
              else "NCM_OPERATION_FAILED", file=sys.stderr)
        raise SystemExit(1)
