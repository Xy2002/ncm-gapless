"""Build and sign the fixed macOS runtime; never publish or retain signing keys."""
import argparse
import base64
import binascii
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

from build_portable import VERSION
from macos_updates import RUNTIME_FILES, parse_signed_release, read_payload

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_KEY = Path(__file__).with_name("macos-update-public-key.pem")


def build(sequence, tag, version, key=None):
    if type(sequence) is not int or sequence <= 0:
        raise ValueError("NCM_RELEASE_SEQUENCE_INVALID")
    if not re.fullmatch(r"macos-release-v[A-Za-z0-9._-]+", tag):
        raise ValueError("NCM_RELEASE_TAG_INVALID")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[a-z0-9.]+)?", version):
        raise ValueError("NCM_RELEASE_VERSION_INVALID")
    try:
        private_key = (Path(key).read_bytes() if key else
                       base64.b64decode(os.environ["NCM_MACOS_RELEASE_KEY"], validate=True))
    except (OSError, KeyError, ValueError, binascii.Error):
        raise RuntimeError("NCM_RELEASE_KEY_MISSING_OR_INVALID") from None
    if not 1 <= len(private_key) <= 65536:
        raise RuntimeError("NCM_RELEASE_KEY_MISSING_OR_INVALID")

    with tempfile.TemporaryDirectory(prefix="ncm-macos-release-") as temporary:
        temporary = Path(temporary)
        temporary.chmod(0o700)
        private_path = temporary / "signing-key.pem"
        private_path.write_bytes(private_key)
        private_path.chmod(0o600)
        del private_key
        try:
            actual_key = subprocess.run(
                ["openssl", "pkey", "-in", str(private_path), "-passin", "pass:", "-pubout", "-outform", "DER"],
                check=True, capture_output=True).stdout
            expected_key = subprocess.run(
                ["openssl", "pkey", "-pubin", "-in", str(PUBLIC_KEY), "-outform", "DER"],
                check=True, capture_output=True).stdout
        except (OSError, subprocess.SubprocessError):
            raise RuntimeError("NCM_RELEASE_KEY_INVALID") from None
        if actual_key != expected_key:
            raise RuntimeError("NCM_RELEASE_KEY_MISMATCH")

        output = BytesIO()
        files = {}
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in RUNTIME_FILES:
                data = (ROOT / name).read_bytes()
                files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, data)
        package = output.getvalue()
        document = {
            "schema": 1, "channel": "macos-maintenance", "sequence": sequence, "version": version,
            "package": {
                "url": f"https://github.com/Xy2002/ncm-gapless/releases/download/{tag}/macos-payload.zip",
                "sha256": hashlib.sha256(package).hexdigest(), "bytes": len(package),
            },
            "files": files,
        }
        payload = json.dumps(document, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        payload_path = temporary / "payload.json"
        payload_path.write_bytes(payload)
        payload_path.chmod(0o600)
        try:
            signature = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", str(private_path), "-passin", "pass:", str(payload_path)],
                check=True, capture_output=True).stdout
        except (OSError, subprocess.SubprocessError):
            raise RuntimeError("NCM_RELEASE_SIGN_FAILED") from None
        envelope = json.dumps({
            "payload": base64.b64encode(payload).decode("ascii"),
            "signature": base64.b64encode(signature).decode("ascii"),
        }, separators=(",", ":")).encode("utf-8")
        release = parse_signed_release(envelope, PUBLIC_KEY)
        read_payload(package, release)

    directory = ROOT / "artifacts/macos-maintenance"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=directory) as staging:
        for name, data in (("macos-payload.zip", package), ("macos-update.json", envelope)):
            staged = Path(staging) / name
            staged.write_bytes(data)
            staged.chmod(0o600)
            staged.replace(directory / name)
    print(f"Signed macOS release {version} sequence {sequence} ({len(package)} bytes)")
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sequence", required=True, type=int)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", default=VERSION)
    parser.add_argument("--key", type=Path, help="PEM private key; otherwise use base64 NCM_MACOS_RELEASE_KEY")
    args = parser.parse_args()
    build(args.sequence, args.tag, args.version, args.key)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(str(error)) from None
