# Read-only discovery. Runs in Windows PowerShell 5.1 and PowerShell 7.
[CmdletBinding()]
param(
    [string]$ClientPath,
    [switch]$Hashes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PeArchitecture {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Not a PE executable' }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset + 6 -gt $stream.Length) { throw 'Invalid PE header offset' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature' }
        switch ($reader.ReadUInt16()) {
            0x014c { return 'x86' }
            0x8664 { return 'x64' }
            0xaa64 { return 'arm64' }
            default { return 'unknown' }
        }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

$candidates = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($ClientPath) {
    $resolved = (Resolve-Path -LiteralPath $ClientPath).Path
    if ([IO.Path]::GetFileName($resolved) -ine 'cloudmusic.exe') { throw 'ClientPath must point to cloudmusic.exe' }
    [void]$candidates.Add($resolved)
}
else {
    $registryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in @(Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue)) {
        $fields = $entry.PSObject.Properties.Name
        if ($fields -notcontains 'DisplayName' -or $entry.DisplayName -notmatch 'CloudMusic|NetEase.*Music|\u7f51\u6613\u4e91\u97f3\u4e50') { continue }
        if ($fields -contains 'InstallLocation' -and $entry.InstallLocation) {
            [void]$candidates.Add((Join-Path $entry.InstallLocation 'cloudmusic.exe'))
        }
        if ($fields -contains 'DisplayIcon' -and $entry.DisplayIcon) {
            $icon = ([string]$entry.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"')
            if ([IO.Path]::GetFileName($icon) -ieq 'cloudmusic.exe') { [void]$candidates.Add($icon) }
        }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        foreach ($relative in @('NetEase\CloudMusic\cloudmusic.exe', 'Programs\CloudMusic\cloudmusic.exe')) {
            [void]$candidates.Add((Join-Path $base $relative))
        }
    }
}

$clients = @(foreach ($path in $candidates) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $file = Get-Item -LiteralPath $path
    $info = [ordered]@{
        path = $file.FullName
        version = $file.VersionInfo.ProductVersion
        architecture = Get-PeArchitecture -Path $file.FullName
        cefPresent = Test-Path -LiteralPath (Join-Path $file.DirectoryName 'libcef.dll')
        packagePresent = Test-Path -LiteralPath (Join-Path $file.DirectoryName 'package\orpheus.ntpk')
        patchStatus = 'not-queried-use-Get-NcmGaplessStatus'
    }
    if ($Hashes) {
        $digests = [ordered]@{}
        foreach ($relative in @('cloudmusic.exe', 'cloudmusic.dll', 'package\orpheus.ntpk')) {
            $artifact = Join-Path $file.DirectoryName $relative
            if (Test-Path -LiteralPath $artifact -PathType Leaf) {
                $digests[$relative] = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $info['sha256'] = $digests
    }
    [PSCustomObject]$info
})

$windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
[PSCustomObject]@{
    windowsBuild = $windows.CurrentBuildNumber
    processArchitecture = $env:PROCESSOR_ARCHITECTURE
    powershell = $PSVersionTable.PSVersion.ToString()
    discovered = $clients.Count
    clients = $clients
    mutatesClient = $false
} | ConvertTo-Json -Depth 6
