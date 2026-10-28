[CmdletBinding()]
param([string]$ClientPath,[switch]$Uninstall,[switch]$MachineOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Ncm-Maintenance.ps1')
. (Join-Path $PSScriptRoot 'tools\Ncm-ClientCompatibility.ps1')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -MachineOnly' -f $PSCommandPath
    if ($ClientPath) { $arguments += ' -ClientPath "{0}"' -f $ClientPath }
    if ($Uninstall) { $arguments += ' -Uninstall' }
    $child = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($child.ExitCode) { throw 'NCM_MAINTENANCE_INSTALL_FAILED' }
    # Enablement always belongs to the caller, never an alternate elevation account.
    if (-not $Uninstall) {
        . (Join-Path $PSScriptRoot 'tools\Ncm-StartupState.ps1')
        $config = Get-Content -LiteralPath (Join-Path ${env:ProgramFiles} 'NCMGaplessMaintenance\config.json') -Raw | ConvertFrom-Json
        $enabled = Read-NcmStartupEnabled
        $token = $(if ($enabled -and $enabled.clientPath -ieq $config.clientPath) { $enabled.token } else { [Guid]::NewGuid().ToString('N') })
        Write-NcmStartupText 'enabled.txt' ("NCMG1`n$token`n$($config.clientPath)`n")
    }
    Write-Host $(if ($Uninstall) { 'Automatic maintenance removed.' } else { 'Automatic maintenance installed. Open the client normally after repair completes.' })
    return
}
$root = Join-Path ${env:ProgramFiles} 'NCMGaplessMaintenance'
$taskName = 'NCMGapless Maintenance'
$bootstrap = @('Ncm-Maintenance.ps1','Invoke-NcmMaintenance.ps1','Ncm-ClientCompatibility.ps1','Set-NcmStartupInstallation.ps1')
$existing = [IO.File]::Exists((Join-Path $root 'config.json'))
if ([IO.Directory]::Exists($root)) {
    Assert-NcmAdminDirectory $root
    if (-not $existing -or (Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json).owner -cne 'ncm-gapless-maintenance-v1') { throw 'NCM_MAINTENANCE_INSTALLATION_CONFLICT' }
}
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and (-not $existing -or $task.Actions.Arguments -cnotcontains ('-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Invoke-NcmMaintenance.ps1') + '"'))) { throw 'NCM_MAINTENANCE_TASK_CONFLICT' }
if ($Uninstall) {
    if ($existing) {
        $config=Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw|ConvertFrom-Json
        $config | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force
        Write-NcmMaintenanceJson (Join-Path $root 'config.json') $config
    }
    if ($task) {
        Disable-ScheduledTask -TaskName $taskName | Out-Null
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            if ($clock.Elapsed.TotalSeconds -gt 90) { throw 'NCM_MAINTENANCE_BUSY' }
            Start-Sleep -Milliseconds 250
        }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    # Preserve cache/receipts for diagnosis; no task or executable entry remains.
    foreach ($name in $bootstrap) { [IO.File]::Delete((Join-Path $root $name)) }
    return
}
if (-not $ClientPath) {
    $found = & (Join-Path $PSScriptRoot 'tools\Get-ClientInfo.ps1') | ConvertFrom-Json
    if ($found.discovered -ne 1) { throw 'NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENTPATH' }
    $ClientPath = $found.clients[0].path
}
$client = Assert-NcmOfficialClient $ClientPath
Assert-NcmAdminDirectory (Split-Path $client.path -Parent)
$publicKey = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tools\update-public-key.xml'))
$packageDirectory = Join-Path $PSScriptRoot 'artifacts\windows-maintenance'
if ([IO.Directory]::Exists((Join-Path $PSScriptRoot 'updates'))) { $packageDirectory=Join-Path $PSScriptRoot 'updates' }
$release = Read-NcmSignedRelease ([IO.File]::ReadAllBytes((Join-Path $packageDirectory 'windows-update.json'))) $publicKey
$package = [IO.File]::ReadAllBytes((Join-Path $packageDirectory 'windows-payload.zip'))
$null = Read-NcmReleasePayload $package $release
if ($existing) {
    $oldKey = [IO.File]::ReadAllText((Join-Path $root 'update-public-key.xml'))
    if ($oldKey -cne $publicKey) { throw 'NCM_UPDATE_KEY_CHANGE_REJECTED' }
    $state = Get-Content -LiteralPath (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
    Assert-NcmReleaseSequence $release $state
    if ($task) {
        Disable-ScheduledTask -TaskName $taskName | Out-Null
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            if ($clock.Elapsed.TotalSeconds -gt 90) { throw 'NCM_MAINTENANCE_BUSY' }
            Start-Sleep -Milliseconds 250
        }
    }
} else {
    [void][IO.Directory]::CreateDirectory($root)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($entry[0])),$entry[1],'ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    Assert-NcmAdminDirectory $root
}
$installLock=[IO.File]::Open((Join-Path $root 'maintenance.lock'),'OpenOrCreate','ReadWrite','None')
try {
foreach ($name in $bootstrap) { Write-NcmAtomicBytes (Join-Path $root $name) ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "tools\$name"))) }
Write-NcmAtomicBytes (Join-Path $root 'update-public-key.xml') ([Text.Encoding]::UTF8.GetBytes($publicKey))
$cache = Join-Path $root ('releases\' + $release.digest)
Write-NcmAtomicBytes (Join-Path $cache 'package.zip') $package
Write-NcmAtomicBytes (Join-Path $cache 'manifest.json') $release.envelope
if ($existing) {
    $current=Get-Content -LiteralPath (Join-Path $root 'active.json') -Raw|ConvertFrom-Json
    if ($current.digest -cne $release.digest) { Write-NcmMaintenanceJson (Join-Path $root 'pending.json') @{digest=$release.digest} }
    $state.highestSequence=$release.document.sequence; $state.highestDigest=$release.digest
    $state.nextCheckUtc=[DateTime]::UtcNow.ToString('o')
    Write-NcmMaintenanceJson (Join-Path $root 'state.json') $state
} else {
    Write-NcmMaintenanceJson (Join-Path $root 'active.json') @{digest=$release.digest}
    Write-NcmMaintenanceJson (Join-Path $root 'state.json') @{highestSequence=$release.document.sequence;highestDigest=$release.digest;nextCheckUtc=[DateTime]::UtcNow.ToString('o')}
}
Write-NcmMaintenanceJson (Join-Path $root 'config.json') @{owner='ncm-gapless-maintenance-v1';enabled=$true;clientPath=$client.path}
$owned = Join-Path (Split-Path $client.path -Parent) 'ncm-gapless\installation.json'
if ([IO.File]::Exists($owned)) { Write-NcmAtomicBytes (Join-Path $root 'owned.json') ([IO.File]::ReadAllBytes($owned)) }
$execute = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Invoke-NcmMaintenance.ps1') + '"'
$action = New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $root
$triggers = @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn),
    (New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) -RepetitionInterval ([TimeSpan]::FromMinutes(1))))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(3)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $taskPrincipal -Force | Out-Null
$service = New-Object -ComObject 'Schedule.Service'; $service.Connect()
$service.GetFolder('\').GetTask($taskName).SetSecurityDescriptor('D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)',0)
} finally { $installLock.Dispose() }
Start-ScheduledTask -TaskName $taskName
if (-not $MachineOnly) {
    . (Join-Path $PSScriptRoot 'tools\Ncm-StartupState.ps1')
    $enabled=Read-NcmStartupEnabled
    $token=$(if ($enabled -and $enabled.clientPath -ieq $client.path) {$enabled.token} else {[Guid]::NewGuid().ToString('N')})
    Write-NcmStartupText 'enabled.txt' ("NCMG1`n$token`n$($client.path)`n")
}
