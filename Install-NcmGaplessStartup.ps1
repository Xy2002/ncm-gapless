[CmdletBinding()]
param([string]$ClientPath, [switch]$Uninstall)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Ncm-StartupState.ps1')
. (Join-Path $PSScriptRoot 'tools\Ncm-ClientCompatibility.ps1')
if ($Uninstall) {
    $maintenanceConfig = Join-Path ${env:ProgramFiles} 'NCMGaplessMaintenance\config.json'
    if ([IO.File]::Exists($maintenanceConfig)) { & (Join-Path $PSScriptRoot 'Install-NcmGaplessMaintenance.ps1') -Uninstall }
    & (Join-Path $PSScriptRoot 'Stop-NcmGapless.ps1') | Out-Null
}
$infoScript = Join-Path $PSScriptRoot 'tools\Get-ClientInfo.ps1'
if ($ClientPath) { $found = & $infoScript -ClientPath $ClientPath | ConvertFrom-Json }
else { $found = & $infoScript | ConvertFrom-Json }
if ($found.discovered -ne 1) { throw 'NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENTPATH' }
$client = $found.clients[0]
if (-not $Uninstall) { $null = Assert-NcmOfficialClient $client.path }
$installedPath = Join-Path (Split-Path $client.path -Parent) 'ncm-gapless\installation.json'
$files = @('tools\AutoAttach-NcmGapless.ps1','tools\Ncm-StartupState.ps1','tools\Ncm-Cdp.ps1',
    'src\client-adapter.js','src\aac-timing.js','src\gapless-engine.js','src\netease-gapless.js','LICENSES\CEF.txt')
$expected = [ordered]@{}
if (-not $Uninstall) {
    $loader = Join-Path $PSScriptRoot 'native\windows\MSIMG32.dll'
    if (-not (Test-Path -LiteralPath $loader)) { throw 'NCM_STARTUP_USE_BUILT_PORTABLE_PACKAGE_OR_BUILD_NATIVE_LOADER' }
    $expected['MSIMG32.dll'] = (Get-FileHash -LiteralPath $loader -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($name in $files) { $expected[('ncm-gapless\' + $name)] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$matches = $false
if (-not $Uninstall -and (Test-Path -LiteralPath $installedPath)) {
    $installed = [IO.File]::ReadAllText($installedPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $matches = $installed.owner -ceq 'ncm-gapless-windows-startup-v1'
    foreach ($name in $expected.Keys) {
        $path = Join-Path (Split-Path $client.path -Parent) $name
        if ($installed.sha256.PSObject.Properties.Name -cnotcontains $name -or
            $installed.sha256.$name -cne $expected[$name] -or -not (Test-Path -LiteralPath $path) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected[$name]) { $matches = $false }
    }
    $drawing = Join-Path (Split-Path $client.path -Parent) 'ncm_gapless_msimg32.dll'
    if (-not (Test-Path -LiteralPath $drawing) -or (Get-FileHash -LiteralPath $drawing -Algorithm SHA256).Hash -ine $installed.sha256.'ncm_gapless_msimg32.dll') { $matches = $false }
}
if (-not $matches) {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" | Where-Object { $_.ExecutablePath -ieq $client.path })
    if ($running.Count) { throw 'NCM_EXIT_CLIENT_BEFORE_STARTUP_INSTALL' }
    Disable-NcmStartup
    $stage = Join-Path $PSScriptRoot ('.local\startup-install-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    if (-not $Uninstall) {
        foreach ($name in $expected.Keys) {
            $source = $(if ($name -ceq 'MSIMG32.dll') { $loader } else { Join-Path $PSScriptRoot $name.Substring(12) })
            $target = Join-Path $stage $name
            [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
            [IO.File]::Copy($source, $target, $true)
        }
        $manifest = [ordered]@{ owner = 'ncm-gapless-windows-startup-v1'; clientVersion = $client.version; sha256 = $expected }
        [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    }
    $resultPath = Join-Path $stage 'result.json'
    $fileScript = Join-Path $PSScriptRoot 'tools\Set-NcmStartupInstallation.ps1'
    $action = $(if ($Uninstall) { 'Uninstall' } else { 'Install' })
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        & $fileScript -ClientPath $client.path -Payload $stage -ResultPath $resultPath -Action $action
    } else {
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ClientPath "{1}" -Payload "{2}" -ResultPath "{3}" -Action {4}' -f $fileScript,$client.path,$stage,$resultPath,$action
        $child = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'NCM_STARTUP_INSTALLATION_NO_RECEIPT' }
    $result = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $result.success) { throw $result.error }
}
if ($Uninstall) { [PSCustomObject]@{ automaticEnabled = $false; startupLoaderInstalled = $false } | ConvertTo-Json; return }
$enabled = Read-NcmStartupEnabled
$token = $(if ($enabled -and $enabled.clientPath -ieq $client.path) { $enabled.token } else { [Guid]::NewGuid().ToString('N') })
Write-NcmStartupText 'enabled.txt' ("NCMG1`n$token`n$($client.path)`n")
Write-NcmStartupText 'installation.json' ([IO.File]::ReadAllText($installedPath, [Text.Encoding]::UTF8))
[PSCustomObject]@{ automaticEnabled = $true; startupLoaderInstalled = $true; helperMode = 'per-launch'; clientRestarted = $false } | ConvertTo-Json
Write-Host 'Installed. Open NetEase Cloud Music normally; the patch will load automatically.'
