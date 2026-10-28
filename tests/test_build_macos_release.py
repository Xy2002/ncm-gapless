"""Sign disposable fixtures with real RSA keys; never use a production private key."""
import base64
from contextlib import redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_macos_release as builder
import build_portable as portable
from macos_updates import RUNTIME_FILES, parse_signed_release, read_payload


@unittest.skipUnless(sys.platform != "win32" and Path("/usr/bin/openssl").is_file() and shutil.which("openssl"),
                     "macOS release verification requires /usr/bin/openssl")
class MacReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix="ncm-release-test-")
        cls.private = Path(cls.keys.name) / "private.pem"
        cls.public = Path(cls.keys.name) / "public.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072",
                        "-out", str(cls.private)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(cls.private), "-pubout", "-out", str(cls.public)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ncm-release-source-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in RUNTIME_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"websocket-client==1.9.0\n" if name == "requirements-macos.txt" else
                             ("fixture: " + name).encode())
        for attribute, value in (("ROOT", self.root), ("PUBLIC_KEY", self.public)):
            mocked = patch.object(builder, attribute, value)
            mocked.start()
            self.addCleanup(mocked.stop)

    def build(self, **kwargs):
        with redirect_stdout(StringIO()):
            return builder.build(123, "macos-release-v0.5.0-test", "0.5.0-experimental", **kwargs)

    def test_signed_payload_verifies_and_contains_only_runtime_files(self):
        directory = self.build(key=self.private)
        envelope = (directory / "macos-update.json").read_bytes()
        release = parse_signed_release(envelope, self.public)
        self.assertEqual(release["document"]["sequence"], 123)
        self.assertEqual(release["document"]["channel"], "macos-maintenance")
        self.assertEqual(set(read_payload((directory / "macos-payload.zip").read_bytes(), release)), set(RUNTIME_FILES))
        self.assertEqual({path.name for path in directory.iterdir()}, {"macos-update.json", "macos-payload.zip"})
        tampered = json.loads(envelope)
        payload = json.loads(base64.b64decode(tampered["payload"]))
        payload["sequence"] += 1
        tampered["payload"] = base64.b64encode(json.dumps(payload).encode()).decode()
        with self.assertRaises((ValueError, RuntimeError)):
            parse_signed_release(json.dumps(tampered).encode(), self.public)

    def test_base64_environment_key_is_supported_without_copying_it_to_artifacts(self):
        secret = base64.b64encode(self.private.read_bytes()).decode()
        with patch.dict(os.environ, {"NCM_MACOS_RELEASE_KEY": secret}):
            directory = self.build()
        for path in directory.iterdir():
            self.assertNotIn(b"PRIVATE KEY", path.read_bytes())

    def test_macos_maintenance_package_includes_verified_payload_and_fixed_bootstrap(self):
        directory = self.build(key=self.private)
        for name in portable.FILES + portable.PLATFORM_FILES["macos"]:
            path = self.root / name
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(("fixture: " + name).encode())
        with patch.object(portable, "ROOT", self.root), redirect_stdout(StringIO()):
            output = portable.build("macos", include_macos_maintenance=True)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(len(archive.namelist()), len(set(archive.namelist())))
            for name in ("macos-update.json", "macos-payload.zip"):
                self.assertEqual(archive.read("ncm-gapless/updates/" + name), (directory / name).read_bytes())
            for name in ("macos_maintenance.py", "macos_updates.py", "macos-update-public-key.pem"):
                self.assertIn("ncm-gapless/tools/" + name, archive.namelist())
            self.assertTrue(all("private" not in name and ".dpapi" not in name for name in archive.namelist()))
            release = parse_signed_release(archive.read("ncm-gapless/updates/macos-update.json"), self.public)
            self.assertEqual(set(read_payload(archive.read("ncm-gapless/updates/macos-payload.zip"), release)), set(RUNTIME_FILES))

    def test_wrong_signing_key_is_rejected_before_creating_artifacts(self):
        with patch.object(builder, "PUBLIC_KEY", Path(__file__).resolve().parents[1] / "tools/macos-update-public-key.pem"):
            with self.assertRaisesRegex(RuntimeError, "NCM_RELEASE_KEY_MISMATCH"):
                self.build(key=self.private)
        self.assertFalse((self.root / "artifacts").exists())

    def test_bad_metadata_or_secret_does_not_create_artifacts(self):
        for sequence, tag, version in ((0, "macos-release-v1", "0.5.0"),
                                       (1, "../macos-release-v1", "0.5.0"),
                                       (1, "macos-release-v1", "bad\nversion"),
                                       (1, "macos-release-v1", "0.6.0+build"),
                                       (1, "macos-release-v1", "0.6.0-RC1")):
            with self.subTest(sequence=sequence, tag=tag, version=version), self.assertRaises(ValueError):
                builder.build(sequence, tag, version, self.private)
        with patch.dict(os.environ, {"NCM_MACOS_RELEASE_KEY": "not base64"}):
            with self.assertRaisesRegex(RuntimeError, "NCM_RELEASE_KEY_MISSING_OR_INVALID"):
                self.build()
        self.assertFalse((self.root / "artifacts").exists())


if __name__ == "__main__":
    unittest.main()
