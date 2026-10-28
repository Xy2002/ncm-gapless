# Elevated file operation only. Per-user enablement is handled by its caller.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ClientPath,
    [Parameter(Mandatory = $true)][string]$Payload,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [ValidateSet('Install','Uninstall')][string]$Action = 'Install')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([IO.Path]::GetFullPath($ResultPath) -ine [IO.Path]::GetFullPath((Join-Path $Payload 'result.json'))) { throw 'NCM_STARTUP_RESULT_PATH_INVALID' }
$result = [ordered]@{ success = $false; error = $null }
$allowed = @('MSIMG32.dll', 'ncm_gapless_msimg32.dll',
    'ncm-gapless\tools\AutoAttach-NcmGapless.ps1', 'ncm-gapless\tools\Ncm-StartupState.ps1', 'ncm-gapless\tools\Ncm-Cdp.ps1',
    'ncm-gapless\src\client-adapter.js', 'ncm-gapless\src\aac-timing.js',
    'ncm-gapless\src\gapless-engine.js', 'ncm-gapless\src\netease-gapless.js', 'ncm-gapless\LICENSES\CEF.txt')
try {
    $client = Get-Item -LiteralPath $ClientPath
    if ($client.Name -ine 'cloudmusic.exe' -or $client.VersionInfo.ProductVersion -ne '3.1.42.205594' -or
        (Get-FileHash -LiteralPath $client.FullName -Algorithm SHA256).Hash -ine '1d593a307e074368cb9539d3aa86577231c8b53c6e966d43bf7661a25f165ad3') { throw 'NCM_STARTUP_CLIENT_UNVERIFIED' }
    $directory = $client.Directory.FullName
    if ($client.Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NCM_STARTUP_TARGET_REPARSE_POINT' }
    $running = @(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" | Where-Object { $_.ExecutablePath -ieq $client.FullName })
    if ($running.Count) { throw 'NCM_EXIT_CLIENT_BEFORE_STARTUP_INSTALL' }
    $runtime = Join-Path $directory 'ncm-gapless'
    $manifestPath = Join-Path $runtime 'installation.json'
    $existing = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $existing = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($existing.owner -cne 'ncm-gapless-windows-startup-v1' -or @($existing.sha256.PSObject.Properties).Count -ne $allowed.Count) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
        foreach ($entry in $existing.sha256.PSObject.Properties) {
            if ($entry.Name -cnotin $allowed) { throw 'NCM_STARTUP_MANIFEST_INVALID' }
            $target = Join-Path $directory $entry.Name
            if (-not (Test-Path -LiteralPath $target) -or
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $entry.Value) { throw 'NCM_STARTUP_OWNED_FILE_CHANGED' }
        }
    } elseif ((Test-Path -LiteralPath $runtime) -or (Test-Path -LiteralPath (Join-Path $directory 'MSIMG32.dll')) -or
        (Test-Path -LiteralPath (Join-Path $directory 'ncm_gapless_msimg32.dll'))) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
    foreach ($name in @('ncm-gapless', 'ncm-gapless\tools', 'ncm-gapless\src', 'ncm-gapless\LICENSES')) {
        $candidate = Join-Path $directory $name
        if ((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'NCM_STARTUP_TARGET_REPARSE_POINT' }
    }
    if ($Action -eq 'Uninstall') {
        if ($existing) {
            foreach ($entry in $existing.sha256.PSObject.Properties) { [IO.File]::Delete((Join-Path $directory $entry.Name)) }
            [IO.File]::Delete($manifestPath)
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
        $copied = New-Object 'System.Collections.Generic.List[string]'
        $backup = Join-Path $Payload 'previous-installation'
        if ($existing) {
            foreach ($entry in $existing.sha256.PSObject.Properties) {
                $saved = Join-Path $backup $entry.Name
                [void][IO.Directory]::CreateDirectory((Split-Path $saved -Parent))
                [IO.File]::Copy((Join-Path $directory $entry.Name), $saved, $true)
            }
        }
        try {
            # Install the loader last, once its forwarding DLL and runtime exist.
            $entries = @($manifest.sha256.PSObject.Properties | Sort-Object { if ($_.Name -ceq 'MSIMG32.dll') { 1 } else { 0 } })
            foreach ($entry in $entries) {
                $source = $(if ($entry.Name -ceq 'ncm_gapless_msimg32.dll') { $systemDrawing } else { Join-Path $Payload $entry.Name })
                $target = Join-Path $directory $entry.Name
                [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
                [IO.File]::Copy($source, $target, $true)
                $copied.Add($entry.Name)
            }
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        } catch {
            # On a fresh installation, remove only bytes copied by this attempt.
            if (-not $existing) {
                foreach ($name in $copied) {
                    $target = Join-Path $directory $name
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ieq $manifest.sha256.$name) { [IO.File]::Delete($target) }
                }
            } else {
                foreach ($entry in $existing.sha256.PSObject.Properties) {
                    [IO.File]::Copy((Join-Path $backup $entry.Name), (Join-Path $directory $entry.Name), $true)
                }
                [IO.File]::WriteAllText($manifestPath, ($existing | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
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
