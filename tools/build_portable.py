"""Package only portable runtime files and sanitized evidence."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "docs/roadmap.md", "compatibility.json",
    "Start-NcmGapless.cmd", "Start-NcmGapless.ps1",
    "Stop-NcmGapless.cmd", "Stop-NcmGapless.ps1",
    "Get-NcmGaplessStatus.cmd", "Get-NcmGaplessStatus.ps1",
    "tools/Ncm-Cdp.ps1", "tools/Get-ClientInfo.ps1",
    "src/client-adapter.js", "src/aac-timing.js", "src/gapless-engine.js", "src/netease-gapless.js", "src/gapless-core.js",
    "docs/implementation.md", "docs/feasibility.md", "docs/evidence/audio-proof.json", "docs/evidence/source-access.json",
    "docs/evidence/audio-proof-v0.2.json", "docs/evidence/integration.json",
    "docs/evidence/controls.json", "docs/evidence/disable.json", "docs/evidence/cold-start.json",
    "docs/evidence/dawn-fm-natural-1.json", "docs/evidence/dawn-fm-natural-2.json",
    "docs/evidence/handoff-v0.2.1.json", "docs/evidence/integration-v0.2.1.json",
    "docs/evidence/review-fixes-v0.2.2.json",
]


def main():
    output = ROOT / "artifacts" / "ncm-gapless-0.2.2-windows.zip"
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"version": "0.2.2-experimental", "clientVersion": "3.1.42.205594", "sha256": {}}
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in FILES:
            data = (ROOT / name).read_bytes()
            if name.endswith(".cmd"):
                data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            archive.writestr("ncm-gapless/" + name, data)
            manifest["sha256"][name] = hashlib.sha256(data).hexdigest()
        archive.writestr("ncm-gapless/manifest.json", json.dumps(manifest, indent=2) + "\n")
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("Archive integrity failed")
        if any(".local" in name or name.endswith(".py") for name in archive.namelist()):
            raise RuntimeError("Research files entered portable archive")
    print(json.dumps({"path": str(output), "bytes": output.stat().st_size,
                      "sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "runtimeFiles": len(FILES)}))


if __name__ == "__main__":
    main()
