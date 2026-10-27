"""No client, account, network, or audio required."""
from io import BytesIO
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import cdp_probe
import macos_launcher as launcher


class MacLauncherTests(unittest.TestCase):
    def test_discovery_checks_bundle_identity_and_version(self):
        with TemporaryDirectory() as directory:
            app = Path(directory) / "Music With Spaces.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/NeteaseMusic").touch()
            info = {"CFBundleIdentifier": "com.netease.163music", "CFBundleExecutable": "NeteaseMusic",
                    "CFBundleShortVersionString": "3.1.12", "CFBundleVersion": "3444"}
            path = app / "Contents/Info.plist"
            path.write_bytes(plistlib.dumps(info))
            self.assertEqual(launcher.find_client(app), app.resolve())
            info["CFBundleVersion"] = "9999"
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, "CLIENT_VERSION_UNVERIFIED"):
                launcher.find_client(app)
            info["CFBundleIdentifier"] = "another.app"
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, "NCM_INSTALLATION_NOT_UNIQUE"):
                launcher.find_client(app)

    @patch.object(launcher.subprocess, "run")
    def test_process_discovery_keeps_spaces_and_ignores_helpers(self, run):
        command = "/Applications/Music With Spaces.app/Contents/MacOS/NeteaseMusic --remote-debugging-port=49321"
        run.side_effect = [subprocess.CompletedProcess([], 0, "123\n"),
                           subprocess.CompletedProcess([], 0, command + "\n")]
        self.assertEqual(launcher.running_commands(), [command])
        self.assertEqual(run.call_args_list[0].args[0], ["/usr/bin/pgrep", "-x", "NeteaseMusic"])
        self.assertIn("-ww", run.call_args.args[0])

    @patch.object(launcher, "get_page", return_value="ws://127.0.0.1:49321/devtools/page/test")
    @patch.object(launcher, "running_commands")
    @patch.object(launcher, "find_client", return_value=Path("/Applications/Music With Spaces.app"))
    def test_reuses_existing_port_without_launching(self, find, processes, page):
        processes.return_value = ["/Applications/Music With Spaces.app/Contents/MacOS/NeteaseMusic --remote-debugging-port=49321"]
        self.assertEqual(launcher.find_port(launch=True), 49321)
        page.assert_called_once_with(49321)

    @patch.object(launcher, "running_commands", return_value=["/Applications/NeteaseMusic.app/Contents/MacOS/NeteaseMusic"])
    @patch.object(launcher, "find_client", return_value=Path("/Applications/NeteaseMusic.app"))
    @patch.object(launcher.subprocess, "run")
    def test_does_not_restart_a_running_client(self, run, find, processes):
        with self.assertRaisesRegex(RuntimeError, "NCM_EXIT_AND_RESTART_WITH_LAUNCHER"):
            launcher.find_port(launch=True)
        run.assert_not_called()

    @patch.object(launcher, "get_page", return_value="ws://127.0.0.1:49321/devtools/page/test")
    @patch.object(launcher, "available_port", return_value=49321)
    @patch.object(launcher, "running_commands", return_value=[])
    @patch.object(launcher, "find_client", return_value=Path("/Applications/Music With Spaces.app"))
    @patch.object(launcher.subprocess, "run")
    def test_cold_launch_uses_an_argument_list_and_loopback(self, run, find, processes, port, page):
        self.assertEqual(launcher.find_port(launch=True), 49321)
        run.assert_called_once_with(["/usr/bin/open", "-a", "/Applications/Music With Spaces.app", "--args",
                                    "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=49321"],
                                   check=True, capture_output=True, timeout=10)


