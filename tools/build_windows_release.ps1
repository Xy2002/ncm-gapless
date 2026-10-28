[CmdletBinding()]
param([Parameter(Mandatory=$true)][long]$Sequence,[string]$Version='0.5.0-experimental',
    [Parameter(Mandatory=$true)][string]$Tag)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Ncm-Maintenance.ps1')
if ($Tag -cnotmatch '^[a-zA-Z0-9._-]+$') { throw 'NCM_RELEASE_TAG_INVALID' }
$repository = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $repository 'artifacts\windows-maintenance'
[void][IO.Directory]::CreateDirectory($directory)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
    if ($env:NCM_WINDOWS_RELEASE_KEY) { $privateKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:NCM_WINDOWS_RELEASE_KEY)) }
    else {
        Add-Type -AssemblyName System.Security
        $encrypted = [IO.File]::ReadAllBytes((Join-Path $repository '.local\keys\update-private.dpapi'))
        $privateKey = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($encrypted,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
    }
    $rsa.FromXmlString($privateKey)
    if ($rsa.ToXmlString($false) -cne [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'update-public-key.xml')).Trim()) { throw 'NCM_RELEASE_KEY_MISMATCH' }
    Add-Type -AssemblyName System.IO.Compression
    $packagePath = Join-Path $directory 'windows-payload.zip'
    $stream = [IO.File]::Open($packagePath,'Create','Write','None')
    $zip = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    $files = [ordered]@{}
    try {
        foreach ($name in $script:NcmReleaseFiles) {
            $source = $(if ($name -ceq 'MSIMG32.dll') { 'native\windows\MSIMG32.dll' } else { $name.Substring(12) })
            $bytes = [IO.File]::ReadAllBytes((Join-Path $repository $source))
            $files[$name] = @{sha256=(Get-NcmDigest $bytes);bytes=$bytes.Length}
            $entry = $zip.CreateEntry($name); $output = $entry.Open()
            try { $output.Write($bytes,0,$bytes.Length) } finally { $output.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    $package = [IO.File]::ReadAllBytes($packagePath)
    $document = [ordered]@{schema=1;channel='windows-maintenance';sequence=$Sequence;version=$Version;
        package=@{url=($script:NcmAssetPrefix+$Tag+'/windows-payload.zip');sha256=(Get-NcmDigest $package);bytes=$package.Length};files=$files}
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($document | ConvertTo-Json -Depth 8 -Compress))
    $envelope = @{payload=[Convert]::ToBase64String($bytes);signature=[Convert]::ToBase64String($rsa.SignData($bytes,'SHA256'))}
    Write-NcmMaintenanceJson (Join-Path $directory 'windows-update.json') $envelope
    $release = Read-NcmSignedRelease ([IO.File]::ReadAllBytes((Join-Path $directory 'windows-update.json'))) $rsa.ToXmlString($false)
    $null = Read-NcmReleasePayload $package $release
    Write-Output "Signed Windows release $Version sequence $Sequence ($($package.Length) bytes)"
} finally { $rsa.Dispose(); $privateKey=$null }
