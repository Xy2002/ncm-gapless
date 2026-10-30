# Exercise the actual caller UI with a controlled elevation/worker boundary.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repository ('.local\maintenance-setup-'+[Guid]::NewGuid().ToString('N'))
$savedProgramFiles=$env:ProgramFiles;$savedLocalAppData=$env:LOCALAPPDATA
$checks=0
function Make-Packet([string]$Scenario) {
    $packet=Join-Path $fixture $Scenario
    if ($Scenario -eq 'unicode') { $packet+=('-'+[char]0x4e91+[char]0x97f3) }
    foreach ($name in @('tools','client')) { [void][IO.Directory]::CreateDirectory((Join-Path $packet $name)) }
    foreach ($name in @('Install-NcmGaplessMaintenance.ps1','tools\Ncm-Maintenance.ps1','tools\Ncm-StartupState.ps1')) {
        [IO.File]::Copy((Join-Path $repository $name),(Join-Path $packet $name))
    }
    foreach ($name in @('Get-ClientInfo.ps1','Invoke-NcmMaintenance.ps1','Set-NcmStartupInstallation.ps1','update-public-key.xml')) {
        [IO.File]::WriteAllText((Join-Path $packet "tools\$name"),'fixture, not executed')
    }
    [IO.File]::WriteAllText((Join-Path $packet 'client\cloudmusic.exe'),'fixture, never executed')
    $mocks=@'
function New-Object {
    param([string]$TypeName,[object[]]$ArgumentList,[string]$ComObject)
    if ($ComObject -eq 'Schedule.Service') {
        $service=[PSCustomObject]@{}
        $service|Add-Member ScriptMethod Connect {}
        $service|Add-Member ScriptMethod GetFolder {param($Path) return $this}
        $service|Add-Member ScriptMethod GetTask {param($Name) return $this}
        $service|Add-Member ScriptMethod SetSecurityDescriptor {param($Descriptor,$Flags)}
        return $service
    }
    if ($TypeName -eq 'Security.Principal.WindowsPrincipal') {
        $principal=[PSCustomObject]@{}
        $principal|Add-Member ScriptMethod IsInRole {param($Role) return ($env:NCM_SETUP_SCENARIO -in @('administrator','machine-only'))}
        return $principal
    }
    return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Assert-NcmOfficialClient($ClientPath) { return @{path=$ClientPath;version='3.1.42.205594'} }
function Assert-NcmAdminDirectory($Path) {}
function Get-ScheduledTask { [CmdletBinding()]param($TaskName) }
function Set-Acl { param($LiteralPath,$AclObject) }
function Get-NcmMaintenanceInstallRelease {
    param($SourceRoot,$PublicKey,[switch]$Offline)
    return @{release=@{digest=('a'*64);envelope=([byte[]]@(1));document=@{sequence=100}};package=([byte[]]@(2))}
}
function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) return @{Execute=$Execute;Arguments=$Argument} }
function New-ScheduledTaskTrigger { param([switch]$AtStartup,[switch]$AtLogOn,[switch]$Once,$At,$RepetitionInterval) return @{} }
function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$Hidden) return @{} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) return @{} }
function Register-ScheduledTask {
    param($TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force)
    [IO.File]::WriteAllText((Join-Path $env:NCM_SETUP_PACKET 'registered.txt'),'fixture task, never registered with Windows')
}
function Start-ScheduledTask {
    param($TaskName)
    $config=Get-Content -LiteralPath (Join-Path $env:ProgramFiles 'NCMGaplessMaintenance\config.json') -Raw|ConvertFrom-Json
    Write-FixtureSetupResult 'repaired' $config.installationId ''
}
function Get-CimInstance {
    param($ClassName,$Filter)
    $counter=Join-Path $env:NCM_SETUP_PACKET 'probes.txt'
    $count=$(if ([IO.File]::Exists($counter)) {[int][IO.File]::ReadAllText($counter)} else {0})
    [IO.File]::WriteAllText($counter,($count+1).ToString())
    if ($env:NCM_SETUP_SCENARIO -eq 'client-timeout' -or ($env:NCM_SETUP_SCENARIO -eq 'client-exits' -and $count -eq 0)) {
        return [PSCustomObject]@{ExecutablePath=(Join-Path $env:NCM_SETUP_PACKET 'client\cloudmusic.exe')}
    }
}
function Write-FixtureSetupResult([string]$Result,[string]$Id,[string]$ErrorCode) {
    Write-NcmMaintenanceJson (Join-Path $env:ProgramFiles 'NCMGaplessMaintenance\setup-result.json') @{
        installationId=$Id;result=$Result;error=$ErrorCode;checkedUtc=[DateTime]::UtcNow.ToString('o');version='0.5.0-experimental'}
}
function Start-Process {
    param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru)
    if ($Verb -ne 'RunAs' -or $FilePath -notmatch 'powershell.exe$') { throw 'UNEXPECTED_PROCESS_LAUNCH' }
    [IO.File]::WriteAllText((Join-Path $env:NCM_SETUP_PACKET 'elevated.txt'),$ArgumentList)
    if ($ArgumentList -match '-Uninstall') { return [PSCustomObject]@{ExitCode=0} }
    $id=$(if ($ArgumentList -match '-InstallationId ([0-9a-f]{32})') {$Matches[1]} else {'b'*32})
    $root=Join-Path $env:ProgramFiles 'NCMGaplessMaintenance'
    Write-NcmMaintenanceJson (Join-Path $root 'config.json') @{owner='ncm-gapless-maintenance-v1';enabled=$true;clientPath=(Join-Path $env:NCM_SETUP_PACKET 'client\cloudmusic.exe');installationId=$id}
    switch ($env:NCM_SETUP_SCENARIO) {
        'failed' { Write-FixtureSetupResult 'failed' $id 'NCM_FIXTURE_REPAIR_FAILED' }
        'stale-only' { Write-FixtureSetupResult 'healthy' ('c'*32) '' }
        'stale-then-ready' { Write-FixtureSetupResult 'healthy' ('c'*32) '' }
        'warning' { Write-FixtureSetupResult 'healthy' $id 'NCM_UPDATE_CHECK_FAILED' }
        'disabled' { Write-NcmMaintenanceJson (Join-Path $root 'config.json') @{owner='ncm-gapless-maintenance-v1';enabled=$false;clientPath=(Join-Path $env:NCM_SETUP_PACKET 'client\cloudmusic.exe');installationId=$id} }
        'wrong-owner' { Write-NcmMaintenanceJson (Join-Path $root 'config.json') @{owner='foreign';enabled=$true;clientPath=(Join-Path $env:NCM_SETUP_PACKET 'client\cloudmusic.exe');installationId=$id} }
        'changed' {
            Write-FixtureSetupResult 'healthy' $id ''
            Write-NcmMaintenanceJson (Join-Path $root 'config.json') @{owner='ncm-gapless-maintenance-v1';enabled=$true;clientPath=(Join-Path $env:NCM_SETUP_PACKET 'client\cloudmusic.exe');installationId=('d'*32)}
        }
        default { Write-FixtureSetupResult 'deferred-client-running' $id '' }
    }
    return [PSCustomObject]@{ExitCode=0}
}
function Start-Sleep {
    param($Milliseconds)
    $root=Join-Path $env:ProgramFiles 'NCMGaplessMaintenance'
    if ([IO.File]::Exists((Join-Path $root 'config.json'))) {
        [IO.File]::AppendAllText((Join-Path $env:NCM_SETUP_PACKET 'polls.txt'),"poll`n")
        $config=Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw|ConvertFrom-Json
        if ($env:NCM_SETUP_SCENARIO -in @('client-exits','closed','stale-then-ready','unicode')) { Write-FixtureSetupResult 'repaired' $config.installationId '' }
        if ($env:NCM_SETUP_SCENARIO -eq 'missing-config') {
            Write-FixtureSetupResult 'healthy' $config.installationId ''
            [IO.File]::Delete((Join-Path $root 'config.json'))
        }
    }
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 10
}
'@
    [IO.File]::WriteAllText((Join-Path $packet 'tools\Ncm-ClientCompatibility.ps1'),$mocks)
    return $packet
}
function Run-Setup([string]$Scenario,[switch]$Uninstall,[switch]$MachineOnly) {
    $packet=Make-Packet $Scenario
    $env:NCM_SETUP_PACKET=$packet;$env:NCM_SETUP_SCENARIO=$Scenario
    $env:ProgramFiles=Join-Path $packet 'machine';$env:LOCALAPPDATA=Join-Path $packet 'profile'
    $scriptPath=Join-Path $packet 'Install-NcmGaplessMaintenance.ps1'
    $extra=@{}
    # Permit the pre-fix script to reach its actual premature-success path.
    if ((Get-Command $scriptPath).Parameters.ContainsKey('WaitTimeoutSeconds')) { $extra.WaitTimeoutSeconds=1 }
    if ($MachineOnly) { $extra.MachineOnly=$true;$extra.InstallationId='1234567890abcdef1234567890abcdef' }
    $log=New-Object 'System.Collections.Generic.List[string]'
    $failure=$null
    try { & $scriptPath -ClientPath (Join-Path $packet 'client\cloudmusic.exe') -Uninstall:$Uninstall @extra *>&1|ForEach-Object {$log.Add($_.ToString())} }
    catch { $failure=$_.ToString() }
    return @{packet=$packet;error=$failure;text=($log -join "`n")}
}
function Check([string]$Name,[scriptblock]$Action) { &$Action;$script:checks++;Write-Host "PASS $Name" }
function Expect-Failure($Result,[string]$Code) {
    if (-not $Result.error -or $Result.error -notmatch $Code -or $Result.text -match '\[3/3\]') { throw "EXPECTED $Code without a ready message; error=$($Result.error); output=$($Result.text)" }
}
try {
    Check 'deferred first repair cannot be reported as installation success' {
        $result=Run-Setup 'deferred-timeout'
        if (-not $result.error) { throw 'INSTALLER_RETURNED_SUCCESS_WHILE_FIRST_REPAIR_WAS_DEFERRED' }
        Expect-Failure $result 'NCM_MAINTENANCE_SETUP_PENDING'
    }
    Check 'running client must exit before elevation; current repair then permits opening' {
        $result=Run-Setup 'client-exits'
        if ($result.error -or $result.text -notmatch '\[3/3\]' -or [int][IO.File]::ReadAllText((Join-Path $result.packet 'probes.txt')) -lt 2) { throw "CLIENT_EXIT_OR_READY_FLOW_FAILED $($result.error) $($result.text)" }
        if ($result.text.IndexOf('[1/3]') -ge $result.text.IndexOf('[2/3]') -or $result.text.IndexOf('[2/3]') -ge $result.text.IndexOf('[3/3]')) { throw 'SETUP_STAGES_OUT_OF_ORDER' }
    }
    Check 'an already closed client proceeds directly to the initial repair' {
        $result=Run-Setup 'closed'
        if ($result.error -or $result.text -notmatch '\[3/3\]') { throw "CLOSED_CLIENT_SETUP_FAILED $($result.error)" }
    }
    Check 'UTF-8 configuration preserves a non-ASCII client path through elevation' {
        $result=Run-Setup 'unicode'
        if ($result.error -or $result.text -notmatch '\[3/3\]') { throw "UNICODE_SETUP_FAILED $($result.error)" }
        $enabled=[IO.File]::ReadAllText((Join-Path $result.packet 'profile\NCMGapless\startup\enabled.txt'),[Text.Encoding]::UTF8)
        if (-not $enabled.Contains((Join-Path $result.packet 'client\cloudmusic.exe'))) { throw 'UNICODE_ENABLED_PATH_CHANGED' }
    }
    Check 'administrator entry waits for the receipt written for its real configuration' {
        $result=Run-Setup 'administrator'
        if ($result.error -or $result.text -notmatch '\[3/3\]' -or -not [IO.File]::Exists((Join-Path $result.packet 'registered.txt')) -or
            [IO.File]::Exists((Join-Path $result.packet 'elevated.txt'))) { throw "ADMINISTRATOR_SETUP_FAILED $($result.error)" }
    }
    Check 'internal machine-only entry registers the requested operation without a premature ready message' {
        $result=Run-Setup 'machine-only' -MachineOnly
        if ($result.error -or $result.text -match '\[\d/3\]' -or [IO.File]::Exists((Join-Path $result.packet 'probes.txt'))) { throw "MACHINE_ONLY_FLOW_FAILED $($result.error)" }
        $config=Get-Content -LiteralPath (Join-Path $result.packet 'machine\NCMGaplessMaintenance\config.json') -Raw|ConvertFrom-Json
        if ($config.installationId -cne '1234567890abcdef1234567890abcdef') { throw 'INSTALLATION_ID_NOT_PRESERVED' }
    }
    Check 'client-exit timeout does not register or claim a finished installation' {
        $result=Run-Setup 'client-timeout';Expect-Failure $result 'NCM_MAINTENANCE_CLIENT_EXIT_TIMEOUT'
        if ([IO.File]::Exists((Join-Path $result.packet 'elevated.txt'))) { throw 'ELEVATION_BEFORE_CLIENT_EXIT' }
    }
    Check 'old successful receipt is rejected until a current repair completes' {
        $result=Run-Setup 'stale-then-ready'
        if ($result.error -or -not [IO.File]::Exists((Join-Path $result.packet 'polls.txt')) -or $result.text -notmatch '\[3/3\]') { throw 'STALE_SUCCESS_ACCEPTED' }
    }
    Check 'old successful receipt alone times out without a ready message' {
        Expect-Failure (Run-Setup 'stale-only') 'NCM_MAINTENANCE_SETUP_PENDING'
    }
    Check 'fresh failed repair reports the error without claiming success' {
        Expect-Failure (Run-Setup 'failed') 'NCM_FIXTURE_REPAIR_FAILED'
    }
    Check 'replacement installation cannot satisfy the waiting caller' {
        Expect-Failure (Run-Setup 'changed') 'NCM_MAINTENANCE_INSTALLATION_CHANGED'
    }
    Check 'revoked maintenance cancels confirmation without re-enabling the user' {
        $result=Run-Setup 'disabled';Expect-Failure $result 'NCM_MAINTENANCE_SETUP_CANCELLED'
        if ([IO.File]::Exists((Join-Path $result.packet 'profile\NCMGapless\startup\enabled.txt'))) { throw 'REVOKED_SETUP_REENABLED_USER' }
    }
    Check 'foreign installation ownership is rejected before enablement' {
        Expect-Failure (Run-Setup 'wrong-owner') 'NCM_MAINTENANCE_CONFIG_INVALID'
    }
    Check 'a removed configuration cannot reuse a successful setup receipt' {
        Expect-Failure (Run-Setup 'missing-config') 'NCM_MAINTENANCE_SETUP_PENDING'
    }
    Check 'verified cached installation remains usable when update checking fails' {
        $result=Run-Setup 'warning'
        if ($result.error -or $result.text -notmatch '\[3/3\]' -or $result.text -notmatch 'NCM_UPDATE_CHECK_FAILED') { throw 'CACHED_READY_WARNING_NOT_REPORTED' }
    }
    Check 'uninstall skips the client-exit and installation-ready waits' {
        $result=Run-Setup 'uninstall' -Uninstall
        if ($result.error -or [IO.File]::Exists((Join-Path $result.packet 'probes.txt')) -or $result.text -match '\[3/3\]') { throw 'UNINSTALL_BLOCKED_BY_SETUP_WAIT' }
    }
    Write-Host "$checks setup UI checks passed; no real client, elevation, task or network used."
} finally {
    $env:ProgramFiles=$savedProgramFiles;$env:LOCALAPPDATA=$savedLocalAppData
    foreach ($name in @('NCM_SETUP_PACKET','NCM_SETUP_SCENARIO')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
}
