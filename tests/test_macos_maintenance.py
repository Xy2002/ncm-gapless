"""Exercise installation and dispatch without touching the music app or user settings."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, redirect_stdout
from io import StringIO
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos_maintenance as maintenance
import macos_launcher as launcher
import macos_updates as updates


@unittest.skipIf(sys.platform == "win32", "Mac maintenance uses POSIX locks and OpenSSL")
class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory(prefix="mac maintenance ")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name).resolve() / "support"
        self.base.mkdir()
        mocked = patch.object(maintenance, "BASE", self.base)
        mocked.start()
        self.addCleanup(mocked.stop)
        self.runtime = self.base / "versions" / ("a" * 64)

    def enable(self):
        settings = {"token": "1" * 32, "root": str(self.base), "clientPath": "/Apps/Music With Spaces.app"}
        maintenance.atomic_write(self.base / "enabled.json", json.dumps(settings).encode())
        (self.base / "on-open.command").touch()
        return settings

    def installed(self):
        (self.base / "update-state.json").write_text("{}")

    def test_install_survives_removing_download_and_keeps_stable_controls(self):
        source = Path(self.directory.name) / "download"
        for name in (*updates.RUNTIME_FILES, "tools/macos-update-public-key.pem", "tools/macos_updates.py", "tools/macos_maintenance.py"):
            output = source / name
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(maintenance.SOURCE / name, output)
        python = self.base / ".venv/bin/python3"
        with patch.object(maintenance, "ensure_python", return_value=python):
            runtime = maintenance.install(source)
        shutil.rmtree(source)
        self.assertEqual(updates.active_runtime(self.base), runtime)
        self.assertTrue((runtime / "src/client-adapter.js").is_file())
        for name, action in maintenance.ENTRYPOINTS.items():
            script = self.base / name
            self.assertEqual(script.stat().st_mode & 0o777, 0o700)
            self.assertEqual(shlex.split(script.read_text().splitlines()[1]),
                             ["exec", str(python), "-B", str(self.base / "macos_maintenance.py"), action, "$@"])
            self.assertNotIn(str(source), script.read_text())
        for folder in (runtime, runtime / "src", runtime / "tools"):
            folder.chmod(0o700)

    def test_disabled_callback_does_not_inspect_runtime_or_download(self):
        with patch.object(updates, "active_runtime") as active, patch.object(maintenance.subprocess, "run") as run, redirect_stdout(StringIO()):
            self.assertEqual(maintenance.dispatch("on-open"), 0)
        active.assert_not_called()
        run.assert_not_called()

    def test_update_runs_after_activation_and_preserves_selected_runtime(self):
        enabled = self.enable()
        self.installed()
        events = []
        receipt = {"token": enabled["token"], "instance": "123", "installed": True, "error": None}
        def run(command, **kwargs):
            events.append("activation")
            self.assertEqual(command[:3], [str(self.base / ".venv/bin/python3"), "-B", str(self.runtime / "tools/macos_launcher.py")])
            (self.base / "last-run.json").write_text(json.dumps({**receipt, "instance": None}))
            return subprocess.CompletedProcess(command, 0, json.dumps({"installed": True, "_activationReceipt": receipt}), "")
        def maintain(runtime, state, activation):
            events.append("update")
            self.assertEqual(runtime, self.runtime)
            self.assertEqual(state, enabled)
            self.assertEqual(activation, receipt)
        with patch.object(updates, "active_runtime", return_value=self.runtime), patch.object(maintenance.subprocess, "run", side_effect=run), patch.object(maintenance, "maintain", side_effect=maintain), redirect_stdout(StringIO()) as output:
            self.assertEqual(maintenance.dispatch("on-open"), 0)
        self.assertEqual(events, ["activation", "update"])
        self.assertEqual(json.loads(output.getvalue()), {"installed": True})

    def test_failed_callback_returns_its_receipt_without_exposing_it(self):
        enabled = self.enable()
        self.installed()
        receipt = {"token": enabled["token"], "instance": "123", "installed": False, "error": "NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE"}
        result = subprocess.CompletedProcess([], 1, json.dumps({"_activationReceipt": receipt}), "")
        with patch.object(updates, "active_runtime", return_value=self.runtime), patch.object(maintenance.subprocess, "run", return_value=result), patch.object(maintenance, "maintain") as maintain, redirect_stdout(StringIO()) as output:
            self.assertEqual(maintenance.dispatch("on-open"), 1)
        maintain.assert_called_once_with(self.runtime, enabled, receipt)
        self.assertEqual(output.getvalue(), "")

    def test_callbacks_remain_serial_until_activation_receipt_is_consumed(self):
        self.enable()
        self.installed()
        held, release, second_started = threading.Event(), threading.Event(), threading.Event()
        events = []
        def run(command, **kwargs):
            events.append("activate")
            return subprocess.CompletedProcess(command, 0, '{"installed":true}', "")
        def maintain(*args):
            events.append("maintain")
            if not held.is_set():
                held.set()
                self.assertTrue(release.wait(3))
        def second_callback():
            second_started.set()
            return maintenance.dispatch("on-open")
        with patch.object(updates, "active_runtime", return_value=self.runtime), patch.object(maintenance.subprocess, "run", side_effect=run), patch.object(maintenance, "maintain", side_effect=maintain), redirect_stdout(StringIO()), ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(maintenance.dispatch, "on-open")
            try:
                self.assertTrue(held.wait(2))
                second = executor.submit(second_callback)
                self.assertTrue(second_started.wait(2))
                with self.assertRaises(TimeoutError):
                    second.result(timeout=.1)
                self.assertEqual(events, ["activate", "maintain"])
            finally:
                release.set()
            self.assertEqual(first.result(timeout=2), 0)
            self.assertEqual(second.result(timeout=2), 0)
        self.assertEqual(events, ["activate", "maintain", "activate", "maintain"])

    def test_stop_and_setup_do_not_wait_for_callback_lock(self):
        self.installed()
        with patch.object(updates, "active_runtime", return_value=self.runtime), patch.object(maintenance, "install", return_value=self.runtime), patch.object(maintenance.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), redirect_stdout(StringIO()), ThreadPoolExecutor(max_workers=1) as executor:
            for action in ("disable", "setup"):
                with self.subTest(action=action):
                    self.enable()
                    with maintenance.operation("callback.lock"):
                        self.assertEqual(executor.submit(maintenance.dispatch, action).result(timeout=2), 0)
                    if action == "disable":
                        self.assertIsNone(maintenance.settings())

    def test_duplicate_callback_cannot_hide_success_or_reset_a_later_failure(self):
        runtime = updates.install_local(maintenance.SOURCE, self.base)
        enabled = self.enable()
        failed = {"token": enabled["token"], "installed": False, "error": "NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE"}
        for instance in ("1", "2"):
            updates.record_activation(self.base, runtime, {**failed, "instance": instance})
        success, duplicate, failure = {}, {}, {}
        with patch.object(launcher, "ROOT", runtime), patch.object(launcher, "AUTOMATION_DIR", self.base), patch.object(launcher, "find_port", return_value=49321), patch.object(launcher.importlib, "import_module"), patch.object(updates, "check_update"):
            with patch.object(launcher, "value", side_effect=["3", {"installed": False}]), patch.object(launcher, "install_patch", return_value={"installed": True}):
                launcher.on_open(receipt=success)
            # A queued duplicate finishes before the first controller consumes its result.
            with patch.object(launcher, "value", side_effect=["3", {"installed": True}]):
                launcher.on_open(receipt=duplicate)
            self.assertIsNone(json.loads((self.base / "last-run.json").read_text())["instance"])
            maintenance.maintain(runtime, enabled, success)
            maintenance.maintain(runtime, enabled, duplicate)
            self.assertEqual(updates.status(self.base)["failureCount"], 0)
            with patch.object(launcher, "value", side_effect=["4", {"installed": False}]), patch.object(launcher, "install_patch", side_effect=RuntimeError(failed["error"])):
                with self.assertRaisesRegex(RuntimeError, failed["error"]):
                    launcher.on_open(receipt=failure)
            maintenance.maintain(runtime, enabled, failure)
            maintenance.maintain(runtime, enabled, failure)
            maintenance.maintain(runtime, enabled, duplicate)
            maintenance.maintain(self.runtime, enabled, success)
            maintenance.maintain(runtime, enabled, {**success, "token": "b" * 32})
            self.assertEqual(updates.status(self.base)["failureCount"], 1)
        for folder in (runtime, runtime / "src", runtime / "tools"):
            folder.chmod(0o700)

    def test_stop_revokes_before_lock_and_retains_custom_client_path(self):
        self.enable()
        self.installed()
        @contextmanager
        def lock():
            self.assertFalse((self.base / "enabled.json").exists())
            self.assertFalse((self.base / "on-open.command").exists())
            self.enable()  # An enable finished while Stop was waiting.
            latest = maintenance.settings()
            latest["clientPath"] = "/Apps/New Music.app"
            maintenance.atomic_write(self.base / "enabled.json", json.dumps(latest).encode())
            yield
        def run(command, **kwargs):
            self.assertFalse((self.base / "enabled.json").exists())
            self.assertEqual(command[-2:], ["--fallback-client-path", "/Apps/New Music.app"])
            return subprocess.CompletedProcess(command, 0, '{"installed":false}\n', "")
        with patch.object(maintenance, "operation", lock), patch.object(updates, "active_runtime", return_value=self.runtime), patch.object(maintenance.subprocess, "run", side_effect=run), patch.object(maintenance, "maintain") as maintain, redirect_stdout(StringIO()):
            self.assertEqual(maintenance.dispatch("disable"), 0)
        maintain.assert_not_called()

    def test_stop_revokes_even_when_runtime_is_damaged(self):
        self.enable()
        self.installed()
        with patch.object(updates, "active_runtime", side_effect=RuntimeError("NCM_UPDATE_RUNTIME_INVALID")):
            with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_RUNTIME_INVALID"):
                maintenance.dispatch("disable")
        self.assertIsNone(maintenance.settings())
        self.assertFalse((self.base / "on-open.command").exists())

    def test_stop_during_maintenance_prevents_update(self):
        enabled = self.enable()
        receipt = {"token": enabled["token"], "instance": "123", "installed": True, "error": None}
        with patch.object(updates, "record_activation", side_effect=lambda *args: maintenance.revoke()), patch.object(updates, "check_update") as update:
            maintenance.maintain(self.runtime, enabled, receipt)
        update.assert_not_called()

    def test_status_exposes_update_error_without_starting_update(self):
        self.installed()
        with patch.object(updates, "active_runtime", return_value=self.runtime), patch.object(updates, "status", return_value={"error": "NCM_UPDATE_DOWNLOAD_FAILED"}), patch.object(maintenance.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"installed":false}', "")), patch.object(updates, "check_update") as update, redirect_stdout(StringIO()) as output:
            self.assertEqual(maintenance.dispatch("status"), 0)
        self.assertEqual(json.loads(output.getvalue())["maintenance"]["error"], "NCM_UPDATE_DOWNLOAD_FAILED")
        update.assert_not_called()

    def test_dependencies_are_created_in_fixed_location_and_reused(self):
        with patch.object(maintenance.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            python = maintenance.ensure_python(maintenance.SOURCE)
        self.assertEqual(python, self.base / ".venv/bin/python3")
        self.assertEqual(run.call_args_list[0].args[0][-1], str(self.base / ".venv"))
        self.assertEqual(run.call_count, 2)
        python.parent.mkdir(parents=True)
        python.touch()
        with patch.object(maintenance.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            maintenance.ensure_python(maintenance.SOURCE)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][-1], "import websocket")

    def test_stop_during_installation_cancels_before_launching_setup(self):
        def install(source, check):
            maintenance.revoke()
            check()
        with patch.object(maintenance, "install", side_effect=install), patch.object(maintenance.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_SETUP_CANCELLED"):
                maintenance.dispatch("setup")
        run.assert_not_called()

    def test_package_is_verified_before_dependencies_are_prepared(self):
        with patch.object(updates, "install_local", side_effect=RuntimeError("NCM_UPDATE_SIGNATURE_INVALID")), patch.object(maintenance, "ensure_python") as prepare:
            with self.assertRaisesRegex(RuntimeError, "NCM_UPDATE_SIGNATURE_INVALID"):
                maintenance.install(maintenance.SOURCE)
        prepare.assert_not_called()

    def test_source_upgrade_retains_custom_client_and_never_clears_newer_setup(self):
        self.enable()
        def run(command, **kwargs):
            self.assertEqual(command[-2:], ["--client-path", "/Apps/Music With Spaces.app"])
            self.assertIn("--request-token", command)
            (self.base / "setup-request").write_text("b" * 32)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(maintenance, "install", return_value=self.runtime), patch.object(maintenance.subprocess, "run", side_effect=run):
            self.assertEqual(maintenance.dispatch("setup"), 0)
        self.assertEqual((self.base / "setup-request").read_text(), "b" * 32)


if __name__ == "__main__":
    unittest.main()
