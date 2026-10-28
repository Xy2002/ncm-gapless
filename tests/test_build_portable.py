"""Check the two runtime packages, their checksums and Mac executable modes."""
from contextlib import redirect_stdout
import hashlib
from io import StringIO
import json
from pathlib import Path
import sys
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_portable import build, PLATFORM_FILES, VERSION, WINDOWS_STARTUP_FILES, ROOT


class PortableTests(unittest.TestCase):
    def test_maintenance_payload_cannot_be_added_to_the_other_platform(self):
        with self.assertRaisesRegex(ValueError, "macOS"):
            build("windows", include_macos_maintenance=True)
        with self.assertRaisesRegex(ValueError, "Windows"):
            build("macos", include_windows_maintenance=True)

    def test_maintenance_package_contains_signed_payload_but_no_private_key(self):
        if not (ROOT / 'artifacts/windows-maintenance/windows-update.json').is_file():
            self.skipTest('Sign the Windows payload before checking its maintenance package')
        with redirect_stdout(StringIO()):
            output = build('windows', include_windows_maintenance=True)
        with zipfile.ZipFile(output) as archive:
            names = archive.namelist()
            self.assertEqual(len(names), len(set(names)))
            self.assertIn('ncm-gapless/updates/windows-update.json', names)
            self.assertIn('ncm-gapless/updates/windows-payload.zip', names)
            self.assertIn('ncm-gapless/tools/update-public-key.xml', names)
            self.assertTrue(all('private' not in name and '.dpapi' not in name for name in names))
            manifest=json.loads(archive.read('ncm-gapless/manifest.json'))
            for name, expected in manifest['sha256'].items():
                self.assertEqual(hashlib.sha256(archive.read('ncm-gapless/'+name)).hexdigest(), expected)

    def test_windows_startup_package_contains_compiled_loader_and_complete_runtime(self):
        if not (ROOT / "native/windows/MSIMG32.dll").is_file():
            self.skipTest("Build the Windows native loader before checking its package")
        with redirect_stdout(StringIO()):
            output = build("windows", include_windows_startup=True)
        with zipfile.ZipFile(output) as archive:
            manifest = json.loads(archive.read("ncm-gapless/manifest.json"))
            for name in WINDOWS_STARTUP_FILES:
                self.assertIn(name, manifest["sha256"])
                self.assertEqual(hashlib.sha256(archive.read("ncm-gapless/" + name)).hexdigest(), manifest["sha256"][name])
            self.assertNotIn("ncm-gapless/native/windows/startup.cpp", archive.namelist())
            self.assertNotIn("ncm-gapless/ncm_gapless_msimg32.dll", archive.namelist())

    def test_platform_runtime_files_and_checksums(self):
        for platform in ("windows", "macos"):
            with self.subTest(platform=platform), redirect_stdout(StringIO()):
                output = build(platform)
                with zipfile.ZipFile(output) as archive:
                    manifest = json.loads(archive.read("ncm-gapless/manifest.json"))
                    self.assertEqual(manifest["version"], VERSION)
                    self.assertEqual(manifest["platform"], platform)
                    for name, expected in manifest["sha256"].items():
                        self.assertEqual(hashlib.sha256(archive.read("ncm-gapless/" + name)).hexdigest(), expected)
                    for name in PLATFORM_FILES[platform]:
                        entry = archive.getinfo("ncm-gapless/" + name)
                        if name.endswith(".command"):
                            self.assertEqual(entry.external_attr >> 16 & 0o777, 0o755)
                    if platform == "macos":
                        self.assertIn("ncm-gapless/tools/macos_maintenance.py", archive.namelist())
                        self.assertIn("ncm-gapless/tools/macos_updates.py", archive.namelist())
                        self.assertIn("ncm-gapless/tools/macos-update-public-key.pem", archive.namelist())
                        self.assertNotIn("ncm-gapless/updates/macos-update.json", archive.namelist())
                    other = "windows" if platform == "macos" else "macos"
                    self.assertTrue(all("ncm-gapless/" + name not in archive.namelist() for name in PLATFORM_FILES[other]))
                    self.assertNotIn("ncm-gapless/requirements-dev.txt", archive.namelist())


if __name__ == "__main__":
    unittest.main()