class RuntimeTests(unittest.TestCase):
    @patch.object(launcher.importlib, "import_module")
    @patch.object(launcher.subprocess, "run")
    @patch.object(launcher.os, "execv")
    def test_installed_dependency_needs_no_setup(self, execute, run, imported):
        launcher.ensure_runtime()
        run.assert_not_called()
        execute.assert_not_called()

    @patch.object(launcher.importlib, "import_module", side_effect=ImportError)
    @patch.object(launcher.subprocess, "run")
    @patch.object(launcher.os, "execv")
    def test_fresh_package_creates_local_environment_and_reexecutes(self, execute, run, imported):
        with TemporaryDirectory(prefix="ncm package ") as directory, patch.object(launcher, "ROOT", Path(directory)):
            with patch.object(launcher.sys, "argv", ["macos_launcher.py", "status", "--client-path", "/Apps/Music With Spaces.app"]):
                launcher.ensure_runtime()
            python = str(Path(directory) / ".venv/bin/python3")
            self.assertEqual(run.call_args_list[0].args[0], [sys.executable, "-m", "venv", str(Path(directory) / ".venv")])
            self.assertEqual(run.call_args_list[1].args[0], [python, "-m", "pip", "install", "--disable-pip-version-check",
                                                          "-r", str(Path(directory) / "requirements-macos.txt")])
            self.assertEqual(run.call_args_list[2].args[0], [python, "-c", "import websocket"])
            self.assertEqual(execute.call_args.args[0], python)
            self.assertEqual(execute.call_args.args[1][2:], ["status", "--client-path", "/Apps/Music With Spaces.app"])

    @patch.object(launcher.importlib, "import_module", side_effect=ImportError)
    @patch.object(launcher.subprocess, "run")
    @patch.object(launcher.os, "execv")
    def test_wrong_python_reuses_existing_environment(self, execute, run, imported):
        with TemporaryDirectory() as directory, patch.object(launcher, "ROOT", Path(directory)):
            python = Path(directory) / ".venv/bin/python3"
            python.parent.mkdir(parents=True)
            python.touch()
            launcher.ensure_runtime()
            run.assert_not_called()
            self.assertEqual(execute.call_args.args[0], str(python))

    @patch.object(launcher.importlib, "import_module", side_effect=ImportError)
    @patch.object(launcher.subprocess, "run")
    @patch.object(launcher.os, "execv")
    def test_incomplete_environment_installs_without_recreating_it(self, execute, run, imported):
        with TemporaryDirectory() as directory, patch.object(launcher, "ROOT", Path(directory)):
            environment = Path(directory) / ".venv"
            python = environment / "bin/python3"
            python.parent.mkdir(parents=True)
            python.touch()
            with patch.object(launcher.sys, "prefix", str(environment)):
                launcher.ensure_runtime()
            self.assertEqual(len(run.call_args_list), 2)
            self.assertEqual(run.call_args_list[0].args[0][1:4], ["-m", "pip", "install"])
            execute.assert_called_once()

    @patch.object(launcher.importlib, "import_module", side_effect=ImportError)
    @patch.object(launcher.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "setup"))
    @patch.object(launcher.os, "execv")
    def test_failed_setup_does_not_launch_or_loop(self, execute, run, imported):
        with TemporaryDirectory() as directory, patch.object(launcher, "ROOT", Path(directory)):
            with self.assertRaisesRegex(RuntimeError, "NCM_DEPENDENCY_SETUP_FAILED"):
                launcher.ensure_runtime()
            execute.assert_not_called()


class CdpPageTests(unittest.TestCase):
    def read_page(self, pages):
        with patch.object(cdp_probe, "build_opener") as opener:
            opener.return_value.open.return_value.__enter__.return_value = BytesIO(json.dumps(pages).encode())
            return cdp_probe.get_page(49321)

    def page(self, url="orpheus://orpheus/app.html", endpoint="ws://127.0.0.1:49321/devtools/page/test"):
        return {"type": "page", "url": url, "webSocketDebuggerUrl": endpoint}

    def test_accepts_only_the_two_known_main_pages(self):
        for url in cdp_probe.PAGE_URLS:
            self.assertEqual(self.read_page([self.page(url)]), "ws://127.0.0.1:49321/devtools/page/test")
        for pages in ([], [self.page(), self.page()], [self.page("https://example.com")], [{**self.page(), "type": "iframe"}]):
            with self.assertRaisesRegex(RuntimeError, "NCM_PAGE_NOT_UNIQUE"):
                self.read_page(pages)

    def test_rejects_remote_or_different_port_websockets(self):
        for endpoint in ("ws://example.com:49321/devtools/page/a", "ws://127.0.0.1:9222/devtools/page/a",
                         "wss://127.0.0.1:49321/devtools/page/a", "ws://user@127.0.0.1:49321/devtools/page/a",
                         "ws://127.0.0.1:49321/other", None):
            with self.subTest(endpoint=endpoint), self.assertRaisesRegex(RuntimeError, "NCM_ENDPOINT_NOT_LOOPBACK"):
                self.read_page([self.page(endpoint=endpoint)])

    def test_rejects_invalid_page_lists_and_ports(self):
        for pages in ({"error": "other service"}, [None]):
            with self.assertRaisesRegex(RuntimeError, "NCM_PAGE_LIST_INVALID"):
                self.read_page(pages)
        for port in (0, 65536, -1):
            with self.assertRaisesRegex(RuntimeError, "NCM_PORT_INVALID"):
                cdp_probe.get_page(port)


if __name__ == "__main__":
    unittest.main()
