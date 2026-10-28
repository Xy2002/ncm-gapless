# Real signature/ZIP/worker/install I/O; fixture client is never executed.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'tools\Ncm-Maintenance.ps1')
$fixture=Join-Path $repository ('.local\maintenance-test-'+[Guid]::NewGuid().ToString('N'))
$root=Join-Path $fixture 'worker'; $clientRoot=Join-Path $fixture 'client'; $feed=Join-Path $fixture 'feed'
foreach ($path in @($root,$clientRoot,$feed)) { [void][IO.Directory]::CreateDirectory($path) }
$client=Join-Path $clientRoot 'cloudmusic.exe'; [IO.File]::WriteAllText($client,'fixture, never executed')
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(3072); $rsa.PersistKeyInCsp=$false
function Make-Release([long]$Sequence,[string]$Marker,[switch]$Extra) {
    $stream=New-Object IO.MemoryStream
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    $files=[ordered]@{}
    try {
        foreach ($name in $script:NcmReleaseFiles) {
            $bytes=[Text.Encoding]::UTF8.GetBytes("fixture $name $Marker")
            $files[$name]=@{sha256=(Get-NcmDigest $bytes);bytes=$bytes.Length}
            $output=$zip.CreateEntry($name).Open(); try { $output.Write($bytes,0,$bytes.Length) } finally { $output.Dispose() }
        }
        if ($Extra) { $null=$zip.CreateEntry('../escape.txt') }
    } finally { $zip.Dispose() }
    $package=$stream.ToArray(); $stream.Dispose()
    $doc=[ordered]@{schema=1;channel='windows-maintenance';sequence=$Sequence;version='0.5.0-experimental';
        package=@{url=($script:NcmAssetPrefix+'fixture-'+$Sequence+'/windows-payload.zip');bytes=$package.Length;sha256=(Get-NcmDigest $package)};files=$files}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($doc|ConvertTo-Json -Depth 8 -Compress))
    $envelope=[Text.Encoding]::UTF8.GetBytes((@{payload=[Convert]::ToBase64String($bytes);signature=[Convert]::ToBase64String($rsa.SignData($bytes,'SHA256'))}|ConvertTo-Json))
    return @{envelope=$envelope;package=$package;release=(Read-NcmSignedRelease $envelope $rsa.ToXmlString($false))}
}
function Reject([scriptblock]$Action,[string]$Code) {
    try { &$Action; throw 'TEST_EXPECTED_REJECTION' } catch { if ($_.ToString() -notmatch $Code) { throw } }
    Write-Host "PASS $Code"
}
Add-Type -AssemblyName System.IO.Compression
try {
    $first=Make-Release 100 'first'
    $null=Read-NcmReleasePayload $first.package $first.release
    Write-Host 'PASS signed complete release'
    $wrapper=[Text.Encoding]::UTF8.GetString($first.envelope)|ConvertFrom-Json
    $wrapper.payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
    Reject {Read-NcmSignedRelease ([Text.Encoding]::UTF8.GetBytes(($wrapper|ConvertTo-Json))) $rsa.ToXmlString($false)} 'NCM_UPDATE_SIGNATURE_INVALID'
    Reject {Read-NcmReleasePayload ([byte[]]@(1,2)) $first.release} 'NCM_UPDATE_PACKAGE_HASH_INVALID'
    $extra=Make-Release 101 'bad' -Extra
    Reject {Read-NcmReleasePayload $extra.package $extra.release} 'NCM_UPDATE_ARCHIVE_INVALID'
    Reject {Assert-NcmReleaseSequence $first.release @{highestSequence=101;highestDigest='other'}} 'NCM_UPDATE_ROLLBACK_REJECTED'
    Reject {Assert-NcmReleaseSequence $first.release @{highestSequence=100;highestDigest='other'}} 'NCM_UPDATE_ROLLBACK_REJECTED'
    foreach ($name in @('Ncm-Maintenance.ps1','Invoke-NcmMaintenance.ps1','Set-NcmStartupInstallation.ps1')) { [IO.File]::Copy((Join-Path $repository "tools\$name"),(Join-Path $root $name)) }
    $mocks=@'
function Assert-NcmOfficialClient($ClientPath) { return @{path=$ClientPath;version='3.2.0.999999'} }
function Assert-NcmAdminDirectory($Path) {}
function Get-CimInstance {
    param($ClassName,$Filter)
    if ($ClassName -ne 'Win32_Process') { return }
    if ($env:NCM_FIXTURE_LAUNCH_RACE) {
        if ([IO.File]::Exists($env:NCM_FIXTURE_LAUNCH_RACE)) { return @{ExecutablePath=$env:NCM_FIXTURE_CLIENT} }
        [IO.File]::WriteAllText($env:NCM_FIXTURE_LAUNCH_RACE,'client starts after first query')
        return
    }
    if ($env:NCM_FIXTURE_RUNNING -eq '1') { return @{ExecutablePath=$env:NCM_FIXTURE_CLIENT} }
}
function Get-NcmHttpsBytes($Url,$MaximumBytes) {
    if ($env:NCM_FIXTURE_OFFLINE -eq '1') { throw 'NCM_FIXTURE_OFFLINE' }
    return ,[IO.File]::ReadAllBytes((Join-Path $env:NCM_FIXTURE_FEED $(if ($Url.EndsWith('.json')) {'feed.json'}else{'feed.zip'})))
}
function Get-NcmActivationHealth($ClientPath,$Digest) {
    if ($env:NCM_FIXTURE_RAPID -eq '1') { return [PSCustomObject]@{clientPath=$ClientPath;runtimeDigest=$Digest;processId=3;startedFileTime='1';result='failed';error='NCM_STARTUP_ATTACH_FAILED';failedInstances=@('1:1','2:1','3:1')} }
    if ($env:NCM_FIXTURE_FAILURE) { return @{clientPath=$ClientPath;runtimeDigest=$Digest;processId=[int]$env:NCM_FIXTURE_FAILURE;startedFileTime='1';result='failed';error='NCM_STARTUP_ATTACH_FAILED'} }
}
'@
    [IO.File]::WriteAllText((Join-Path $root 'Ncm-ClientCompatibility.ps1'),$mocks)
    Write-NcmAtomicBytes (Join-Path $root 'update-public-key.xml') ([Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($false)))
    Write-NcmMaintenanceJson (Join-Path $root 'config.json') @{owner='ncm-gapless-maintenance-v1';clientPath=$client}
    Write-NcmMaintenanceJson (Join-Path $root 'state.json') @{highestSequence=100;highestDigest=$first.release.digest;nextCheckUtc='2000-01-01T00:00:00Z'}
    Write-NcmMaintenanceJson (Join-Path $root 'active.json') @{digest=$first.release.digest}
    $cache=Join-Path $root ('releases\'+$first.release.digest)
    Write-NcmAtomicBytes (Join-Path $cache 'package.zip') $first.package
    Write-NcmAtomicBytes (Join-Path $cache 'manifest.json') $first.envelope
    $env:NCM_FIXTURE_FEED=$feed; $env:NCM_FIXTURE_CLIENT=$client
    function Publish($Release) {
        Write-NcmAtomicBytes (Join-Path $feed 'feed.json') $Release.envelope
        Write-NcmAtomicBytes (Join-Path $feed 'feed.zip') $Release.package
    }
    function Run-Worker {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Invoke-NcmMaintenance.ps1') -CheckNow
        if ($LASTEXITCODE) { throw 'WORKER_FAILED' }
        return (Get-Content -LiteralPath (Join-Path $root 'status.json') -Raw|ConvertFrom-Json)
    }
    Publish $first
    $status=Run-Worker
    if ($status.result -cne 'repaired') { throw ($status|ConvertTo-Json) }
    Write-Host 'PASS worker installs only signed cached runtime, preserving fixture client'
    $env:NCM_FIXTURE_RUNNING='1'
    [IO.File]::Delete((Join-Path $clientRoot 'MSIMG32.dll'))
    $status=Run-Worker
    if ($status.result -cne 'deferred-client-running' -or [IO.File]::Exists((Join-Path $clientRoot 'MSIMG32.dll'))) { throw 'DID_NOT_DEFER' }
    $env:NCM_FIXTURE_RUNNING='0'; $env:NCM_FIXTURE_OFFLINE='1'
    [IO.File]::Delete((Join-Path $clientRoot 'ncm-gapless\installation.json'))
    $status=Run-Worker
    if ($status.result -cne 'repaired' -or -not [IO.File]::Exists((Join-Path $clientRoot 'MSIMG32.dll'))) { throw ($status|ConvertTo-Json) }
    Write-Host 'PASS running client is untouched; offline repair restores missing loader and ownership manifest'
    $env:NCM_FIXTURE_OFFLINE='0'
    $counter=Get-Content -LiteralPath (Join-Path $root 'state.json') -Raw|ConvertFrom-Json
    $counter|Add-Member -NotePropertyName failureCount -NotePropertyValue 2 -Force
    $counter|Add-Member -NotePropertyName failureDigest -NotePropertyValue $first.release.digest -Force
    Write-NcmMaintenanceJson (Join-Path $root 'state.json') $counter
    $second=Make-Release 101 'second'; Publish $second
    $env:NCM_FIXTURE_LAUNCH_RACE=Join-Path $fixture 'launch-race.txt'
    $status=Run-Worker
    $raceState=Get-Content -LiteralPath (Join-Path $root 'state.json') -Raw|ConvertFrom-Json
    if ($status.result -cne 'deferred-client-running' -or -not [IO.File]::Exists((Join-Path $root 'pending.json')) -or
        ($raceState.PSObject.Properties.Name -contains 'rejectedDigest' -and $raceState.rejectedDigest -ceq $second.release.digest)) { throw 'LAUNCH_RACE_QUARANTINED_VALID_UPDATE' }
    $env:NCM_FIXTURE_LAUNCH_RACE=$null
    Write-Host 'PASS late client startup retains the signed pending release for retry'
    $status=Run-Worker
    if ($status.result -cne 'updated' -or (Get-Content -LiteralPath (Join-Path $root 'active.json') -Raw|ConvertFrom-Json).digest -cne $second.release.digest) { throw ($status|ConvertTo-Json) }
    if ((Get-Content -LiteralPath (Join-Path $root 'previous.json') -Raw|ConvertFrom-Json).digest -cne $first.release.digest) { throw 'PREVIOUS_MISSING' }
    Write-Host 'PASS signed update activates transactionally and retains previous release'
    [IO.File]::WriteAllText((Join-Path $clientRoot 'ncm-gapless\active.txt'),$first.release.digest)
    $status=Run-Worker
    if ($status.result -cne 'repaired') { throw 'INTERRUPTED_POINTER_NOT_RECONCILED' }
    $torn=Get-Content -LiteralPath (Join-Path $clientRoot 'ncm-gapless\installation.json') -Raw|ConvertFrom-Json
    $torn.sha256.'MSIMG32.dll'=$first.release.document.files.'MSIMG32.dll'.sha256
    Write-NcmMaintenanceJson (Join-Path $clientRoot 'ncm-gapless\installation.json') $torn
    $status=Run-Worker
    if ($status.result -cne 'repaired') { throw 'INTERRUPTED_LOADER_NOT_RECONCILED' }
    Write-Host 'PASS interrupted pointer/manifest and proxy/manifest transactions reconcile only to verified bytes'
    for ($i=1;$i -le 3;$i++) {
        $env:NCM_FIXTURE_FAILURE=$i.ToString(); $status=Run-Worker
        if ($i -lt 3 -and $status.result -ceq 'rolled-back') { throw 'FAILURE_COUNT_LEAKED_BETWEEN_RELEASES' }
    }
    $env:NCM_FIXTURE_FAILURE=$null
    if ($status.result -cne 'rolled-back' -or (Get-Content -LiteralPath (Join-Path $root 'state.json') -Raw|ConvertFrom-Json).highestSequence -ne 101) { throw ($status|ConvertTo-Json) }
    $status=Run-Worker
    if ($status.error -cne 'NCM_UPDATE_QUARANTINED' -or $status.result -cne 'healthy') { throw ($status|ConvertTo-Json) }
    Write-Host 'PASS three distinct failed starts trigger signed cached rollback; bad release is quarantined without reducing highest sequence'
    Write-NcmMaintenanceJson (Join-Path $root 'pending.json') @{digest=$second.release.digest}
    $third=Make-Release 102 'third'; Publish $third
    [IO.File]::WriteAllText((Join-Path $feed 'feed.zip'),'corrupt download')
    [IO.File]::Delete((Join-Path $clientRoot 'MSIMG32.dll'))
    $status=Run-Worker
    if ($status.result -cne 'repaired' -or $status.error -cne 'NCM_UPDATE_PENDING_REJECTED') { throw ($status|ConvertTo-Json) }
    Write-Host 'PASS stale pending and failed newer download do not block cached active repair'
    $fourth=Make-Release 103 'rapid-health';Publish $fourth
    $status=Run-Worker
    if ($status.result -cne 'updated') { throw 'RAPID_ROLLBACK_SETUP_FAILED' }
    $env:NCM_FIXTURE_RAPID='1';$status=Run-Worker;$env:NCM_FIXTURE_RAPID=$null
    if ($status.result -cne 'rolled-back') { throw 'RAPID_FAILURES_REQUIRE_EXTRA_MAINTENANCE_POLLS' }
    Write-Host 'PASS one maintenance poll consumes three distinct durable failed starts'
    Publish $first
    $status=Run-Worker
    if ($status.error -cne 'NCM_UPDATE_ROLLBACK_REJECTED' -or $status.result -cne 'healthy') { throw ($status|ConvertTo-Json) }
    Write-Host 'PASS replayed signed downgrade leaves current runtime intact'
    Publish $second
    [IO.File]::WriteAllText((Join-Path $clientRoot 'MSIMG32.dll'),'foreign')
    $status=Run-Worker
    if ($status.result -cne 'failed' -or [IO.File]::ReadAllText((Join-Path $clientRoot 'MSIMG32.dll')) -cne 'foreign') { throw 'FOREIGN_FILE_OVERWRITTEN' }
    Write-Host 'PASS conflicting loader is preserved'
    if ([IO.File]::ReadAllText($client) -cne 'fixture, never executed') { throw 'CLIENT_CHANGED' }
    $config=Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw|ConvertFrom-Json
    $config|Add-Member -NotePropertyName enabled -NotePropertyValue $false
    Write-NcmMaintenanceJson (Join-Path $root 'config.json') $config
    [IO.File]::Delete((Join-Path $clientRoot 'MSIMG32.dll'))
    $status=Run-Worker
    if ($status.result -cne 'disabled' -or [IO.File]::Exists((Join-Path $clientRoot 'MSIMG32.dll'))) { throw 'UNINSTALL_REINSTALLED_PATCH' }
    Write-Host 'PASS revoked machine maintenance cannot reinstall a removed startup loader'
    $stage=Join-Path $root 'stage'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Set-NcmStartupInstallation.ps1') -ClientPath $client -Payload $stage -ResultPath (Join-Path $stage 'result.json') -Action Uninstall
    if ($LASTEXITCODE) { throw 'VERSIONED_UNINSTALL_FAILED' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Set-NcmStartupInstallation.ps1') -ClientPath $client -Payload $stage -ResultPath (Join-Path $stage 'result.json') -Repair -RuntimeDigest $first.release.digest
    if ($LASTEXITCODE) { throw 'VERSIONED_REINSTALL_FAILED' }
    Write-Host 'PASS versioned physical uninstall and reinstall preserve old caches without blocking installation'
    Write-Host '18 maintenance security and worker checks passed; no real client, scheduled task or network used.'
} finally {
    $rsa.Dispose()
    foreach ($name in @('NCM_FIXTURE_RUNNING','NCM_FIXTURE_OFFLINE','NCM_FIXTURE_FEED','NCM_FIXTURE_CLIENT','NCM_FIXTURE_FAILURE','NCM_FIXTURE_LAUNCH_RACE','NCM_FIXTURE_RAPID')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
}
