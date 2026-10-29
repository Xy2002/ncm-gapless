# Real installer release selection and signature checks with controlled download bytes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'tools\Ncm-Maintenance.ps1')
Add-Type -AssemblyName System.IO.Compression
$fixture=Join-Path $repository ('.local\maintenance-install-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
$rsa.PersistKeyInCsp=$false
$publicKey=$rsa.ToXmlString($false)
$script:requests=New-Object 'System.Collections.Generic.List[string]'
$script:downloadError=''
$script:checks=0
$savedProgramFiles=$env:ProgramFiles
function Make-Release([long]$Sequence,[switch]$Extra,[string]$Url) {
    $stream=New-Object IO.MemoryStream
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    $files=[ordered]@{}
    try {
        foreach ($name in $script:NcmReleaseFiles) {
            $bytes=[Text.Encoding]::UTF8.GetBytes("fixture $Sequence $name")
            $files[$name]=@{sha256=(Get-NcmDigest $bytes);bytes=$bytes.Length}
            $output=$zip.CreateEntry($name).Open()
            try { $output.Write($bytes,0,$bytes.Length) } finally { $output.Dispose() }
        }
        if ($Extra) { $null=$zip.CreateEntry('../escape.txt') }
    } finally { $zip.Dispose();$stream.Dispose() }
    $package=$stream.ToArray()
    if (-not $Url) { $Url=$script:NcmAssetPrefix+"fixture-$Sequence/windows-payload.zip" }
    $document=@{schema=1;channel='windows-maintenance';sequence=$Sequence;version='0.5.0-experimental';
        package=@{url=$Url;bytes=$package.Length;sha256=(Get-NcmDigest $package)};files=$files}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($document|ConvertTo-Json -Depth 8 -Compress))
    $envelope=[Text.Encoding]::UTF8.GetBytes((@{payload=[Convert]::ToBase64String($bytes);signature=[Convert]::ToBase64String($rsa.SignData($bytes,'SHA256'))}|ConvertTo-Json))
    return @{envelope=$envelope;package=$package;url=$Url}
}
function Get-NcmHttpsBytes($Url,$MaximumBytes) {
    $script:requests.Add($Url)
    if ($script:downloadError -eq 'manifest' -or ($script:downloadError -eq 'payload' -and $Url -ne $script:NcmFeedUrl)) { throw 'fixture offline' }
    if ($Url -ceq $script:NcmFeedUrl) { $bytes=$script:online.envelope }
    elseif ($Url -ceq $script:online.url) { $bytes=$script:online.package }
    else { throw "UNEXPECTED_DOWNLOAD $Url" }
    if ($MaximumBytes -lt $bytes.Length -or $MaximumBytes -gt 8388608) { throw 'DOWNLOAD_BOUND_INVALID' }
    return ,$bytes
}
function Case([string]$CaseName,[scriptblock]$Action) {
    $script:requests.Clear();$script:downloadError='';$script:online=$second
    &$Action
    $script:checks++
    Write-Host "PASS $CaseName"
}
function Reject([scriptblock]$Action,[string]$Code,[switch]$Help) {
    $caught=$null
    try { $null=&$Action } catch { $caught=$_.ToString() }
    if (-not $caught -or $caught -notmatch [regex]::Escape($Code)) { throw "EXPECTED $Code; ACTUAL $caught" }
    if ($Help -and ($caught -notmatch 'windows-update.json' -or $caught -notmatch 'windows-payload.zip' -or
        $caught -notmatch 'https://github.com/Xy2002/ncm-gapless/releases' -or $caught -notmatch 'Install-NcmGaplessMaintenance.cmd')) { throw "MISSING_RECOVERY_HELP $caught" }
}
function Put-Release([string]$Root,[string]$Layout,$Release) {
    $directory=Join-Path $Root $Layout
    Write-NcmAtomicBytes (Join-Path $directory 'windows-update.json') $Release.envelope
    Write-NcmAtomicBytes (Join-Path $directory 'windows-payload.zip') $Release.package
}
function Assert-Release($Value,$Expected,[int]$Downloads) {
    if ($Value.release.digest -cne (Read-NcmSignedRelease $Expected.envelope $publicKey).digest -or
        (Get-NcmDigest $Value.package) -cne (Get-NcmDigest $Expected.package) -or $script:requests.Count -ne $Downloads) { throw 'WRONG_RELEASE_OR_DOWNLOAD_COUNT' }
}
function Make-Installer([string]$Name) {
    $packet=Join-Path $fixture $Name
    foreach ($relative in @('tools','client')) { [void][IO.Directory]::CreateDirectory((Join-Path $packet $relative)) }
    [IO.File]::Copy((Join-Path $repository 'Install-NcmGaplessMaintenance.ps1'),(Join-Path $packet 'Install-NcmGaplessMaintenance.ps1'))
    [IO.File]::Copy((Join-Path $repository 'tools\Ncm-Maintenance.ps1'),(Join-Path $packet 'tools\Ncm-Maintenance.ps1'))
    foreach ($name in @('Get-ClientInfo.ps1','Ncm-StartupState.ps1','Invoke-NcmMaintenance.ps1','Set-NcmStartupInstallation.ps1')) {
        [IO.File]::WriteAllText((Join-Path $packet "tools\$name"),'# Fixture: must not be executed.')
    }
    [IO.File]::WriteAllText((Join-Path $packet 'tools\update-public-key.xml'),$publicKey)
    [IO.File]::WriteAllText((Join-Path $packet 'client\cloudmusic.exe'),'Fixture: never executed.')
    Write-NcmAtomicBytes (Join-Path $packet 'feed.json') $second.envelope
    Write-NcmAtomicBytes (Join-Path $packet 'feed.zip') $second.package
    # Stop at the ACL boundary; all task and elevation entry points are replaced.
    $mocks=@'
function New-Object {
    param([string]$TypeName,[object[]]$ArgumentList)
    if ($TypeName -eq 'Security.Principal.WindowsPrincipal') {
        $principal=[PSCustomObject]@{}
        $principal|Add-Member ScriptMethod IsInRole { param($Role) return ($env:NCM_INSTALL_TEST_ELEVATE -ne '1') }
        return $principal
    }
    return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Assert-NcmOfficialClient($ClientPath) { return @{path=$ClientPath;version='3.1.42.205594'} }
function Assert-NcmAdminDirectory($Path) {
    if (-not [IO.Path]::GetFullPath($Path).StartsWith($env:NCM_INSTALL_TEST_ROOT+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'FIXTURE_PATH_ESCAPE' }
}
function Get-ScheduledTask { [CmdletBinding()]param($TaskName) }
function Set-Acl { param($LiteralPath,$AclObject) throw 'FIXTURE_INSTALL_READY' }
function New-ScheduledTaskAction { throw 'UNEXPECTED_TASK_MUTATION' }
function Register-ScheduledTask { throw 'UNEXPECTED_TASK_MUTATION' }
function Start-Process {
    param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru)
    if ($env:NCM_INSTALL_TEST_ELEVATION_FAIL -eq '1') { return [PSCustomObject]@{ExitCode=1} }
    throw "FIXTURE_ELEVATION $ArgumentList"
}
function Get-NcmHttpsBytes($Url,$MaximumBytes) {
    [IO.File]::AppendAllText((Join-Path $env:NCM_INSTALL_TEST_ROOT 'requests.txt'),"$Url`n")
    if ($Url -ceq $script:NcmFeedUrl) { return ,[IO.File]::ReadAllBytes((Join-Path $env:NCM_INSTALL_TEST_ROOT 'feed.json')) }
    if ($Url -cne ($script:NcmAssetPrefix+'fixture-101/windows-payload.zip')) { throw 'UNEXPECTED_DOWNLOAD' }
    return ,[IO.File]::ReadAllBytes((Join-Path $env:NCM_INSTALL_TEST_ROOT 'feed.zip'))
}
'@
    [IO.File]::WriteAllText((Join-Path $packet 'tools\Ncm-ClientCompatibility.ps1'),$mocks)
    return $packet
}
function Run-Installer([string]$Packet,[switch]$Offline,[switch]$Elevate,[switch]$FailElevation,[switch]$Uninstall) {
    $env:ProgramFiles=Join-Path $Packet 'machine files'
    $env:NCM_INSTALL_TEST_ROOT=$Packet
    $env:NCM_INSTALL_TEST_ELEVATE=$(if ($Elevate) {'1'} else {'0'})
    $env:NCM_INSTALL_TEST_ELEVATION_FAIL=$(if ($FailElevation) {'1'} else {'0'})
    & (Join-Path $Packet 'Install-NcmGaplessMaintenance.ps1') -ClientPath (Join-Path $Packet 'client\cloudmusic.exe') -MachineOnly -Offline:$Offline -Uninstall:$Uninstall
}
try {
    $first=Make-Release 100;$second=Make-Release 101
    Case 'source ZIP missing files has actionable offline error, without file-read exception' {
        Reject {Get-NcmMaintenanceInstallRelease (Join-Path $fixture 'empty') $publicKey -Offline} 'NCM_MAINTENANCE_PACKAGE_MISSING' -Help
        if ($script:requests.Count) { throw 'OFFLINE_ATTEMPTED_NETWORK' }
    }
    Case 'source ZIP downloads and verifies the fixed channel and its signed payload' {
        $source=Join-Path $fixture 'source ZIP (2)'
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey) $second 2
        if ($script:requests[0] -cne $script:NcmFeedUrl -or $script:requests[1] -cne $second.url -or [IO.Directory]::Exists($source)) { throw 'SOURCE_DOWNLOAD_MUTATED_DIRECTORY_OR_USED_WRONG_FEED' }
    }
    Case 'complete embedded maintenance bundle stays offline by default' {
        $source=Join-Path $fixture 'embedded';Put-Release $source 'updates' $first
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey) $first 0
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey -Offline) $first 0
    }
    Case 'locally built signed artifacts remain usable offline' {
        $source=Join-Path $fixture 'built';Put-Release $source 'artifacts\windows-maintenance' $first
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey -Offline) $first 0
    }
    Case 'embedded pair is preferred over build artifacts' {
        $source=Join-Path $fixture 'both';Put-Release $source 'updates' $first;Put-Release $source 'artifacts\windows-maintenance' $second
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey) $first 0
    }
    Case 'partial embedded bundle does not hide a complete local build' {
        $source=Join-Path $fixture 'partial-with-build'
        Write-NcmAtomicBytes (Join-Path $source 'updates\windows-update.json') $second.envelope
        Put-Release $source 'artifacts\windows-maintenance' $first
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey -Offline) $first 0
    }
    Case 'partial local bundle is replaced as a pair in memory, without mixing versions' {
        $source=Join-Path $fixture 'partial'
        Write-NcmAtomicBytes (Join-Path $source 'updates\windows-update.json') $first.envelope
        Assert-Release (Get-NcmMaintenanceInstallRelease $source $publicKey) $second 2
        if ((Get-NcmDigest ([IO.File]::ReadAllBytes((Join-Path $source 'updates\windows-update.json')))) -cne (Get-NcmDigest $first.envelope) -or
            [IO.File]::Exists((Join-Path $source 'updates\windows-payload.zip'))) { throw 'PARTIAL_SOURCE_FILES_CHANGED' }
    }
    Case 'offline mode never mixes files from different local layouts' {
        $source=Join-Path $fixture 'split'
        Write-NcmAtomicBytes (Join-Path $source 'updates\windows-update.json') $first.envelope
        Write-NcmAtomicBytes (Join-Path $source 'artifacts\windows-maintenance\windows-payload.zip') $first.package
        Reject {Get-NcmMaintenanceInstallRelease $source $publicKey -Offline} 'NCM_MAINTENANCE_PACKAGE_MISSING' -Help
        if ($script:requests.Count) { throw 'OFFLINE_ATTEMPTED_NETWORK' }
    }
    foreach ($failure in @('manifest','payload')) {
        Case "failed $failure download explains how to obtain the complete maintenance bundle" {
            $script:downloadError=$failure
            Reject {Get-NcmMaintenanceInstallRelease (Join-Path $fixture 'network-error') $publicKey} 'NCM_MAINTENANCE_DOWNLOAD_FAILED' -Help
        }
    }
    Case 'invalid embedded signature fails without falling back to the network' {
        $source=Join-Path $fixture 'bad-local-signature';Put-Release $source 'updates' $first
        $wrapper=[Text.Encoding]::UTF8.GetString($first.envelope)|ConvertFrom-Json
        $wrapper.payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
        Write-NcmMaintenanceJson (Join-Path $source 'updates\windows-update.json') $wrapper
        Reject {Get-NcmMaintenanceInstallRelease $source $publicKey} 'NCM_UPDATE_SIGNATURE_INVALID'
        if ($script:requests.Count) { throw 'CORRUPT_BUNDLE_TRIGGERED_DOWNLOAD' }
    }
    Case 'invalid downloaded signature is rejected before fetching a payload' {
        $script:online=@{envelope=[IO.File]::ReadAllBytes((Join-Path $fixture 'bad-local-signature\updates\windows-update.json'));package=$second.package;url=$second.url}
        Reject {Get-NcmMaintenanceInstallRelease (Join-Path $fixture 'invalid-online-signature') $publicKey} 'NCM_UPDATE_SIGNATURE_INVALID'
        if ($script:requests.Count -ne 1) { throw 'UNVERIFIED_MANIFEST_TRIGGERED_PAYLOAD_DOWNLOAD' }
    }
    Case 'even a signed manifest cannot request another repository' {
        $script:online=Make-Release 102 -Url 'https://github.com/other/repo/releases/download/tag/windows-payload.zip'
        Reject {Get-NcmMaintenanceInstallRelease (Join-Path $fixture 'untrusted-url') $publicKey} 'NCM_UPDATE_MANIFEST_INVALID'
        if ($script:requests.Count -ne 1) { throw 'UNTRUSTED_URL_DOWNLOADED' }
    }
    Case 'corrupt local payload fails without downloading a replacement' {
        $source=Join-Path $fixture 'corrupt-local';Put-Release $source 'updates' $first
        Write-NcmAtomicBytes (Join-Path $source 'updates\windows-payload.zip') ([byte[]]@(1,2,3))
        Reject {Get-NcmMaintenanceInstallRelease $source $publicKey} 'NCM_UPDATE_PACKAGE_HASH_INVALID'
        if ($script:requests.Count) { throw 'CORRUPT_BUNDLE_TRIGGERED_DOWNLOAD' }
    }
    Case 'downloaded payload must match the signed length and hash' {
        $script:online=@{envelope=$second.envelope;package=([byte[]]@(1,2,3));url=$second.url}
        Reject {Get-NcmMaintenanceInstallRelease (Join-Path $fixture 'corrupt-online') $publicKey} 'NCM_UPDATE_PACKAGE_HASH_INVALID'
    }
    Case 'downloaded archive rejects undeclared and traversing entries' {
        $script:online=Make-Release 103 -Extra
        Reject {Get-NcmMaintenanceInstallRelease (Join-Path $fixture 'bad-archive') $publicKey} 'NCM_UPDATE_ARCHIVE_INVALID'
    }
    Case 'real installer bootstraps a source ZIP before reaching its machine install boundary' {
        $packet=Make-Installer 'actual source ZIP (2)'
        Reject {Run-Installer $packet} 'FIXTURE_INSTALL_READY'
        if (@([IO.File]::ReadAllLines((Join-Path $packet 'requests.txt'))).Count -ne 2 -or
            [IO.File]::Exists((Join-Path $packet 'machine files\NCMGaplessMaintenance\config.json'))) { throw 'CALLER_DID_NOT_DOWNLOAD_OR_MUTATED_INSTALLATION' }
    }
    Case 'real installer forwards offline mode and fails before changing machine state' {
        $packet=Make-Installer 'actual offline'
        Reject {Run-Installer $packet -Offline} 'NCM_MAINTENANCE_PACKAGE_MISSING' -Help
        if ([IO.File]::Exists((Join-Path $packet 'requests.txt')) -or [IO.Directory]::Exists((Join-Path $packet 'machine files'))) { throw 'OFFLINE_CALLER_DOWNLOADED_OR_MUTATED_INSTALLATION' }
    }
    Case 'real installer accepts an offline bundle without a network request' {
        $packet=Make-Installer 'actual embedded';Put-Release $packet 'updates' $first
        Reject {Run-Installer $packet -Offline} 'FIXTURE_INSTALL_READY'
        if ([IO.File]::Exists((Join-Path $packet 'requests.txt'))) { throw 'OFFLINE_CALLER_DOWNLOADED' }
    }
    Case 'real installer rejects a corrupt download before changing machine state' {
        $packet=Make-Installer 'actual corrupt download'
        Write-NcmAtomicBytes (Join-Path $packet 'feed.zip') ([byte[]]@(1,2,3))
        Reject {Run-Installer $packet} 'NCM_UPDATE_PACKAGE_HASH_INVALID'
        if ([IO.Directory]::Exists((Join-Path $packet 'machine files'))) { throw 'INVALID_DOWNLOAD_MUTATED_INSTALLATION' }
    }
    foreach ($name in @('tools\update-public-key.xml','tools\Ncm-Maintenance.ps1')) {
        Case "real installer explains missing $name before elevation or download" {
            $packet=Make-Installer ('missing '+[IO.Path]::GetFileName($name))
            [IO.File]::Delete((Join-Path $packet $name))
            Reject {Run-Installer $packet -Elevate} 'NCM_MAINTENANCE_INSTALLER_FILES_MISSING'
            if ([IO.File]::Exists((Join-Path $packet 'requests.txt'))) { throw 'INCOMPLETE_INSTALLER_DOWNLOADED' }
        }
    }
    Case 'offline mode and the spaced client path survive the elevation call' {
        $packet=Make-Installer 'actual elevation'
        Reject {Run-Installer $packet -Offline -Elevate} ('-ClientPath "'+(Join-Path $packet 'client\cloudmusic.exe')+'" -Offline')
    }
    Case 'failed elevated install includes a usable manual recovery path' {
        $packet=Make-Installer 'failed elevation'
        Reject {Run-Installer $packet -Offline -Elevate -FailElevation} 'NCM_MAINTENANCE_INSTALL_FAILED' -Help
    }
    Case 'uninstall does not require a public key or maintenance payload' {
        $packet=Make-Installer 'actual uninstall'
        [IO.File]::Delete((Join-Path $packet 'tools\update-public-key.xml'))
        [IO.File]::Delete((Join-Path $packet 'tools\Invoke-NcmMaintenance.ps1'))
        Reject {Run-Installer $packet -Uninstall -Elevate} '-Uninstall'
        if ([IO.File]::Exists((Join-Path $packet 'requests.txt'))) { throw 'UNINSTALL_ATTEMPTED_DOWNLOAD' }
    }
    Write-Host "$script:checks maintenance installer checks passed; no real client, elevation, scheduled task or network used."
} finally {
    $rsa.Dispose()
    $env:ProgramFiles=$savedProgramFiles
    foreach ($name in @('NCM_INSTALL_TEST_ROOT','NCM_INSTALL_TEST_ELEVATE','NCM_INSTALL_TEST_ELEVATION_FAIL')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
}
