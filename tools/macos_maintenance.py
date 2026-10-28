"""Install a user-owned runtime and check signed updates after one-shot activation."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import uuid

import macos_updates as updates

BASE = Path.home() / "Library/Application Support/NcmGapless"
SOURCE = Path(__file__).resolve().parents[1]
ENTRYPOINTS = {"Start-NcmGapless.command": "setup", "Stop-NcmGapless.command": "disable",
               "Get-NcmGaplessStatus.command": "status"}


def atomic_write(path, data, mode=0o600):
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


@contextmanager
def operation(name="operation.lock"):
    import fcntl
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (BASE / name).open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def settings():
    try:
        value = json.loads((BASE / "enabled.json").read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (ValueError, UnicodeError):
        raise RuntimeError("NCM_AUTOMATION_STATE_INVALID") from None
    if (not isinstance(value, dict) or not isinstance(value.get("token"), str)
            or not re.fullmatch(r"[0-9a-f]{32}", value["token"])
            or any(not isinstance(value.get(key), str) or not Path(value[key]).is_absolute()
                   for key in ("root", "clientPath"))):
        raise RuntimeError("NCM_AUTOMATION_STATE_INVALID")
    return value


def revoke():
    (BASE / "enabled.json").unlink(missing_ok=True)
    (BASE / "on-open.command").unlink(missing_ok=True)
    (BASE / "setup-request").unlink(missing_ok=True)


def ensure_python(source):
    python = BASE / ".venv/bin/python3"
    # Recreate the environment here: venv scripts contain absolute interpreter paths.
    try:
        if not python.is_file():
            subprocess.run([sys.executable, "-m", "venv", str(BASE / ".venv")],
                           check=True, stdout=sys.stderr)
        ready = subprocess.run([str(python), "-B", "-c", "import websocket"], capture_output=True)
        if ready.returncode:
            subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                            "-r", str(source / "requirements-macos.txt")], check=True, stdout=sys.stderr)
            subprocess.run([str(python), "-B", "-c", "import websocket"], check=True, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("NCM_DEPENDENCY_SETUP_FAILED") from None
    return python


def install(source, check=lambda: None):
    with operation():
        check()
        runtime = updates.install_local(source, BASE)
        check()
        python = ensure_python(runtime)
        check()
        for name in ("macos_maintenance.py", "macos_updates.py"):
            atomic_write(BASE / name, (source / "tools" / name).read_bytes())
        for name, action in ENTRYPOINTS.items():
            command = [str(python), "-B", str(BASE / "macos_maintenance.py"), action]
            atomic_write(BASE / name, ("#!/bin/sh\nexec " + shlex.join(command) + ' "$@"\n').encode(), 0o700)
        return runtime


def maintain(runtime, enabled, receipt):
    if not enabled:
        return
    def check():
        if settings() != enabled:
            raise RuntimeError("NCM_AUTO_ENABLE_CANCELLED")
    try:
        with operation():
            check()
            if isinstance(receipt, dict) and receipt.get("token") == enabled["token"]:
                updates.record_activation(BASE, runtime, receipt)
            check()
            updates.check_update(BASE, BASE / "macos-update-public-key.pem", check=check)
    except RuntimeError as error:
        if str(error) != "NCM_AUTO_ENABLE_CANCELLED":
            print(error_code(error), file=sys.stderr)


def error_code(error):
    message = str(error)
    return message if re.fullmatch(r"[A-Z][A-Z0-9_]+", message) else "NCM_MAINTENANCE_FAILED"


def dispatch(action, client_path=None):
    if action == "on-open":
        # Keep activation receipts in order without blocking Stop or setup callbacks.
        with operation("callback.lock"):
            return _dispatch(action, client_path)
    return _dispatch(action, client_path)


def _dispatch(action, client_path=None):
    installed = Path(__file__).resolve().parent == BASE
    explicit_client = client_path is not None
    enabled = None
    if action == "disable":
        try:
            enabled = settings()
        except (OSError, RuntimeError):
            pass
        finally:
            # Revoke before waiting for an in-flight download or launcher operation.
            revoke()
        if client_path is None and enabled:
            client_path = Path(enabled["clientPath"])
    elif action == "on-open":
        enabled = settings()
        if not enabled:
            print(json.dumps({"automaticEnabled": False}))
            return 0
    elif action in ("setup", "enable") and client_path is None:
        saved = settings()
        if saved:
            client_path = Path(saved["clientPath"])
    request = None
    if action in ("setup", "enable"):
        request = uuid.uuid4().hex
        atomic_write(BASE / "setup-request", request.encode())
    def check_request():
        try:
            current = (BASE / "setup-request").read_text()
        except FileNotFoundError:
            current = None
        if current != request:
            raise RuntimeError("NCM_SETUP_CANCELLED")
    if request and not installed:
        runtime = install(SOURCE, check=check_request)
    else:
        with operation():
            if action == "disable":
                try:
                    latest = settings()
                    if latest and not explicit_client:
                        client_path = Path(latest["clientPath"])
                except (OSError, RuntimeError):
                    pass
                revoke()
            if (BASE / "update-state.json").exists():
                runtime = updates.active_runtime(BASE)
            elif installed:
                raise RuntimeError("NCM_MAINTENANCE_NOT_INSTALLED")
            else:
                runtime = SOURCE
    managed = runtime.parent == BASE / "versions"
    python = BASE / ".venv/bin/python3" if managed else Path(sys.executable)
    command = [str(python), "-B", str(runtime / "tools/macos_launcher.py"), action]
    if request:
        check_request()
        command.extend(["--request-token", request])
    if client_path is not None:
        option = "--fallback-client-path" if action == "disable" and not explicit_client else "--client-path"
        command.extend([option, str(client_path)])
    if action in ("setup", "enable", "install"):
        return subprocess.run(command).returncode
    result = subprocess.run(command, capture_output=True, text=True, timeout=150)
    receipt = None
    if result.stdout:
        if action == "on-open":
            report = json.loads(result.stdout)
            receipt = report.pop("_activationReceipt", None)
            if report:
                print(json.dumps(report, ensure_ascii=False, indent=2))
        elif action == "status" and result.returncode == 0:
            report = json.loads(result.stdout)
            if managed:
                with operation():
                    report["maintenance"] = updates.status(BASE)
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    if action == "on-open" and managed:
        # Update only after injection; the running page keeps its current version.
        maintain(runtime, enabled, receipt)
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("setup", "enable", "install", "status", "disable", "on-open"))
    parser.add_argument("--client-path", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("NCM_MACOS_REQUIRED")
    return dispatch(args.action, args.client_path)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("NCM_OPERATION_CANCELLED", file=sys.stderr)
        raise SystemExit(130)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(error_code(error), file=sys.stderr)
        raise SystemExit(1)
