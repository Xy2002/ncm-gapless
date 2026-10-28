# Exercise the real top-level command and setter on a fake, never-executed client.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'tools\Ncm-StartupState.ps1')
$fixture=Join-Path $repository ('.local\reenable-'+[Guid]::NewGuid().ToString('N'))
$packet=Join-Path $fixture 'packet';$target=Join-Path $fixture 'client';$payload=Join-Path $fixture 'payload'
foreach ($dir in @($packet,$target,$payload,(Join-Path $packet 'tools'),(Join-Path $packet 'native\windows'))) { [void][IO.Directory]::CreateDirectory($dir) }
$clientPath=Join-Path $target 'cloudmusic.exe';[IO.File]::WriteAllText($clientPath,'never executed')
$savedLocal=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Join-Path $fixture 'profile'
$env:NCM_REENABLE_PACKET=$packet;$env:NCM_REENABLE_CLIENT=$clientPath
try {
    $names=@('tools\AutoAttach-NcmGapless.ps1','tools\Ncm-StartupState.ps1','tools\Ncm-Cdp.ps1','src\client-adapter.js','src\aac-timing.js','src\gapless-engine.js','src\netease-gapless.js','LICENSES\CEF.txt')
    foreach ($name in $names) {
        $path=Join-Path $packet $name;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        if ($name -eq 'tools\Ncm-StartupState.ps1') { [IO.File]::Copy((Join-Path $repository $name),$path) }
        elseif ($name -eq 'tools\Ncm-Cdp.ps1') { [IO.File]::WriteAllText($path,"function Find-NcmPort { throw 'NCM_NOT_RUNNING' }") }
        else { [IO.File]::WriteAllText($path,"// fixture $name") }
    }
    foreach ($name in @('Install-NcmGaplessStartup.ps1','Stop-NcmGapless.ps1')) { [IO.File]::Copy((Join-Path $repository $name),(Join-Path $packet $name)) }
    [IO.File]::Copy((Join-Path $repository 'tools\Set-NcmStartupInstallation.ps1'),(Join-Path $packet 'tools\Set-NcmStartupInstallation.ps1'))
    [IO.File]::WriteAllText((Join-Path $packet 'native\windows\MSIMG32.dll'),'fixture DLL, never loaded')
    $mocks=@'
function Assert-NcmOfficialClient($ClientPath) { return @{path=$ClientPath;version='3.2.0.999999'} }
function Get-CimInstance {
    param($ClassName,$Filter)
    if ($env:NCM_REENABLE_NO_SCAN -eq '1') { throw 'REVIEW_UNEXPECTED_PROCESS_SCAN' }
}
function Start-Process {
    param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru)
    if ($env:NCM_REENABLE_NO_SCAN -eq '1') { throw 'REVIEW_UNEXPECTED_ELEVATION' }
    if ($ArgumentList -notmatch ' -Repair') { throw 'VERSIONED_CONVERSION_MUST_ALLOW_ABSENT_LEGACY_FILES' }
    if ($ArgumentList -notmatch '-Payload "([^"]+)"') { throw 'FIXTURE_PAYLOAD_MISSING' }
    $stage=$Matches[1]
    & (Join-Path $env:NCM_REENABLE_PACKET 'tools\Set-NcmStartupInstallation.ps1') -ClientPath $env:NCM_REENABLE_CLIENT -Payload $stage -ResultPath (Join-Path $stage 'result.json') -Repair
    return [PSCustomObject]@{ExitCode=0}
}
'@
    [IO.File]::WriteAllText((Join-Path $packet 'tools\Ncm-ClientCompatibility.ps1'),$mocks)
    $info=@'
param($ClientPath)
@{discovered=1;clients=@(@{path=$ClientPath;version='3.2.0.999999'})}|ConvertTo-Json -Depth 4
'@
    [IO.File]::WriteAllText((Join-Path $packet 'tools\Get-ClientInfo.ps1'),$info)
    $hashes=[ordered]@{}
    foreach ($name in @('MSIMG32.dll')+@($names|ForEach-Object {'ncm-gapless\'+$_})) {
        $source=Join-Path $packet $(if ($name -eq 'MSIMG32.dll') {'native\windows\MSIMG32.dll'}else{$name.Substring(12)})
        $path=Join-Path $payload $name;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::Copy($source,$path)
        $hashes[$name]=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
    [IO.File]::WriteAllText((Join-Path $payload 'manifest.json'),(@{owner='ncm-gapless-windows-startup-v1';clientVersion='3.2.0.999999';sha256=$hashes}|ConvertTo-Json -Depth 6))
    $setter=Join-Path $packet 'tools\Set-NcmStartupInstallation.ps1'
    & $setter -ClientPath $clientPath -Payload $payload -ResultPath (Join-Path $payload 'result.json') -RuntimeDigest ('d'*64)
    foreach ($name in $names) { if ([IO.File]::Exists((Join-Path $target ('ncm-gapless\'+$name)))) { throw 'FIXTURE_HAS_UNEXPECTED_LEGACY_RUNTIME' } }
    $env:NCM_REENABLE_NO_SCAN='1'
    & (Join-Path $packet 'Install-NcmGaplessStartup.ps1') -ClientPath $clientPath|Out-Null
    & (Join-Path $packet 'Stop-NcmGapless.ps1')|Out-Null
    if (Read-NcmStartupEnabled) { throw 'STOP_DID_NOT_REVOKE' }
    & (Join-Path $packet 'Install-NcmGaplessStartup.ps1') -ClientPath $clientPath|Out-Null
    if (-not (Read-NcmStartupEnabled)) { throw 'VERSIONED_REENABLE_FAILED' }
    Write-Host 'PASS fresh versioned install re-enables through the real command without copying or restarting'
    $env:NCM_REENABLE_NO_SCAN='0'
    [IO.File]::AppendAllText((Join-Path $packet 'src\client-adapter.js'),'// newer standalone')
    & (Join-Path $packet 'Install-NcmGaplessStartup.ps1') -ClientPath $clientPath|Out-Null
    if ([IO.File]::Exists((Join-Path $target 'ncm-gapless\active.txt'))) { throw 'STALE_VERSION_POINTER_RETAINED' }
    $manifest=Get-Content -LiteralPath (Join-Path $target 'ncm-gapless\installation.json') -Raw|ConvertFrom-Json
    if ($manifest.PSObject.Properties.Name -contains 'runtime') { throw 'STANDALONE_CONVERSION_NOT_COMMITTED' }
    if ((Get-FileHash -LiteralPath (Join-Path $target 'ncm-gapless\src\client-adapter.js')).Hash -ne (Get-FileHash -LiteralPath (Join-Path $packet 'src\client-adapter.js')).Hash) { throw 'STANDALONE_CODE_NOT_ACTIVATED' }
    Write-Host 'PASS standalone conversion switches away from the old immutable runtime'
    $env:NCM_REENABLE_NO_SCAN='1'
    & (Join-Path $packet 'Stop-NcmGapless.ps1')|Out-Null
    & (Join-Path $packet 'Install-NcmGaplessStartup.ps1') -ClientPath $clientPath|Out-Null
    if (-not (Read-NcmStartupEnabled)) { throw 'STANDALONE_REENABLE_FAILED' }
    Write-Host 'PASS converted standalone installation re-enables without file operations'
    Write-Host '3 top-level re-enable and mode-conversion checks passed on isolated files.'
} finally {
    $env:LOCALAPPDATA=$savedLocal
    foreach ($name in @('NCM_REENABLE_PACKET','NCM_REENABLE_CLIENT','NCM_REENABLE_NO_SCAN')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
}
