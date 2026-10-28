"""Signed, versioned Mac runtimes. Callers serialize mutations with operation.lock."""
import base64
import hashlib
from http.client import HTTPException
from io import BytesIO
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile


RUNTIME_FILES = (
    "src/client-adapter.js", "src/aac-timing.js", "src/gapless-engine.js",
    "src/netease-gapless.js", "tools/macos_launcher.py", "tools/cdp_probe.py",
    "tools/macos_automation.json", "requirements-macos.txt",
)
FEED_URL = "https://github.com/Xy2002/ncm-gapless/releases/download/macos-maintenance/macos-update.json"
MANIFEST_LIMIT = 131072
PACKAGE_LIMIT = 8388608
FILE_LIMIT = 2097152
DEPENDENCIES = b"websocket-client==1.9.0"
_HASH = re.compile(r"[0-9a-f]{64}\Z")
_PACKAGE_URL = re.compile(r"https://github\.com/Xy2002/ncm-gapless/releases/download/macos-release-v[a-zA-Z0-9._-]+/macos-payload\.zip\Z")
_HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"}


class UpdateError(RuntimeError):
    pass


class _Cancelled(Exception):
    def __init__(self, error):
        self.error = error


def _check(callback):
    try:
        callback()
    except Exception as error:
        raise _Cancelled(error) from error


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _json(data, code="NCM_UPDATE_MANIFEST_INVALID"):
    def pairs(entries):
        result = {}
        for key, value in entries:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    def reject_constant(_):
        raise ValueError("non-JSON number")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs,
                          parse_constant=reject_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise UpdateError(code) from None


def _keys(value, expected):
    return isinstance(value, dict) and set(value) == set(expected)


def _hash(value):
    return isinstance(value, str) and _HASH.fullmatch(value) is not None


def _read(path, maximum):
    path = Path(path)
    if path.is_symlink():
        raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
                raise UpdateError("NCM_UPDATE_FILE_INVALID")
            result = stream.read(maximum + 1)
            if len(result) > maximum:
                raise UpdateError("NCM_UPDATE_FILE_INVALID")
            return result
    except OSError:
        raise UpdateError("NCM_UPDATE_FILE_UNAVAILABLE") from None


def _directory(path):
    path = Path(path)
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def _base(path):
    path = Path(path).expanduser().absolute()
    _directory(path)
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise UpdateError("NCM_UPDATE_DIRECTORY_UNSAFE")
    return path.resolve()


def _atomic(path, data, check=lambda: None):
    _directory(path.parent)
    if path.is_symlink():
        raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        _check(check)
        temporary.replace(path)
        _sync_directory(path.parent)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _file_list(files):
    if not _keys(files, RUNTIME_FILES):
        raise UpdateError("NCM_UPDATE_FILE_LIST_INVALID")
    for metadata in files.values():
        if (not _keys(metadata, ("sha256", "bytes")) or not _hash(metadata["sha256"]) or
                type(metadata["bytes"]) is not int or not 0 < metadata["bytes"] <= FILE_LIMIT):
            raise UpdateError("NCM_UPDATE_FILE_LIST_INVALID")


