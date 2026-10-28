# Elevated file operation only. Per-user enablement is handled by its caller.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ClientPath,
    [Parameter(Mandatory = $true)][string]$Payload,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [ValidateSet('Install','Uninstall')][string]$Action = 'Install', [switch]$Repair, [string]$RuntimeDigest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Ncm-ClientCompatibility.ps1')
function Copy-NcmInstalledFile([string]$Source,[string]$Target) {
    $temporary = "$Target.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::Copy($Source,$temporary,$false)
        if ([IO.File]::Exists($Target)) { [IO.File]::Replace($temporary,$Target,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Target) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
if ([IO.Path]::GetFullPath($ResultPath) -ine [IO.Path]::GetFullPath((Join-Path $Payload 'result.json'))) { throw 'NCM_STARTUP_RESULT_PATH_INVALID' }
$result = [ordered]@{ success = $false; error = $null }
$allowed = @('MSIMG32.dll', 'ncm_gapless_msimg32.dll',
    'ncm-gapless\tools\AutoAttach-NcmGapless.ps1', 'ncm-gapless\tools\Ncm-StartupState.ps1', 'ncm-gapless\tools\Ncm-Cdp.ps1',
    'ncm-gapless\src\client-adapter.js', 'ncm-gapless\src\aac-timing.js',
    'ncm-gapless\src\gapless-engine.js', 'ncm-gapless\src\netease-gapless.js', 'ncm-gapless\LICENSES\CEF.txt')
try {
    if ($RuntimeDigest -and $RuntimeDigest -cnotmatch '^[0-9a-f]{64}$') { throw 'NCM_UPDATE_POINTER_INVALID' }
    $client = Get-Item -LiteralPath $ClientPath
    if ($Action -eq 'Install') { $null = Assert-NcmOfficialClient $ClientPath }
    elseif ($client.Name -ine 'cloudmusic.exe') { throw 'NCM_CLIENT_NAME_INVALID' }
    $directory = $client.Directory.FullName
    if ($client.Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NCM_STARTUP_TARGET_REPARSE_POINT' }
    $running = @(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" | Where-Object { $_.ExecutablePath -ieq $client.FullName })
    if ($running.Count) { throw 'NCM_EXIT_CLIENT_BEFORE_STARTUP_INSTALL' }
    $runtime = Join-Path $directory 'ncm-gapless'
    $manifestPath = Join-Path $runtime 'installation.json'
    $retiredPath = Join-Path $runtime 'uninstalled.json'
    $existing = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $existing = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($existing.owner -cne 'ncm-gapless-windows-startup-v1' -or @($existing.sha256.PSObject.Properties).Count -ne $allowed.Count) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
        foreach ($entry in $existing.sha256.PSObject.Properties) {
            if ($entry.Name -cnotin $allowed) { throw 'NCM_STARTUP_MANIFEST_INVALID' }
            $target = Join-Path $directory $entry.Name
            if (-not (Test-Path -LiteralPath $target)) {
                if ($Repair -or $Action -eq 'Uninstall') { continue }
                throw 'NCM_STARTUP_OWNED_FILE_CHANGED'
            }
            if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NCM_STARTUP_OWNED_FILE_CHANGED' }
            $actualHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ($actualHash -ine $entry.Value) {
                # Reconcile an interrupted verified proxy replacement, never arbitrary changed bytes.
                $reconciled=$false
                if ($Repair -and $RuntimeDigest -and $entry.Name -ceq 'MSIMG32.dll') {
                    $incoming=Get-Content -LiteralPath (Join-Path $Payload 'manifest.json') -Raw|ConvertFrom-Json
                    $reconciled=$actualHash -ieq $incoming.sha256.'MSIMG32.dll'
                }
                if (-not $reconciled) { throw 'NCM_STARTUP_OWNED_FILE_CHANGED' }
            }
        }
    } else {
        if ([IO.File]::Exists((Join-Path $directory 'MSIMG32.dll')) -or [IO.File]::Exists((Join-Path $directory 'ncm_gapless_msimg32.dll'))) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
        if ([IO.Directory]::Exists($runtime)) {
            if (-not [IO.File]::Exists($retiredPath) -or (Get-Content -LiteralPath $retiredPath -Raw|ConvertFrom-Json).owner -cne 'ncm-gapless-retired-v1') { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
            foreach ($name in $allowed) { if ([IO.File]::Exists((Join-Path $directory $name))) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' } }
        }
    }
    foreach ($name in @('ncm-gapless', 'ncm-gapless\tools', 'ncm-gapless\src', 'ncm-gapless\LICENSES')) {
        $candidate = Join-Path $directory $name
        if ((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'NCM_STARTUP_TARGET_REPARSE_POINT' }
    }
    if ($existing -and $existing.PSObject.Properties.Name -contains 'runtime') {
        if ($existing.runtime.digest -cnotmatch '^[0-9a-f]{64}$' -or @($existing.runtime.sha256.PSObject.Properties).Count -ne 8) { throw 'NCM_STARTUP_MANIFEST_INVALID' }
        $versioned = Join-Path $runtime ('versions\' + $existing.runtime.digest)
        $pointer = Join-Path $runtime 'active.txt'
        if ([IO.File]::Exists($pointer) -and ((Get-Item -LiteralPath $pointer).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'NCM_STARTUP_TARGET_REPARSE_POINT' }
        if ([IO.File]::Exists($pointer) -and [IO.File]::ReadAllText($pointer) -cne $existing.runtime.digest -and -not ($Repair -and $RuntimeDigest)) { throw 'NCM_STARTUP_OWNED_FILE_CHANGED' }
        foreach ($entry in $existing.runtime.sha256.PSObject.Properties) {
            if (('ncm-gapless\' + $entry.Name) -cnotin $allowed) { throw 'NCM_STARTUP_MANIFEST_INVALID' }
            $target = Join-Path $versioned $entry.Name
            if ([IO.File]::Exists($target) -and ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $entry.Value)) { throw 'NCM_STARTUP_OWNED_FILE_CHANGED' }
        }
    }
    if ($Action -eq 'Uninstall') {
        if ($existing) {
            foreach ($entry in $existing.sha256.PSObject.Properties) { $path=Join-Path $directory $entry.Name; if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
            [IO.File]::Delete($manifestPath)
            if ($existing.PSObject.Properties.Name -contains 'runtime') {
                [IO.File]::Delete((Join-Path $runtime 'active.txt'))
                foreach ($entry in $existing.runtime.sha256.PSObject.Properties) { $path=Join-Path $versioned $entry.Name; if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
            }
            [IO.File]::WriteAllText($retiredPath,'{"owner":"ncm-gapless-retired-v1"}',(New-Object Text.UTF8Encoding($false)))
            # Remove only empty directories. Preserve any unrecognized user files.
            foreach ($name in @('ncm-gapless\tools','ncm-gapless\src','ncm-gapless\LICENSES','ncm-gapless')) {
                $candidate = [IO.Path]::GetFullPath((Join-Path $directory $name))
                $boundary = [IO.Path]::GetFullPath($runtime) + [IO.Path]::DirectorySeparatorChar
                if ($candidate -ine [IO.Path]::GetFullPath($runtime) -and -not $candidate.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'NCM_STARTUP_UNSAFE_REMOVAL_PATH' }
                if ((Test-Path -LiteralPath $candidate) -and @(Get-ChildItem -LiteralPath $candidate -Force).Count -eq 0) { [IO.Directory]::Delete($candidate, $false) }
            }
        }
    } else {
        $manifest = [IO.File]::ReadAllText((Join-Path $Payload 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($manifest.owner -cne 'ncm-gapless-windows-startup-v1' -or @($manifest.sha256.PSObject.Properties).Count -ne ($allowed.Count - 1)) { throw 'NCM_STARTUP_PAYLOAD_INVALID' }
        foreach ($entry in $manifest.sha256.PSObject.Properties) {
            if ($entry.Name -cnotin $allowed -or $entry.Name -ceq 'ncm_gapless_msimg32.dll' -or
                (Get-FileHash -LiteralPath (Join-Path $Payload $entry.Name) -Algorithm SHA256).Hash -ine $entry.Value) { throw 'NCM_STARTUP_PAYLOAD_INVALID' }
        }
        $systemDrawing = Join-Path $env:WINDIR 'System32\msimg32.dll'
        $manifest.sha256 | Add-Member -NotePropertyName 'ncm_gapless_msimg32.dll' -NotePropertyValue ((Get-FileHash -LiteralPath $systemDrawing -Algorithm SHA256).Hash.ToLowerInvariant()) -Force
        if ($RuntimeDigest) {
            $runtimeHashes = [ordered]@{}
            foreach ($entry in $manifest.sha256.PSObject.Properties) {
                if (-not $entry.Name.StartsWith('ncm-gapless\',[StringComparison]::Ordinal)) { continue }
                $relative = $entry.Name.Substring(12)
                $target = Join-Path $runtime ("versions\$RuntimeDigest\$relative")
                [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
                if ([IO.File]::Exists($target)) {
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $entry.Value) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
                } else { Copy-NcmInstalledFile (Join-Path $Payload $entry.Name) $target }
                $runtimeHashes[$relative] = $entry.Value
                # Legacy bootstrap stays unchanged; mapped old loaders can finish safely.
                if ($existing) { $manifest.sha256.($entry.Name) = $existing.sha256.($entry.Name) }
            }
            $manifest | Add-Member -NotePropertyName runtime -NotePropertyValue @{digest=$RuntimeDigest;sha256=$runtimeHashes}
        }
        $copied = New-Object 'System.Collections.Generic.List[string]'
        $backup = Join-Path $Payload 'previous-installation'
        if ($existing) {
            foreach ($entry in $existing.sha256.PSObject.Properties) {
                $saved = Join-Path $backup $entry.Name
                [void][IO.Directory]::CreateDirectory((Split-Path $saved -Parent))
                if ([IO.File]::Exists((Join-Path $directory $entry.Name))) { [IO.File]::Copy((Join-Path $directory $entry.Name), $saved, $true) }
            }
        }
        try {
            # Install the loader last, once its forwarding DLL and runtime exist.
            $entries = @($manifest.sha256.PSObject.Properties | Sort-Object { if ($_.Name -ceq 'MSIMG32.dll') { 1 } else { 0 } })
            foreach ($entry in $entries) {
                if ($RuntimeDigest -and $entry.Name.StartsWith('ncm-gapless\',[StringComparison]::Ordinal)) { continue }
                $source = $(if ($entry.Name -ceq 'ncm_gapless_msimg32.dll') { $systemDrawing } else { Join-Path $Payload $entry.Name })
                $target = Join-Path $directory $entry.Name
                [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
                Copy-NcmInstalledFile $source $target
                $copied.Add($entry.Name)
            }
            if ($RuntimeDigest) {
                $pointerSource = Join-Path $Payload 'active.txt'
                [IO.File]::WriteAllText($pointerSource,$RuntimeDigest,(New-Object Text.UTF8Encoding($false)))
            }
            $manifestSource = Join-Path $Payload 'installed-manifest.json'
            [IO.File]::WriteAllText($manifestSource, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            Copy-NcmInstalledFile $manifestSource $manifestPath
            if ($RuntimeDigest) { Copy-NcmInstalledFile $pointerSource (Join-Path $runtime 'active.txt') }
            elseif ($existing -and $existing.PSObject.Properties.Name -contains 'runtime') { [IO.File]::Delete((Join-Path $runtime 'active.txt')) }
            [IO.File]::Delete($retiredPath)
        } catch {
            # On a fresh installation, remove only bytes copied by this attempt.
            if (-not $existing) {
                foreach ($name in $copied) {
                    $target = Join-Path $directory $name
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ieq $manifest.sha256.$name) { [IO.File]::Delete($target) }
                }
            } else {
                foreach ($entry in $existing.sha256.PSObject.Properties) {
                    if ([IO.File]::Exists((Join-Path $backup $entry.Name))) { Copy-NcmInstalledFile (Join-Path $backup $entry.Name) (Join-Path $directory $entry.Name) }
                    elseif ($copied.Contains($entry.Name)) { [IO.File]::Delete((Join-Path $directory $entry.Name)) }
                }
                [IO.File]::WriteAllText($manifestPath, ($existing | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
                if ($RuntimeDigest -or $existing.PSObject.Properties.Name -contains 'runtime') {
                    if ($existing.PSObject.Properties.Name -contains 'runtime') { [IO.File]::WriteAllText((Join-Path $runtime 'active.txt'),$existing.runtime.digest,(New-Object Text.UTF8Encoding($false))) }
                    else { [IO.File]::Delete((Join-Path $runtime 'active.txt')) }
                }
            }
            throw
        }
    }
    $result.success = $true
} catch {
    $match = [regex]::Match($_.ToString(), 'NCM_[A-Z_]+')
    $result.error = $(if ($match.Success) { $match.Value } else { 'NCM_STARTUP_FILE_OPERATION_FAILED' })
} finally {
    [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
if (-not $result.success) { exit 1 }
