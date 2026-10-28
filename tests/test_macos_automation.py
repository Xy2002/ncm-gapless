"""One-shot automation, cancellation and local import; never launches a client."""
from concurrent.futures import ThreadPoolExecutor
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
from unittest.mock import ANY, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos_launcher as launcher


@unittest.skipIf(sys.platform == "win32", "macOS automation uses POSIX file locks")
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

    def run_main(self, action, *arguments):
        with patch.object(sys, "argv", ["macos_launcher.py", action, *arguments]), patch.object(sys, "platform", "darwin"), redirect_stdout(StringIO()) as output:
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

    def test_stop_revokes_enablement_written_while_waiting_for_lock(self):
        waiting = threading.Event()
        operation = launcher.operation

        def wait_for_lock():
            waiting.set()
            return operation()

        with patch.object(launcher, "operation", side_effect=wait_for_lock), patch.object(launcher, "find_port", return_value=49321) as find, patch.object(launcher, "ensure_runtime"), patch.object(launcher, "uninstall_patch", return_value={"installed": False}), patch.object(launcher, "shortcut_installed", return_value=True):
            with ThreadPoolExecutor(max_workers=1) as executor:
                with operation():
                    stopped = executor.submit(self.run_main, "disable")
                    self.assertTrue(waiting.wait(2))
                    self.enable()
                    (self.folder / "on-open.command").touch()
                report = stopped.result(timeout=2)
            self.assertFalse(report["installed"])
            self.assertFalse(report["automaticEnabled"])
            self.assertIsNone(launcher.automation_settings())
            self.assertFalse((self.folder / "on-open.command").exists())
            find.assert_called_once_with(launch=False, client_path=self.app)
            self.assertEqual(launcher.on_open(), {"automaticEnabled": False})

    def test_stop_uses_saved_client_before_removing_configuration(self):
        self.enable()
        with patch.object(launcher, "find_port", return_value=49321) as find, patch.object(launcher, "ensure_runtime"), patch.object(launcher, "uninstall_patch", return_value={"installed": False}):
            self.assertFalse(self.run_main("disable")["automaticEnabled"])
            find.assert_called_once_with(launch=False, client_path=self.app)

    def test_stop_keeps_saved_client_path_after_runtime_reexecution(self):
        self.app = self.folder / "Custom Apps/Music With Spaces.app"
        python = self.folder / ".venv/bin/python3"
        python.parent.mkdir(parents=True)
        python.touch()

        def find_port(*, launch, client_path):
            self.assertEqual(client_path, self.app)
            return 49321

        with patch.object(launcher, "ROOT", self.folder), patch.object(launcher, "find_port", side_effect=find_port) as find, patch.object(launcher.subprocess, "run") as run, patch.object(launcher.os, "execv", side_effect=SystemExit) as execute, patch.object(launcher, "uninstall_patch", return_value={"installed": False}) as uninstall:
            self.enable()
            with patch.object(launcher.importlib, "import_module", side_effect=ImportError):
                with self.assertRaises(SystemExit):
                    self.run_main("disable")
            self.assertIsNone(launcher.automation_settings())
            uninstall.assert_not_called()
            run.assert_not_called()
            self.assertEqual(execute.call_args.args[0], str(python))
            with patch.object(launcher.importlib, "import_module"):
                report = self.run_main(*execute.call_args.args[1][2:])
            self.assertFalse(report["installed"])
            self.assertFalse(report["automaticEnabled"])
            self.assertEqual(find.call_count, 2)
            uninstall.assert_called_once_with(49321)

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

    def test_setup_verifies_real_launch_after_releasing_operation_lock(self):
        settings = self.enable()
        def launched(*args, **kwargs):
            with launcher.operation(wait=False) as acquired:
                self.assertTrue(acquired)
                launcher.atomic_write(self.folder / "last-run.json", json.dumps({
                    "token": settings["token"], "installed": True, "error": None,
                }).encode())
        with patch.object(launcher, "running_commands", return_value=[self.command]), patch.object(launcher, "quit_client") as quit_client, patch.object(launcher.subprocess, "run", side_effect=launched) as run, patch.object(launcher, "find_port", return_value=49321), patch.object(launcher, "value", return_value={"installed": True}):
            self.assertEqual(launcher.verify_automatic(settings, self.app), {"port": 49321, "installed": True})
            quit_client.assert_called_once_with(self.app, check=ANY)
            run.assert_called_once_with(["/usr/bin/open", "-a", str(self.app)], check=True, capture_output=True, timeout=10)

    def test_setup_rejects_a_stale_success_record(self):
        settings = self.enable()
        launcher.atomic_write(self.folder / "last-run.json", json.dumps({"token": settings["token"], "installed": True}).encode())
        with patch.object(launcher, "running_commands", return_value=[]), patch.object(launcher.subprocess, "run"), patch.object(launcher.time, "monotonic", side_effect=[0, 1, 46]), patch.object(launcher.time, "sleep"), patch.object(launcher, "find_port", return_value=49321), patch.object(launcher, "value", return_value={"installed": True}):
            with self.assertRaisesRegex(RuntimeError, "NCM_SETUP_NOT_READY"):
                launcher.verify_automatic(settings, self.app)

    def test_existing_setup_skips_questions_and_reports_the_new_port(self):
        self.enable()
        with patch.object(launcher, "enable_automatic", return_value={"shortcutImported": True, "port": 9222}), patch.object(launcher, "verify_automatic", return_value={"port": 49321, "installed": True}), patch.object(launcher, "prompt_configuration") as prompt:
            report = launcher.setup_automatic(self.app)
            self.assertTrue(report["setupVerified"])
            self.assertEqual(report["port"], 49321)
            prompt.assert_not_called()

    def test_enable_failure_reverts_memory_installation(self):
        with patch.object(launcher, "find_port", return_value=49321), patch.object(launcher, "value", return_value={"installed": True}), patch.object(launcher, "prepare_shortcut", side_effect=RuntimeError("NCM_AUTOMATION_IMPORT_FAILED")), patch.object(launcher, "uninstall_patch") as uninstall:
            with self.assertRaisesRegex(RuntimeError, "NCM_AUTOMATION_IMPORT_FAILED"):
                launcher.enable_automatic(self.app)
            uninstall.assert_called_once_with(49321)
        self.assertIsNone(launcher.automation_settings())

    def test_fresh_setup_waits_for_import_then_verifies(self):
        self.enable()
        terminal = Mock()
        terminal.isatty.return_value = True
        with patch.object(launcher.sys, "stdin", terminal), patch.object(launcher, "enable_automatic", return_value={"shortcutImported": False}), patch.object(launcher, "shortcut_installed", side_effect=[False, True]), patch.object(launcher.time, "sleep"), patch.object(launcher, "prompt_configuration") as prompt, patch.object(launcher, "verify_automatic", return_value={"installed": True}) as verify:
            self.assertTrue(launcher.setup_automatic(self.app)["setupVerified"])
            prompt.assert_called_once()
            verify.assert_called_once()

    def test_setup_cancellation_rolls_back_without_verifying(self):
        settings = self.enable()
        terminal = Mock()
        terminal.isatty.return_value = True
        with patch.object(launcher.sys, "stdin", terminal), patch.object(launcher, "enable_automatic", return_value={"shortcutImported": False}), patch.object(launcher, "shortcut_installed", return_value=True), patch.object(launcher, "prompt_configuration", side_effect=RuntimeError("NCM_SETUP_CANCELLED")), patch.object(launcher, "verify_automatic") as verify, patch.object(launcher, "rollback_setup") as rollback:
            with self.assertRaisesRegex(RuntimeError, "NCM_SETUP_CANCELLED"):
                launcher.setup_automatic(self.app)
            verify.assert_not_called()
            rollback.assert_called_once_with(settings)

    def test_setup_keyboard_interrupt_also_rolls_back(self):
        settings = self.enable()
        with patch.object(launcher, "enable_automatic", return_value={"shortcutImported": True}), patch.object(launcher, "verify_automatic", side_effect=KeyboardInterrupt), patch.object(launcher, "rollback_setup") as rollback:
            with self.assertRaises(KeyboardInterrupt):
                launcher.setup_automatic(self.app)
            rollback.assert_called_once_with(settings)

    def test_setup_retries_only_after_confirmation_and_stops_after_three_attempts(self):
        self.enable()
        with patch.object(launcher, "enable_automatic", return_value={"shortcutImported": True}), patch.object(launcher, "verify_automatic", side_effect=RuntimeError("NCM_SETUP_NOT_READY")) as verify, patch.object(launcher, "prompt_configuration") as prompt, patch.object(launcher, "rollback_setup") as rollback:
            with self.assertRaisesRegex(RuntimeError, "NCM_SETUP_NOT_READY"):
                launcher.setup_automatic(self.app)
            self.assertEqual(verify.call_count, 3)
            self.assertEqual(prompt.call_count, 2)
            rollback.assert_called_once()

    def test_setup_rollback_uninstalls_only_its_own_session(self):
        settings = self.enable()
        (self.folder / "on-open.command").touch()
        with patch.object(launcher, "find_port", return_value=49321), patch.object(launcher, "uninstall_patch") as uninstall:
            launcher.rollback_setup(settings)
            uninstall.assert_called_once_with(49321)
        self.assertIsNone(launcher.automation_settings())
        self.assertFalse((self.folder / "on-open.command").exists())

    def test_setup_rollback_preserves_a_newer_enable_request(self):
        settings = self.enable()
        newer = {**settings, "token": "b" * 32}
        launcher.atomic_write(self.folder / "enabled.json", json.dumps(newer).encode())
        with patch.object(launcher, "uninstall_patch") as uninstall:
            launcher.rollback_setup(settings)
            uninstall.assert_not_called()
        self.assertEqual(launcher.automation_settings(), newer)

    def test_setup_confirmation_can_cancel_without_changing_system_preferences(self):
        terminal = Mock()
        terminal.isatty.return_value = True
        terminal.readline.return_value = "q\n"
        with patch.object(launcher.sys, "stdin", terminal), patch.object(launcher.select, "select", return_value=([terminal], [], [])), patch.object(launcher.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_SETUP_CANCELLED"):
                launcher.prompt_configuration()
            run.assert_called_once_with(["/usr/bin/shortcuts", "view", launcher.SHORTCUT_NAME], check=True, capture_output=True, timeout=15)

    def test_setup_without_a_terminal_does_not_attempt_ui_control(self):
        terminal = Mock()
        terminal.isatty.return_value = False
        with patch.object(launcher.sys, "stdin", terminal), patch.object(launcher.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "NCM_SETUP_REQUIRES_TERMINAL"):
                launcher.prompt_configuration()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
