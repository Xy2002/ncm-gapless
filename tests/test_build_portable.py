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
from build_portable import build, PLATFORM_FILES, VERSION


class PortableTests(unittest.TestCase):
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
                    other = "windows" if platform == "macos" else "macos"
                    self.assertTrue(all("ncm-gapless/" + name not in archive.namelist() for name in PLATFORM_FILES[other]))
                    self.assertNotIn("ncm-gapless/requirements-dev.txt", archive.namelist())


if __name__ == "__main__":
    unittest.main()
