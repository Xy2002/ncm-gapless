# Uses a byte-identical copy of cloudmusic.exe only for metadata validation.
# Never executes it; all installation/removal targets are inside .local/.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $repository ('.local\windows-startup-install-test-' + [Guid]::NewGuid().ToString('N'))
$clientRoot = Join-Path $fixture 'client'
$payload = Join-Path $fixture 'payload'
[void][IO.Directory]::CreateDirectory($clientRoot)
[void][IO.Directory]::CreateDirectory($payload)
$client = Join-Path $clientRoot 'cloudmusic.exe'
[IO.File]::Copy('C:\Program Files\NetEase\CloudMusic\cloudmusic.exe', $client)
$originalHash = (Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash
$files = @('tools\AutoAttach-NcmGapless.ps1','tools\Ncm-StartupState.ps1','tools\Ncm-Cdp.ps1',
    'src\client-adapter.js','src\aac-timing.js','src\gapless-engine.js','src\netease-gapless.js','LICENSES\CEF.txt')
$hashes = [ordered]@{}
[IO.File]::Copy((Join-Path $repository 'native\windows\MSIMG32.dll'), (Join-Path $payload 'MSIMG32.dll'))
$hashes['MSIMG32.dll'] = (Get-FileHash -LiteralPath (Join-Path $payload 'MSIMG32.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
foreach ($name in $files) {
    $relative = 'ncm-gapless\' + $name
    $target = Join-Path $payload $relative
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    [IO.File]::Copy((Join-Path $repository $name), $target)
    $hashes[$relative] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest = [ordered]@{ owner='ncm-gapless-windows-startup-v1'; clientVersion='3.1.42.205594'; sha256=$hashes }
[IO.File]::WriteAllText((Join-Path $payload 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
$worker = Join-Path $repository 'tools\Set-NcmStartupInstallation.ps1'
$resultPath = Join-Path $payload 'result.json'
function Run-Installation([string]$Action='Install',[switch]$Repair) {
    $extra = @(); if ($Repair) { $extra += '-Repair' }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $worker -ClientPath $client -Payload $payload -ResultPath $resultPath -Action $Action @extra
    return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
}
$result = Run-Installation
if (-not $result.success) { throw "FRESH_INSTALL_FAILED: $($result.error)" }
foreach ($name in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $clientRoot $name) -Algorithm SHA256).Hash -ine $hashes[$name]) { throw 'INSTALLED_BYTES_MISMATCH' }
}
Write-Host 'PASS installation copies only the declared loader and runtime bytes'
$result = Run-Installation
if (-not $result.success) { throw "REINSTALL_FAILED: $($result.error)" }
Write-Host 'PASS repeat installation validates ownership and succeeds'
[IO.File]::Delete((Join-Path $clientRoot 'MSIMG32.dll'))
[IO.File]::Delete((Join-Path $clientRoot 'ncm-gapless\src\client-adapter.js'))
$result = Run-Installation -Repair
if (-not $result.success -or -not [IO.File]::Exists((Join-Path $clientRoot 'MSIMG32.dll')) -or
    (Get-FileHash -LiteralPath (Join-Path $clientRoot 'ncm-gapless\src\client-adapter.js')).Hash -ine $hashes['ncm-gapless\src\client-adapter.js']) { throw 'REPAIR_FAILED' }
Write-Host 'PASS missing loader and runtime files are repaired without changing the client'
$changed = Join-Path $clientRoot 'ncm-gapless\tools\AutoAttach-NcmGapless.ps1'
$saved = [IO.File]::ReadAllBytes($changed)
[IO.File]::AppendAllText($changed, '# user change')
$result = Run-Installation 'Uninstall'
if ($result.success -or $result.error -cne 'NCM_STARTUP_OWNED_FILE_CHANGED' -or -not (Test-Path -LiteralPath $changed)) { throw 'CHANGED_FILE_WAS_NOT_PRESERVED' }
[IO.File]::WriteAllBytes($changed, $saved)
Write-Host 'PASS changed installed files block removal and are preserved'
$userNote = Join-Path $clientRoot 'ncm-gapless\user-note.txt'
[IO.File]::WriteAllText($userNote, 'keep this file')
$result = Run-Installation 'Uninstall'
if (-not $result.success) { throw "UNINSTALL_FAILED: $($result.error)" }
if (-not (Test-Path -LiteralPath $userNote) -or (Test-Path -LiteralPath (Join-Path $clientRoot 'MSIMG32.dll'))) { throw 'UNINSTALL_BOUNDARY_FAILED' }
if ((Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash -cne $originalHash) { throw 'ORIGINAL_EXE_CHANGED' }
Write-Host 'PASS removal preserves user files and the original executable'
[IO.File]::WriteAllText((Join-Path $clientRoot 'MSIMG32.dll'), 'unrelated loader')
$result = Run-Installation
if ($result.success -or $result.error -cne 'NCM_STARTUP_INSTALLATION_CONFLICT' -or [IO.File]::ReadAllText((Join-Path $clientRoot 'MSIMG32.dll')) -cne 'unrelated loader') { throw 'FOREIGN_LOADER_WAS_NOT_PRESERVED' }
Write-Host 'PASS a pre-existing loader is never overwritten'
Write-Host '6 installation ownership checks passed. The real installation was not modified.'
