"""One-shot automation, cancellation and local import; never launches a client."""
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading
import time
import unittest
from unittest.mock import ANY, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos_launcher as launcher


class AutomationTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory(prefix="ncm automation ")
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.app = Path("/Applications/Music With Spaces.app")
        self.command = str(self.app / "Contents/MacOS/NeteaseMusic")
        for name, value in (("AUTOMATION_DIR", self.folder),):
            mocked = patch.object(launcher, name, value)
            mocked.start()
            self.addCleanup(mocked.stop)

    def enable(self):
        settings = {"root": str(launcher.ROOT), "clientPath": str(self.app), "token": "a" * 32}
        launcher.atomic_write(self.folder / "enabled.json", json.dumps(settings).encode())
        return settings

    def run_main(self, action):
        with patch.object(sys, "argv", ["macos_launcher.py", action]), patch.object(sys, "platform", "darwin"), redirect_stdout(StringIO()) as output:
            launcher.main()
        return json.loads(output.getvalue())

    def test_disabled_event_does_not_inspect_or_launch(self):
        with patch.object(launcher, "find_port") as find:
            self.assertEqual(launcher.on_open(), {"automaticEnabled": False})
            find.assert_not_called()

    def test_closed_client_is_not_opened(self):
        self.enable()
        with patch.object(launcher, "find_port", side_effect=RuntimeError("NCM_NOT_RUNNING")) as find, patch.object(launcher.importlib, "import_module"), patch.object(launcher, "install_patch") as install:
            self.assertEqual(launcher.on_open(), {"installed": False})
            find.assert_called_once_with(client_path=str(self.app), restart=True, check=ANY)
            install.assert_not_called()

    def test_existing_patch_is_not_reinjected(self):
        self.enable()
        with patch.object(launcher, "find_port", return_value=49321), patch.object(launcher.importlib, "import_module"), patch.object(launcher, "value", return_value={"installed": True}), patch.object(launcher, "install_patch") as install:
            self.assertTrue(launcher.on_open()["installed"])
            install.assert_not_called()
        last = json.loads((self.folder / "last-run.json").read_text())
        self.assertTrue(last["installed"])
        self.assertIsNone(last["error"])

    def test_unknown_version_fails_closed_and_records_only_code(self):
        self.enable()
        with patch.object(launcher, "find_client", side_effect=RuntimeError("CLIENT_VERSION_UNVERIFIED")), patch.object(launcher.importlib, "import_module"), patch.object(launcher.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "CLIENT_VERSION_UNVERIFIED"):
                launcher.on_open()
            run.assert_not_called()
        self.assertEqual(json.loads((self.folder / "last-run.json").read_text())["error"], "CLIENT_VERSION_UNVERIFIED")

    def test_native_start_restarts_once_using_loopback(self):
        with patch.object(launcher, "find_client", return_value=self.app), patch.object(launcher, "running_commands", return_value=[self.command]), patch.object(launcher, "quit_client") as quit_client, patch.object(launcher, "available_port", return_value=49321), patch.object(launcher, "get_page", return_value="ready"), patch.object(launcher.subprocess, "run") as run:
            self.assertEqual(launcher.find_port(restart=True), 49321)
            quit_client.assert_called_once_with(self.app, check=None)
            run.assert_called_once_with(["/usr/bin/open", "-a", str(self.app), "--args", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=49321"], check=True, capture_output=True, timeout=10)

    def test_existing_debug_port_waits_without_restart(self):
        command = self.command + " --remote-debugging-port=49321"
        with patch.object(launcher, "find_client", return_value=self.app), patch.object(launcher, "running_commands", return_value=[command]), patch.object(launcher, "get_page", side_effect=[OSError(), "ready"]), patch.object(launcher.time, "sleep"), patch.object(launcher, "quit_client") as quit_client, patch.object(launcher.subprocess, "run") as run:
            self.assertEqual(launcher.find_port(restart=True), 49321)
            quit_client.assert_not_called()
            run.assert_not_called()

    def test_quitting_during_debug_startup_does_not_reopen(self):
        command = self.command + " --remote-debugging-port=49321"
        with patch.object(launcher, "find_client", return_value=self.app), patch.object(launcher, "running_commands", side_effect=[[command], []]), patch.object(launcher, "get_page", side_effect=OSError()), patch.object(launcher.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_NOT_RUNNING"):
                launcher.find_port(restart=True)
            run.assert_not_called()

    def test_stop_after_normal_quit_cancels_relaunch(self):
        settings = self.enable()
        with patch.object(launcher, "find_client", return_value=self.app), patch.object(launcher, "running_commands", return_value=[self.command]), patch.object(launcher, "quit_client", side_effect=lambda *args, **kwargs: (self.folder / "enabled.json").unlink()), patch.object(launcher.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_AUTO_ENABLE_CANCELLED"):
                launcher.find_port(restart=True, check=lambda: launcher.check_automation(settings))
            run.assert_not_called()

    def test_cancelled_installation_never_evaluates_patch(self):
        def cancelled():
            raise RuntimeError("NCM_AUTO_ENABLE_CANCELLED")
        with patch.object(launcher, "value") as value:
            with self.assertRaisesRegex(RuntimeError, "NCM_AUTO_ENABLE_CANCELLED"):
                launcher.install_patch(49321, check=cancelled)
            value.assert_not_called()

    def test_refused_normal_quit_does_not_force_termination(self):
        with patch.object(launcher.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "osascript")) as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_CLIENT_QUIT_FAILED"):
                launcher.quit_client(self.app)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][0], "/usr/bin/osascript")

    def test_missing_process_at_quit_is_not_a_relaunch_request(self):
        with patch.object(launcher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "false\n")):
            with self.assertRaisesRegex(RuntimeError, "NCM_NOT_RUNNING"):
                launcher.quit_client(self.app)

    def test_foreign_process_cannot_be_restarted(self):
        with patch.object(launcher, "find_client", return_value=self.app), patch.object(launcher, "running_commands", return_value=[self.command + "-foreign --remote-debugging-port=49321"]), patch.object(launcher, "quit_client") as quit_client:
            with self.assertRaisesRegex(RuntimeError, "NCM_OTHER_CLIENT_RUNNING"):
                launcher.find_port(restart=True)
            quit_client.assert_not_called()

    def test_stop_clears_state_before_waiting_and_needs_no_runtime_if_closed(self):
        self.enable()
        result = []
        with patch.object(launcher, "find_port", side_effect=RuntimeError("NCM_NOT_RUNNING")), patch.object(launcher, "running_commands", return_value=[]), patch.object(launcher, "ensure_runtime") as runtime:
            with launcher.operation():
                thread = threading.Thread(target=lambda: result.append(self.run_main("disable")))
                thread.start()
                deadline = time.monotonic() + 2
                while (self.folder / "enabled.json").exists() and time.monotonic() < deadline:
                    threading.Event().wait(.01)
                self.assertFalse((self.folder / "enabled.json").exists())
                self.assertTrue(thread.is_alive())
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertFalse(result[0]["automaticEnabled"])
            runtime.assert_not_called()

    def test_duplicate_event_does_no_work(self):
        self.enable()
        with launcher.operation(), patch.object(launcher, "find_port") as find:
            self.assertEqual(launcher.on_open(), {"busy": True})
            find.assert_not_called()

    def test_stop_uses_saved_client_before_removing_configuration(self):
        self.enable()
        with patch.object(launcher, "find_port", return_value=49321) as find, patch.object(launcher, "ensure_runtime"), patch.object(launcher, "uninstall_patch", return_value={"installed": False}):
            self.assertFalse(self.run_main("disable")["automaticEnabled"])
            find.assert_called_once_with(launch=False, client_path=self.app)

    def test_status_uses_saved_client_for_a_nonstandard_installation(self):
        self.enable()
        with patch.object(launcher, "find_port", return_value=49321) as find, patch.object(launcher, "ensure_runtime"), patch.object(launcher, "value", return_value={"installed": True}), patch.object(launcher, "shortcut_installed", return_value=True):
            self.assertTrue(self.run_main("status")["automaticEnabled"])
            find.assert_called_once_with(launch=False, client_path=self.app)

    def test_stop_revokes_corrupt_configuration(self):
        launcher.atomic_write(self.folder / "enabled.json", b"{invalid")
        (self.folder / "on-open.command").touch()
        with patch.object(launcher, "find_port", side_effect=RuntimeError("NCM_NOT_RUNNING")), patch.object(launcher, "running_commands", return_value=[]):
            self.assertFalse(self.run_main("disable")["automaticEnabled"])
        self.assertFalse((self.folder / "enabled.json").exists())
        self.assertFalse((self.folder / "on-open.command").exists())

    def test_enable_writes_a_private_quoted_entry_and_cleans_up_failed_setup(self):
        python = "/tmp/Python space's $() directory/python3"
        with patch.object(launcher.sys, "executable", python), patch.object(launcher, "find_port", return_value=49321), patch.object(launcher, "value", return_value={"installed": True}), patch.object(launcher, "prepare_shortcut", return_value=True):
            self.assertTrue(launcher.enable_automatic(self.app)["automaticEnabled"])
        entry = self.folder / "on-open.command"
        self.assertEqual(entry.stat().st_mode & 0o777, 0o700)
        self.assertEqual(shlex.split(entry.read_text().splitlines()[1]), ["exec", python, str(Path(launcher.__file__).resolve()), "on-open"])
        self.assertEqual((self.folder / "enabled.json").stat().st_mode & 0o777, 0o600)
        with patch.object(launcher, "find_port", side_effect=RuntimeError("CLIENT_VERSION_UNVERIFIED")):
            with self.assertRaisesRegex(RuntimeError, "CLIENT_VERSION_UNVERIFIED"):
                launcher.enable_automatic(self.app)
        self.assertIsNone(launcher.automation_settings())
        self.assertFalse(entry.exists())

    def test_local_import_uses_generic_targeted_template_and_official_signer(self):
        settings = self.enable()
        with patch.object(launcher, "shortcut_installed", return_value=False), patch.object(launcher.subprocess, "run") as run:
            self.assertFalse(launcher.prepare_shortcut(settings))
        workflow = plistlib.loads((self.folder / "automation-unsigned.shortcut").read_bytes())
        app = workflow["WFWorkflowTriggers"][0]["WFTriggerSerializedParameters"]["WFSelectedApps"]
        self.assertEqual(app["BundleIdentifier"], "com.netease.163music")
        self.assertEqual(app["TeamIdentifier"], "43B53CMF9D")
        self.assertEqual(len(workflow["WFWorkflowActions"]), 1)
        source = workflow["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["Script"]
        self.assertIn("$HOME/Library/Application Support/NcmGapless/on-open.command", source)
        self.assertNotIn(str(Path.home()), source)
        self.assertEqual(run.call_args_list[0].args[0][:4], ["/usr/bin/shortcuts", "sign", "--mode", "anyone"])
        self.assertEqual(Path(run.call_args_list[0].args[0][5]).suffix, ".shortcut")
        self.assertEqual(run.call_args_list[1].args[0][:3], ["/usr/bin/open", "-a", "/System/Applications/Shortcuts.app"])

    def test_signing_failure_does_not_open_an_unsigned_shortcut(self):
        settings = self.enable()
        with patch.object(launcher, "shortcut_installed", return_value=False), patch.object(launcher.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "sign")) as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_AUTOMATION_IMPORT_FAILED"):
                launcher.prepare_shortcut(settings)
            self.assertEqual(run.call_count, 1)

    def test_uninstall_connection_loss_is_checked_before_reporting_success(self):
        for installed in (True, False):
            with self.subTest(installed=installed), patch.object(launcher, "value", side_effect=[RuntimeError("NCM_CDP_CONNECTION_FAILED"), {"installed": installed}]):
                if installed:
                    with self.assertRaisesRegex(RuntimeError, "NCM_CDP_CONNECTION_FAILED"):
                        launcher.uninstall_patch(49321)
                else:
                    self.assertFalse(launcher.uninstall_patch(49321)["installed"])


if __name__ == "__main__":
    unittest.main()
