"""Package only portable runtime files and sanitized evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.6.0-experimental"
FILES = [
    "LICENSE", "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "docs/roadmap.md", "docs/windows-startup.md",
    "docs/windows-automatic-investigation.md", "LICENSES/CEF.txt", "compatibility.json",
    "docs/evidence/windows-startup-v1.json",
    "src/client-adapter.js", "src/aac-timing.js", "src/gapless-engine.js", "src/netease-gapless.js", "src/gapless-core.js",
    "docs/implementation.md", "docs/feasibility.md", "docs/evidence/audio-proof.json", "docs/evidence/source-access.json",
    "docs/evidence/audio-proof-v0.2.json", "docs/evidence/integration.json",
    "docs/evidence/controls.json", "docs/evidence/disable.json", "docs/evidence/cold-start.json",
    "docs/evidence/dawn-fm-natural-1.json", "docs/evidence/dawn-fm-natural-2.json",
    "docs/evidence/handoff-v0.2.1.json", "docs/evidence/integration-v0.2.1.json",
    "docs/evidence/review-fixes-v0.2.2.json",
    "docs/macos.md", "docs/evidence/macos-validation.json",
    "docs/evidence/macos-first-run-v0.3.1.json",
    "docs/evidence/macos-automation-v0.4.0.json",
    "docs/evidence/macos-setup-v0.4.0.json",
]
PLATFORM_FILES = {
    "windows": ["Start-NcmGapless.cmd", "Start-NcmGapless.ps1", "Stop-NcmGapless.cmd", "Stop-NcmGapless.ps1",
                "Get-NcmGaplessStatus.cmd", "Get-NcmGaplessStatus.ps1", "tools/Ncm-Cdp.ps1", "tools/Get-ClientInfo.ps1", "tools/Ncm-StartupState.ps1", "tools/Ncm-ClientCompatibility.ps1"],
    "macos": ["Start-NcmGapless.command", "Stop-NcmGapless.command", "Get-NcmGaplessStatus.command",
              "tools/macos_launcher.py", "tools/macos_automation.json", "tools/cdp_probe.py", "requirements-macos.txt",
              "tools/macos_maintenance.py", "tools/macos_updates.py", "tools/macos-update-public-key.pem",
              "docs/macos-maintenance.md"],
}
WINDOWS_STARTUP_FILES = [
    "Install-NcmGaplessStartup.cmd", "Install-NcmGaplessStartup.ps1", "Uninstall-NcmGaplessStartup.cmd",
    "tools/AutoAttach-NcmGapless.ps1", "tools/Set-NcmStartupInstallation.ps1", "native/windows/MSIMG32.dll",
    'Install-NcmGaplessMaintenance.ps1', 'tools/Ncm-Maintenance.ps1',
]
WINDOWS_MAINTENANCE_FILES = [
    'Install-NcmGaplessMaintenance.cmd', 'Install-NcmGaplessMaintenance.ps1', 'Uninstall-NcmGaplessMaintenance.cmd',
    'tools/Ncm-Maintenance.ps1', 'tools/Invoke-NcmMaintenance.ps1', 'tools/update-public-key.xml',
    'docs/windows-maintenance.md',
    'docs/evidence/windows-maintenance-v0.5.json',
    'docs/evidence/windows-ci-release-v0.5.json',
]


def build(platform, include_windows_startup=False, include_windows_maintenance=False, include_macos_maintenance=False):
    if include_windows_maintenance:
        include_windows_startup = True
    if include_windows_startup and platform != "windows":
        raise ValueError("The Windows startup loader is only available in the Windows package")
    if include_macos_maintenance and platform != "macos":
        raise ValueError("The macOS maintenance payload is only available in the macOS package")
    suffix = platform + ("-maintenance" if include_windows_maintenance or include_macos_maintenance else "-startup" if include_windows_startup else "")
    output = ROOT / "artifacts" / f"ncm-gapless-{VERSION.split('-')[0]}-{suffix}.zip"
    output.parent.mkdir(parents=True, exist_ok=True)
    files = FILES + PLATFORM_FILES[platform]
    if include_windows_startup:
        files += WINDOWS_STARTUP_FILES
    if include_windows_maintenance:
        files += WINDOWS_MAINTENANCE_FILES
    files = list(dict.fromkeys(files))
    manifest = {"version": VERSION, "platform": platform,
                "clientVersion": "3.1.12.3444" if platform == "macos" else "3.1.42.205594", "sha256": {}}
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            data = (ROOT / name).read_bytes()
            if name.endswith(".cmd"):
                data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            entry = zipfile.ZipInfo("ncm-gapless/" + name)
            entry.create_system = 3
            entry.external_attr = (0o100755 if name.endswith(".command") else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
            manifest["sha256"][name] = hashlib.sha256(data).hexdigest()
        if include_windows_maintenance or include_macos_maintenance:
            for name in (f'{platform}-update.json', f'{platform}-payload.zip'):
                data = (ROOT / f'artifacts/{platform}-maintenance' / name).read_bytes()
                archive.writestr('ncm-gapless/updates/' + name, data)
                manifest['sha256']['updates/' + name] = hashlib.sha256(data).hexdigest()
        archive.writestr("ncm-gapless/manifest.json", json.dumps(manifest, indent=2) + "\n")
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("Archive integrity failed")
        allowed_python = {"ncm-gapless/" + name for name in PLATFORM_FILES[platform] if name.endswith(".py")}
        if any(".local" in name or name.endswith(".py") and name not in allowed_python for name in archive.namelist()):
            raise RuntimeError("Research files entered portable archive")
    print(json.dumps({"path": str(output), "bytes": output.stat().st_size,
                      "sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "runtimeFiles": len(files)}))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=tuple(PLATFORM_FILES), default="windows")
    parser.add_argument("--windows-startup", action="store_true", help="Include the locally built optional Windows startup loader")
    parser.add_argument('--windows-maintenance', action='store_true', help='Include the signed Windows maintenance installer and payload')
    parser.add_argument('--macos-maintenance', action='store_true', help='Include the signed macOS maintenance payload')
    args = parser.parse_args()
    build(args.platform, include_windows_startup=args.windows_startup, include_windows_maintenance=args.windows_maintenance,
          include_macos_maintenance=args.macos_maintenance)


if __name__ == "__main__":
    main()
