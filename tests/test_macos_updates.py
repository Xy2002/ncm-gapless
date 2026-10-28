"""Real signatures and disk transactions; no network, client or installed automation."""
import base64
from io import BytesIO
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos_updates as updates


@unittest.skipUnless(hasattr(os, "O_NOFOLLOW") and Path("/usr/bin/openssl").is_file(), "Requires POSIX files and system OpenSSL")
class MacUpdatesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory()
        directory = Path(cls.keys.name)
        cls.private_key = directory / "private.pem"
        cls.public_key = directory / "public.pem"
        subprocess.run(["/usr/bin/openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072",
                        "-out", str(cls.private_key)], check=True, capture_output=True)
        subprocess.run(["/usr/bin/openssl", "pkey", "-in", str(cls.private_key), "-pubout", "-out", str(cls.public_key)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.source = self.directory / "source"
        self.base = self.directory / "installed"
        for name in updates.RUNTIME_FILES:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(updates.DEPENDENCIES + b"\n" if name == "requirements-macos.txt" else b"original " + name.encode())
        (self.source / "tools/macos-update-public-key.pem").write_bytes(self.public_key.read_bytes())
        self.local = updates.install_local(self.source, self.base)
        self.now = 100000

    def tearDown(self):
        for path in self.directory.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        self.temporary.cleanup()

    def sign(self, raw):
        message = self.directory / "message"
        signature = self.directory / "signature"
        message.write_bytes(raw)
        subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", str(self.private_key),
                        "-out", str(signature), str(message)], check=True, capture_output=True)
        return json.dumps({"payload": base64.b64encode(raw).decode(), "signature": base64.b64encode(signature.read_bytes()).decode()}).encode()

    def release(self, sequence=10, marker="new", *, edit=None, entries=None, dependencies=None):
        files = {name: (updates.DEPENDENCIES + b"\n" if name == "requirements-macos.txt" else (marker + " " + name).encode())
                 for name in updates.RUNTIME_FILES}
        if dependencies is not None:
            files["requirements-macos.txt"] = dependencies
        stream = BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, content in (entries if entries is not None else files.items()):
                    archive.writestr(name, content)
        package = stream.getvalue()
        document = {"schema": 1, "channel": "macos-maintenance", "sequence": sequence, "version": "0.6.0-experimental",
                    "package": {"url": "https://github.com/Xy2002/ncm-gapless/releases/download/macos-release-v0.6.0-test/macos-payload.zip",
                                "bytes": len(package), "sha256": updates._digest(package)},
                    "files": {name: {"bytes": len(content), "sha256": updates._digest(content)} for name, content in files.items()}}
        if edit:
            edit(document)
        return self.sign(json.dumps(document, separators=(",", ":")).encode()), package, document

    def check(self, release, *, callback=lambda: None):
        envelope, package, _ = release
        self.now += 22000
        with patch.object(updates.time, "time", return_value=self.now), patch.object(updates, "download", side_effect=[envelope, package]):
            return updates.check_update(self.base, self.public_key, callback)

    def receipt(self, instance, *, error="NCM_ACTIVATION_FAILED", installed=False):
        return {"token": "1" * 32, "instance": instance, "installed": installed, "error": error}

    def test_local_snapshot_is_independent_and_detects_later_modification(self):
        original = (self.local / "src/client-adapter.js").read_bytes()
        (self.source / "src/client-adapter.js").write_bytes(b"source moved or changed")
        self.assertEqual((updates.active_runtime(self.base) / "src/client-adapter.js").read_bytes(), original)
        modified = self.local / "src/client-adapter.js"
        modified.chmod(0o600)
        modified.write_bytes(b"changed installed code")
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_FILE_HASH_INVALID"):
            updates.active_runtime(self.base)
        self.assertFalse(updates.status(self.base)["installed"])

    def test_initial_local_key_is_validated_before_pinning_and_can_retry(self):
        source_key = self.source / "tools/macos-update-public-key.pem"
        valid = source_key.read_bytes()
        small = self.directory / "small.pem"
        ec = self.directory / "ec.pem"
        subprocess.run(["/usr/bin/openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:1024",
                        "-out", str(small)], check=True, capture_output=True)
        subprocess.run(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout",
                        "-out", str(ec)], check=True, capture_output=True)
        invalid_keys = [b"incomplete public key"]
        for private in (small, ec):
            invalid_keys.append(subprocess.run(["/usr/bin/openssl", "pkey", "-in", str(private), "-pubout"],
                                               check=True, capture_output=True).stdout)
        for index, invalid in enumerate(invalid_keys):
            with self.subTest(key=index):
                base = self.directory / f"fresh-local-{index}"
                source_key.write_bytes(invalid)
                with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_KEY_INVALID"):
                    updates.install_local(self.source, base)
                self.assertFalse((base / "macos-update-public-key.pem").exists())
                source_key.write_bytes(valid)
                self.assertEqual(updates.install_local(self.source, base), updates.active_runtime(base))

    def test_failed_initial_signed_package_does_not_pin_key_and_can_retry(self):
        source_key = self.source / "tools/macos-update-public-key.pem"
        valid_key = source_key.read_bytes()
        envelope, package, _ = self.release()
        unsupported_envelope, unsupported_package, _ = self.release(dependencies=b"other-package==1.0\n")
        target = self.source / "updates"
        target.mkdir()
        variants = [(b"incomplete public key", envelope, package),
                    (valid_key, envelope[:-1], package), (valid_key, envelope, package + b"damaged"),
                    (valid_key, unsupported_envelope, unsupported_package)]
        for index, (key, initial_envelope, initial_package) in enumerate(variants):
            with self.subTest(package=index):
                base = self.directory / f"fresh-signed-{index}"
                source_key.write_bytes(key)
                (target / "macos-update.json").write_bytes(initial_envelope)
                (target / "macos-payload.zip").write_bytes(initial_package)
                with self.assertRaises(updates.UpdateError):
                    updates.install_local(self.source, base)
                self.assertFalse((base / "macos-update-public-key.pem").exists())
                self.assertFalse((base / "update-state.json").exists())
                source_key.write_bytes(valid_key)
                (target / "macos-update.json").write_bytes(envelope)
                (target / "macos-payload.zip").write_bytes(package)
                self.assertEqual(updates.install_local(self.source, base), updates.active_runtime(base))
                self.assertEqual(updates.status(base)["source"], "signed")

    def test_real_signature_and_complete_payload(self):
        envelope, package, _ = self.release()
        release = updates.parse_signed_release(envelope, self.public_key)
        self.assertEqual(set(updates.read_payload(package, release)), set(updates.RUNTIME_FILES))
        wrapper = json.loads(envelope)
        wrapper["payload"] = base64.b64encode(b"{}").decode()
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_SIGNATURE_INVALID"):
            updates.parse_signed_release(json.dumps(wrapper).encode(), self.public_key)
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_PACKAGE_HASH_INVALID"):
            updates.read_payload(package + b"changed", release)

    def test_signed_schema_types_keys_urls_and_duplicate_json_are_rejected(self):
        changes = [lambda d: d.update(sequence=True), lambda d: d.update(schema=True),
                   lambda d: d.update(extra="command"), lambda d: d["package"].update(bytes=True),
                   lambda d: d["package"].update(url="http://github.com/evil.zip"),
                   lambda d: d["package"].update(url="https://github.com/Xy2002/ncm-gapless/releases/download/macos-maintenance/macos-payload.zip"),
                   lambda d: d["files"].update({"../escape": {"bytes": 1, "sha256": "1" * 64}})]
        for change in changes:
            with self.subTest(change=change):
                envelope, _, _ = self.release(edit=change)
                with self.assertRaises(RuntimeError):
                    updates.parse_signed_release(envelope, self.public_key)
        envelope, _, document = self.release()
        duplicate = json.dumps(document).replace('"schema": 1', '"schema": 1, "schema": 1').encode()
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_MANIFEST_INVALID"):
            updates.parse_signed_release(self.sign(duplicate), self.public_key)
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_MANIFEST_INVALID"):
            updates.parse_signed_release(envelope[:-1] + b',"payload":"another"}', self.public_key)

    def test_archive_traversal_duplicate_and_symlink_never_extract(self):
        files = [(name, updates.DEPENDENCIES + b"\n" if name == "requirements-macos.txt" else ("new " + name).encode())
                 for name in updates.RUNTIME_FILES]
        link = zipfile.ZipInfo(files[0][0])
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        variants = [[("../escape", files[0][1]), *files[1:]],
                    [files[1], *files[1:]], [(link, files[0][1]), *files[1:]]]
        for entries in variants:
            with self.subTest(entries=entries[0][0]):
                envelope, package, _ = self.release(entries=entries)
                with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_ARCHIVE_INVALID"):
                    updates.read_payload(package, updates.parse_signed_release(envelope, self.public_key))
        self.assertFalse((self.directory / "escape").exists())

    def test_signed_dependency_change_cannot_modify_shared_runtime(self):
        release = self.release(dependencies=b"websocket-client==2.0.0\n")
        result = self.check(release)
        self.assertEqual(result["error"], "NCM_UPDATE_DEPENDENCIES_UNSUPPORTED")
        self.assertEqual(updates.active_runtime(self.base), self.local)
        self.assertFalse((self.base / ".venv").exists())

    def test_signed_update_is_atomic_and_previous_runtime_is_preserved(self):
        result = self.check(self.release())
        self.assertEqual(result["result"], "updated")
        self.assertEqual(result["source"], "signed")
        self.assertTrue(result["rollbackAvailable"])
        current = updates.active_runtime(self.base)
        self.assertNotEqual(current, self.local)
        self.assertTrue((self.local / "tools/macos_launcher.py").exists())
        self.assertEqual(result["highestSequence"], 10)
        self.assertNotIn(str(self.base), json.dumps(result))

    def test_replayed_or_changed_same_sequence_cannot_replace_active(self):
        self.check(self.release(10))
        current = updates.active_runtime(self.base)
        for release in (self.release(9), self.release(10, "changed")):
            result = self.check(release)
            self.assertEqual(result["error"], "NCM_UPDATE_ROLLBACK_REJECTED")
            self.assertEqual(updates.active_runtime(self.base), current)

    def test_partial_write_and_cancellation_do_not_change_active_pointer(self):
        release = self.release()
        replace = Path.rename
        def fail_stage(path, target):
            if path.name.startswith(".staging-"):
                raise OSError("simulated disk failure")
            return replace(path, target)
        with patch.object(Path, "rename", fail_stage):
            result = self.check(release)
        self.assertEqual(result["result"], "failed")
        self.assertEqual(updates.active_runtime(self.base), self.local)
        self.assertFalse(list((self.base / "versions").glob(".staging-*")))
        calls = 0
        def cancel_during_write():
            nonlocal calls
            calls += 1
            if calls == 6:
                raise RuntimeError("NCM_AUTO_ENABLE_CANCELLED")
        before_cancel = (self.base / "update-state.json").read_bytes()
        with self.assertRaisesRegex(RuntimeError, "NCM_AUTO_ENABLE_CANCELLED"):
            self.check(release, callback=cancel_during_write)
        self.assertEqual((self.base / "update-state.json").read_bytes(), before_cancel)
        self.assertEqual(updates.active_runtime(self.base), self.local)
        self.assertFalse(list((self.base / "versions").glob(".staging-*")))

    def test_directory_is_renamable_then_readonly_before_activation(self):
        rename = Path.rename
        save = updates._save
        renamed = []
        def require_writable_directory(path, target):
            if path.name.startswith(".staging-"):
                if not path.stat().st_mode & stat.S_IWUSR:
                    raise PermissionError("read-only source directory")
                renamed.append(target)
            return rename(path, target)
        def require_sealed_runtime(base, state, check=lambda: None):
            runtime = base / "versions" / state["active"]["digest"]
            for directory in (runtime, runtime / "src", runtime / "tools"):
                self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o555)
            return save(base, state, check)
        with patch.object(Path, "rename", require_writable_directory), patch.object(updates, "_save", require_sealed_runtime):
            self.assertEqual(self.check(self.release())["result"], "updated")
        self.assertEqual(renamed, [updates.active_runtime(self.base)])

    def test_interrupted_directory_sealing_keeps_old_runtime_and_retries(self):
        release = self.release()
        chmod = Path.chmod
        interrupted = []
        def fail_new_runtime(path, mode, *args, **kwargs):
            if path.parent == self.base / "versions" and not path.name.startswith(".") and mode == 0o555:
                interrupted.append(path)
                raise OSError("interrupted after rename")
            return chmod(path, mode, *args, **kwargs)
        with patch.object(Path, "chmod", fail_new_runtime):
            self.assertEqual(self.check(release)["result"], "failed")
        self.assertEqual(updates.active_runtime(self.base), self.local)
        self.assertEqual(len(interrupted), 1)
        self.assertEqual(self.check(release)["result"], "updated")
        self.assertEqual(updates.active_runtime(self.base), interrupted[0])
        self.assertEqual(stat.S_IMODE(interrupted[0].stat().st_mode), 0o555)

    def test_partial_file_write_is_discarded_before_retry(self):
        release = self.release()
        original = Path.open
        def disk_full(path, mode="r", *args, **kwargs):
            if mode == "xb" and path.name == "cdp_probe.py":
                raise OSError("disk full")
            return original(path, mode, *args, **kwargs)
        with patch.object(Path, "open", disk_full):
            self.assertEqual(self.check(release)["result"], "failed")
        self.assertEqual(updates.active_runtime(self.base), self.local)
        self.assertFalse(list((self.base / "versions").glob(".staging-*")))
        self.assertEqual(self.check(release)["result"], "updated")

    def test_cancel_after_staging_before_state_commit_keeps_old_runtime(self):
        release = self.release()
        original = (self.base / "update-state.json").read_bytes()
        def cancel_when_runtime_ready():
            if len(list((self.base / "versions").glob("[0-9a-f]*"))) > 1:
                raise RuntimeError("NCM_AUTO_ENABLE_CANCELLED")
        with self.assertRaisesRegex(RuntimeError, "NCM_AUTO_ENABLE_CANCELLED"):
            self.check(release, callback=cancel_when_runtime_ready)
        self.assertEqual((self.base / "update-state.json").read_bytes(), original)
        self.assertEqual(updates.active_runtime(self.base), self.local)

    def test_offline_keeps_working_runtime_and_error_during_throttle(self):
        with patch.object(updates.time, "time", return_value=self.now), patch.object(updates, "download", side_effect=OSError("private URL omitted")):
            result = updates.check_update(self.base, self.public_key)
        self.assertEqual(result["error"], "NCM_UPDATE_DOWNLOAD_FAILED")
        self.assertEqual(result["nextCheck"], self.now + 1800)
        with patch.object(updates.time, "time", return_value=self.now + 60), patch.object(updates, "download") as fetch:
            self.assertEqual(updates.check_update(self.base, self.public_key)["error"], result["error"])
            fetch.assert_not_called()
        self.assertEqual(updates.active_runtime(self.base), self.local)

    def test_three_distinct_failures_roll_back_and_quarantine_without_lowering_sequence(self):
        release = self.release()
        self.check(release)
        current = updates.active_runtime(self.base)
        first = self.receipt("123:456")
        self.assertEqual(updates.record_activation(self.base, current, first)["failureCount"], 1)
        self.assertEqual(updates.record_activation(self.base, current, first)["failureCount"], 1)
        updates.record_activation(self.base, current, self.receipt("124:457"))
        result = updates.record_activation(self.base, current, self.receipt("125:458"))
        self.assertEqual(result["result"], "rolled-back")
        self.assertEqual(result["highestSequence"], 10)
        self.assertEqual(updates.active_runtime(self.base), self.local)
        result = self.check(release)
        self.assertEqual(result["error"], "NCM_UPDATE_QUARANTINED")
        self.assertEqual(updates.active_runtime(self.base), self.local)

    def test_compatibility_cancellation_and_missing_instance_do_not_count(self):
        self.check(self.release())
        current = updates.active_runtime(self.base)
        for error in ("CLIENT_PLAYBACK_CONTRACT_UNSUPPORTED", "PLAYBACK_INTERFACE_MISSING", "WEBPACK_RUNTIME_UNSUPPORTED",
                      "NCM_AUTO_ENABLE_CANCELLED", "NCM_CLIENT_SIGNATURE_INVALID", "NCM_CLIENT_PUBLISHER_UNVERIFIED",
                      "NCM_STARTUP_NOT_READY", "NCM_DEBUG_PORT_NOT_READY"):
            self.assertEqual(updates.record_activation(self.base, current, self.receipt("1:2", error=error))["failureCount"], 0)
        self.assertEqual(updates.record_activation(self.base, current, self.receipt(None))["failureCount"], 0)
        updates.record_activation(self.base, current, self.receipt("3:4"))
        self.assertEqual(updates.record_activation(self.base, current, self.receipt("4:5", installed=True, error=None))["failureCount"], 0)
        self.assertEqual(updates.record_activation(self.base, self.local, self.receipt("5:6"))["failureCount"], 0)

    def test_signed_portable_install_uses_signed_bytes_and_sets_antirollback_floor(self):
        envelope, package, document = self.release(30)
        target = self.source / "updates"
        target.mkdir()
        (target / "macos-update.json").write_bytes(envelope)
        (target / "macos-payload.zip").write_bytes(package)
        (self.source / "src/client-adapter.js").write_bytes(b"untrusted unpacked copy ignored")
        runtime = updates.install_local(self.source, self.base)
        self.assertEqual(updates._digest((runtime / "src/client-adapter.js").read_bytes()), document["files"]["src/client-adapter.js"]["sha256"])
        self.assertEqual(updates.status(self.base)["highestSequence"], 30)
        self.assertEqual(self.check(self.release(29))["error"], "NCM_UPDATE_ROLLBACK_REJECTED")
        (target / "macos-payload.zip").unlink()
        with self.assertRaises(RuntimeError):
            updates.install_local(self.source, self.base)
        self.assertEqual(updates.active_runtime(self.base), runtime)

    def test_symlink_or_changed_public_key_is_never_followed(self):
        key = self.base / "macos-update-public-key.pem"
        original = key.read_bytes()
        key.write_bytes(b"changed trust anchor")
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_KEY_CHANGE_REJECTED"):
            updates.install_local(self.source, self.base)
        key.write_bytes(original)
        target = self.local / "src/client-adapter.js"
        target.parent.chmod(0o700)
        target.unlink()
        target.symlink_to(self.source / "src/client-adapter.js")
        with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_PATH_UNSAFE"):
            updates.active_runtime(self.base)

    def test_redirects_allow_only_https_github_asset_hosts(self):
        for url in ("http://github.com/file", "https://github.com.evil.test/file", "https://example.com/file",
                    "https://user:password@github.com/file", "https://github.com:444/file"):
            with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_DOWNLOAD_URL_REJECTED"):
                updates._approved_url(url)
        updates._approved_url("https://release-assets.githubusercontent.com/github-production-release-asset/file?token=private")

    def test_download_rechecks_redirect_size_and_timeout(self):
        class Response(BytesIO):
            headers = {}
            def geturl(self):
                return self.url
        def response(data, url=updates.FEED_URL, length=None):
            value = Response(data)
            value.url = url
            value.headers = {} if length is None else {"Content-Length": length}
            return value
        for value, error in ((response(b"1234", length="4"), "NCM_UPDATE_DOWNLOAD_TOO_LARGE"),
                             (response(b"1234"), "NCM_UPDATE_DOWNLOAD_TOO_LARGE"),
                             (response(b"1", "https://example.test/asset"), "NCM_UPDATE_DOWNLOAD_URL_REJECTED")):
            with self.subTest(error=error), patch.object(updates, "build_opener") as opener:
                opener.return_value.open.return_value = value
                with self.assertRaisesRegex(RuntimeError, error):
                    updates.download(updates.FEED_URL, 3)
        with patch.object(updates, "build_opener") as opener, patch.object(updates.time, "monotonic", side_effect=[0, 26]):
            opener.return_value.open.return_value = response(b"1")
            with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_DOWNLOAD_TIMEOUT"):
                updates.download(updates.FEED_URL, 3)
        with patch.object(updates, "build_opener") as opener:
            opener.return_value.open.return_value = response(b"123")
            self.assertEqual(updates.download(updates.FEED_URL, 3), b"123")

    def test_writable_shared_base_is_rejected(self):
        self.base.chmod(0o777)
        try:
            with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_DIRECTORY_UNSAFE"):
                updates.active_runtime(self.base)
        finally:
            self.base.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