def _validate_public_key(key):
    try:
        info = subprocess.run(["/usr/bin/openssl", "rsa", "-pubin", "-text", "-noout"],
                              input=key, capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        raise UpdateError("NCM_UPDATE_VERIFIER_UNAVAILABLE") from None
    bits = re.search(rb"Public-Key: \((\d+) bit\)", info.stdout)
    if info.returncode or not bits or not 3072 <= int(bits[1]) <= 8192:
        raise UpdateError("NCM_UPDATE_KEY_INVALID")


def parse_signed_release(envelope, public_key):
    """Verify original payload bytes before trusting a release document."""
    if not isinstance(envelope, bytes) or len(envelope) > MANIFEST_LIMIT:
        raise UpdateError("NCM_UPDATE_MANIFEST_TOO_LARGE")
    wrapper = _json(envelope)
    if not _keys(wrapper, ("payload", "signature")) or any(type(value) is not str for value in wrapper.values()):
        raise UpdateError("NCM_UPDATE_MANIFEST_INVALID")
    try:
        payload = base64.b64decode(wrapper["payload"], validate=True)
        signature = base64.b64decode(wrapper["signature"], validate=True)
    except ValueError:
        raise UpdateError("NCM_UPDATE_SIGNATURE_INVALID") from None
    key = _read(public_key, 8192)
    _validate_public_key(key)
    with tempfile.TemporaryDirectory(prefix="ncm-verify-") as temporary:
        directory = Path(temporary)
        for name, data in (("key.pem", key), ("payload", payload), ("signature", signature)):
            (directory / name).write_bytes(data)
        try:
            verification = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-verify", str(directory / "key.pem"),
                                           "-signature", str(directory / "signature"), str(directory / "payload")],
                                          capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            raise UpdateError("NCM_UPDATE_VERIFIER_UNAVAILABLE") from None
        if verification.returncode:
            raise UpdateError("NCM_UPDATE_SIGNATURE_INVALID")
    document = _json(payload)
    if (not _keys(document, ("schema", "channel", "sequence", "version", "package", "files")) or
            type(document["schema"]) is not int or document["schema"] != 1 or document["channel"] != "macos-maintenance" or
            type(document["sequence"]) is not int or not 0 < document["sequence"] < 2**63 or
            not isinstance(document["version"], str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[a-z0-9.]+)?", document["version"])):
        raise UpdateError("NCM_UPDATE_MANIFEST_INVALID")
    package = document["package"]
    if (not _keys(package, ("url", "sha256", "bytes")) or not isinstance(package["url"], str) or
            not _PACKAGE_URL.fullmatch(package["url"]) or not _hash(package["sha256"]) or
            type(package["bytes"]) is not int or not 0 < package["bytes"] <= PACKAGE_LIMIT):
        raise UpdateError("NCM_UPDATE_MANIFEST_INVALID")
    _file_list(document["files"])
    return {"document": document, "digest": _digest(payload), "envelope": envelope}


def _dependencies(files):
    if files["requirements-macos.txt"].strip() != DEPENDENCIES:
        raise UpdateError("NCM_UPDATE_DEPENDENCIES_UNSUPPORTED")


def read_payload(package, release):
    document = release["document"]
    if len(package) != document["package"]["bytes"] or _digest(package) != document["package"]["sha256"]:
        raise UpdateError("NCM_UPDATE_PACKAGE_HASH_INVALID")
    files = {}
    try:
        with zipfile.ZipFile(BytesIO(package)) as archive:
            entries = archive.infolist()
            if len(entries) != len(RUNTIME_FILES):
                raise UpdateError("NCM_UPDATE_ARCHIVE_INVALID")
            for entry in entries:
                kind = stat.S_IFMT(entry.external_attr >> 16)
                if (entry.filename not in RUNTIME_FILES or entry.filename in files or entry.orig_filename != entry.filename or
                        entry.is_dir() or kind not in (0, stat.S_IFREG) or entry.flag_bits & 1 or
                        entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                    raise UpdateError("NCM_UPDATE_ARCHIVE_INVALID")
                metadata = document["files"][entry.filename]
                if entry.file_size != metadata["bytes"]:
                    raise UpdateError("NCM_UPDATE_FILE_HASH_INVALID")
                data = archive.read(entry)
                if len(data) != metadata["bytes"] or _digest(data) != metadata["sha256"]:
                    raise UpdateError("NCM_UPDATE_FILE_HASH_INVALID")
                files[entry.filename] = data
    except (zipfile.BadZipFile, ValueError, NotImplementedError, RuntimeError) as error:
        if isinstance(error, UpdateError):
            raise
        raise UpdateError("NCM_UPDATE_ARCHIVE_INVALID") from None
    _dependencies(files)
    return files


def _pointer(value):
    return _keys(value, ("kind", "digest")) and value["kind"] in ("local", "signed") and _hash(value["digest"])


def _empty_state():
    return {"schema": 1, "active": None, "previous": None, "highestSequence": 0, "highestDigest": None,
            "quarantine": [], "failures": [], "nextCheck": 0, "checkedAt": 0, "result": "not-installed",
            "error": None, "activationError": None}


def _state(base):
    path = base / "update-state.json"
    if not path.exists() and not path.is_symlink():
        return _empty_state()
    state = _json(_read(path, MANIFEST_LIMIT), "NCM_UPDATE_STATE_INVALID")
    if (not _keys(state, _empty_state()) or type(state["schema"]) is not int or state["schema"] != 1 or
            any(value is not None and not _pointer(value) for value in (state["active"], state["previous"])) or
            type(state["highestSequence"]) is not int or not 0 <= state["highestSequence"] < 2**63 or
            (state["highestDigest"] is not None and not _hash(state["highestDigest"])) or
            (state["highestSequence"] == 0) != (state["highestDigest"] is None) or
            any(type(state[key]) is not int or state[key] < 0 for key in ("nextCheck", "checkedAt")) or
            not isinstance(state["quarantine"], list) or not all(_hash(value) for value in state["quarantine"]) or
            not isinstance(state["failures"], list) or len(state["failures"]) > 3 or
            not all(isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9:._-]{1,160}", value) for value in state["failures"]) or
            not isinstance(state["result"], str) or not re.fullmatch(r"[a-z-]{1,40}", state["result"]) or
            any(value is not None and (not isinstance(value, str) or not re.fullmatch(r"[A-Z_]{1,120}", value))
                for value in (state["error"], state["activationError"]))):
        raise UpdateError("NCM_UPDATE_STATE_INVALID")
    return state


def _save(base, state, check=lambda: None):
    _atomic(base / "update-state.json", json.dumps(state, sort_keys=True, separators=(",", ":")).encode(), check)


def _runtime(base, pointer, directory=None):
    if not _pointer(pointer):
        raise UpdateError("NCM_UPDATE_NOT_INSTALLED")
    versions = base / "versions"
    if versions.is_symlink():
        raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
    directory = directory or versions / pointer["digest"]
    if directory.is_symlink() or not directory.is_dir():
        raise UpdateError("NCM_UPDATE_RUNTIME_INVALID")
    name = "local-manifest.json" if pointer["kind"] == "local" else "signed-manifest.json"
    manifest = _read(directory / name, MANIFEST_LIMIT)
    if pointer["kind"] == "signed":
        release = parse_signed_release(manifest, base / "macos-update-public-key.pem")
        document, digest = release["document"], release["digest"]
    else:
        document, digest = _json(manifest), _digest(manifest)
        if (not _keys(document, ("schema", "kind", "version", "files")) or type(document["schema"]) is not int or
                document["schema"] != 1 or document["kind"] != "local" or document["version"] != "local"):
            raise UpdateError("NCM_UPDATE_RUNTIME_INVALID")
        _file_list(document["files"])
    if digest != pointer["digest"]:
        raise UpdateError("NCM_UPDATE_RUNTIME_INVALID")
    expected = set(RUNTIME_FILES) | {name, "src", "tools"}
    for path in directory.rglob("*"):
        if path.is_symlink() or path.relative_to(directory).as_posix() not in expected:
            raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
    files = {}
    for relative in RUNTIME_FILES:
        path = directory / relative
        if path.parent.is_symlink():
            raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
        data = _read(path, FILE_LIMIT)
        metadata = document["files"][relative]
        if len(data) != metadata["bytes"] or _digest(data) != metadata["sha256"]:
            raise UpdateError("NCM_UPDATE_FILE_HASH_INVALID")
        files[relative] = data
    _dependencies(files)
    return directory, document


def _store(base, pointer, manifest, files, check=lambda: None):
    versions = _directory(base / "versions")
    target = versions / pointer["digest"]
    if target.exists() or target.is_symlink():
        _runtime(base, pointer)
        return target
    stage = Path(tempfile.mkdtemp(prefix=".staging-", dir=versions))
    try:
        name = "local-manifest.json" if pointer["kind"] == "local" else "signed-manifest.json"
        for relative, data in (*files.items(), (name, manifest)):
            _check(check)
            path = stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            path.chmod(0o444)
        _runtime(base, pointer, stage)
        _check(check)
        for path in (stage / "src", stage / "tools", stage):
            path.chmod(0o555)
            _sync_directory(path)
        stage.rename(target)
        _sync_directory(versions)
    finally:
        if stage.exists():
            for path in (stage, stage / "src", stage / "tools"):
                if path.is_dir():
                    path.chmod(0o700)
            shutil.rmtree(stage)
    return target


def install_local(source_root, base):
    """Install explicitly selected local source; it is not a signed release."""
    base = _base(base)
    source = Path(source_root).resolve()
    state = _state(base)
    key_path = source / "tools/macos-update-public-key.pem"
    public_key = _read(key_path, 8192)
    pinned = base / "macos-update-public-key.pem"
    needs_pin = not pinned.exists() and not pinned.is_symlink()
    if not needs_pin:
        if _read(pinned, 8192) != public_key:
            raise UpdateError("NCM_UPDATE_KEY_CHANGE_REJECTED")
    updates = source / "updates"
    if updates.exists() or updates.is_symlink():
        if updates.is_symlink() or not updates.is_dir():
            raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
        release = parse_signed_release(_read(updates / "macos-update.json", MANIFEST_LIMIT), key_path if needs_pin else pinned)
        sequence, digest = release["document"]["sequence"], release["digest"]
        if sequence < state["highestSequence"] or (sequence == state["highestSequence"] and digest != state["highestDigest"]):
            raise UpdateError("NCM_UPDATE_ROLLBACK_REJECTED")
        if digest in state["quarantine"]:
            raise UpdateError("NCM_UPDATE_QUARANTINED")
        files = read_payload(_read(updates / "macos-payload.zip", PACKAGE_LIMIT), release)
        pointer = {"kind": "signed", "digest": digest}
        if needs_pin:
            _atomic(pinned, public_key)
        runtime = _store(base, pointer, release["envelope"], files)
        if state["active"] != pointer:
            state["previous"], state["active"] = state["active"], pointer
        state.update(highestSequence=sequence, highestDigest=digest, failures=[], activationError=None,
                     result="signed-installed", nextCheck=0)
        _save(base, state)
        return runtime
    _validate_public_key(public_key)
    files = {}
    for relative in RUNTIME_FILES:
        path = source / relative
        if path.parent.is_symlink():
            raise UpdateError("NCM_UPDATE_PATH_UNSAFE")
        files[relative] = _read(path, FILE_LIMIT)
    _dependencies(files)
    document = {"schema": 1, "kind": "local", "version": "local",
                "files": {name: {"sha256": _digest(data), "bytes": len(data)} for name, data in files.items()}}
    _file_list(document["files"])
    manifest = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
    pointer = {"kind": "local", "digest": _digest(manifest)}
    if needs_pin:
        _atomic(pinned, public_key)
    runtime = _store(base, pointer, manifest, files)
    if state["active"] != pointer:
        state["previous"], state["active"] = state["active"], pointer
    state.update(failures=[], activationError=None, result="local-installed", nextCheck=0)
    state["quarantine"] = [value for value in state["quarantine"] if value != pointer["digest"]]
    _save(base, state)
    return runtime


def active_runtime(base):
    base = _base(base)
    return _runtime(base, _state(base)["active"])[0]


def _approved_url(url):
    try:
        parts = urlsplit(url)
        approved = parts.scheme == "https" and parts.hostname in _HOSTS and parts.port in (None, 443) and not parts.username and not parts.password
    except ValueError:
        approved = False
    if not approved:
        raise UpdateError("NCM_UPDATE_DOWNLOAD_URL_REJECTED")


class _Redirects(HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, request, fp, code, message, headers, url):
        _approved_url(url)
        return super().redirect_request(request, fp, code, message, headers, url)


def download(url, maximum, check=lambda: None):
    _approved_url(url)
    deadline = time.monotonic() + 25
    _check(check)
    request = Request(url, headers={"User-Agent": "ncm-gapless-macos-maintenance", "Accept-Encoding": "identity"})
    with build_opener(_Redirects()).open(request, timeout=8) as response:
        _approved_url(response.geturl())
        length = response.headers.get("Content-Length")
        if length is not None and (not re.fullmatch(r"\d+", length) or int(length) > maximum):
            raise UpdateError("NCM_UPDATE_DOWNLOAD_TOO_LARGE")
        chunks, total = [], 0
        while True:
            _check(check)
            if time.monotonic() > deadline:
                raise UpdateError("NCM_UPDATE_DOWNLOAD_TIMEOUT")
            chunk = response.read1(min(65536, maximum + 1 - total))
            if not chunk:
                return b"".join(chunks)
            total += len(chunk)
            if total > maximum:
                raise UpdateError("NCM_UPDATE_DOWNLOAD_TOO_LARGE")
            chunks.append(chunk)


def check_update(base, public_key, check=lambda: None):
    base = _base(base)
    state = _state(base)
    _runtime(base, state["active"])
    try:
        _check(check)
        if int(time.time()) < state["nextCheck"]:
            return status(base)
        if _read(public_key, 8192) != _read(base / "macos-update-public-key.pem", 8192):
            raise UpdateError("NCM_UPDATE_KEY_CHANGE_REJECTED")
        release = parse_signed_release(download(FEED_URL, MANIFEST_LIMIT, check), public_key)
        _check(check)
        sequence, digest = release["document"]["sequence"], release["digest"]
        if sequence < state["highestSequence"] or (sequence == state["highestSequence"] and digest != state["highestDigest"]):
            raise UpdateError("NCM_UPDATE_ROLLBACK_REJECTED")
        state.update(highestSequence=sequence, highestDigest=digest)
        if digest in state["quarantine"]:
            raise UpdateError("NCM_UPDATE_QUARANTINED")
        pointer = {"kind": "signed", "digest": digest}
        if pointer != state["active"]:
            package = download(release["document"]["package"]["url"], PACKAGE_LIMIT, check)
            _check(check)
            files = read_payload(package, release)
            _store(base, pointer, release["envelope"], files, check)
            state.update(previous=state["active"], active=pointer, failures=[], activationError=None, result="updated")
        else:
            state["result"] = "current"
        state.update(error=None, checkedAt=int(time.time()), nextCheck=int(time.time()) + 6 * 3600)
        _save(base, state, check)
    except _Cancelled as cancelled:
        raise cancelled.error
    except (UpdateError, OSError, HTTPException) as error:
        state.update(error=str(error) if isinstance(error, UpdateError) else "NCM_UPDATE_DOWNLOAD_FAILED",
                     result="failed", checkedAt=int(time.time()), nextCheck=int(time.time()) + 1800)
        try:
            _save(base, state, check)
        except _Cancelled as cancelled:
            raise cancelled.error
    return status(base)


def record_activation(base, runtime, receipt):
    base = _base(base)
    state = _state(base)
    active = state["active"]
    if not active or Path(runtime).absolute() != base / "versions" / active["digest"]:
        return status(base)
    instance = receipt.get("instance")
    if (not isinstance(instance, str) or not re.fullmatch(r"[a-zA-Z0-9:._-]{1,160}", instance) or
            not isinstance(receipt.get("token"), str) or not re.fullmatch(r"[0-9a-f]{32}", receipt["token"]) or
            type(receipt.get("installed")) is not bool):
        return status(base)
    error = receipt.get("error")
    if error is not None and (not isinstance(error, str) or not re.fullmatch(r"[A-Z_]{1,120}", error)):
        error = "NCM_ACTIVATION_FAILED"
    if receipt["installed"]:
        state.update(failures=[], activationError=None)
    elif not error or error.startswith(("CLIENT_", "PLAYBACK_", "WEBPACK_")) or "CANCEL" in error or error in (
            "NCM_NOT_RUNNING", "NCM_OTHER_CLIENT_RUNNING", "NCM_EXECUTABLE_UNVERIFIED", "NCM_CLIENT_SIGNATURE_UNVERIFIED",
            "NCM_CLIENT_SIGNATURE_INVALID", "NCM_CLIENT_PUBLISHER_UNVERIFIED", "NCM_STARTUP_NOT_READY",
            "NCM_DEBUG_PORT_NOT_READY", "NCM_UPDATE_DEPENDENCIES_UNSUPPORTED"):
        return status(base)
    else:
        state["activationError"] = error
        if instance not in state["failures"]:
            state["failures"] = (state["failures"] + [instance])[-3:]
        if len(state["failures"]) >= 3 and state["previous"]:
            _runtime(base, state["previous"])
            state["quarantine"] = list(dict.fromkeys(state["quarantine"] + [active["digest"]]))
            state.update(active=state["previous"], previous=None, failures=[], result="rolled-back")
    _save(base, state)
    return status(base)


def status(base):
    try:
        base = _base(base)
        state = _state(base)
        result = {key: state[key] for key in ("result", "error", "activationError", "checkedAt", "nextCheck", "highestSequence")}
        result.update(installed=state["active"] is not None, failureCount=len(state["failures"]),
                      rollbackAvailable=state["previous"] is not None)
        if state["active"]:
            _, document = _runtime(base, state["active"])
            result.update(digest=state["active"]["digest"], source=state["active"]["kind"], version=document["version"])
        return result
    except (UpdateError, OSError) as error:
        return {"installed": False, "result": "failed", "error": str(error) if isinstance(error, UpdateError) else "NCM_UPDATE_STATE_UNAVAILABLE"}
