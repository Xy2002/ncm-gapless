# Per-user revocation and receipts for the optional native startup loader.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NcmStartupStateDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NCMGapless\startup')
}
function Read-NcmStartupText {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Write-NcmStartupText {
    param([string]$Name, [string]$Text)
    $directory = Get-NcmStartupStateDirectory
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory $Name
    $temporary = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Read-NcmStartupEnabled {
    $text = Read-NcmStartupText (Join-Path (Get-NcmStartupStateDirectory) 'enabled.txt')
    if (-not $text) { return $null }
    $parts = $text -split "`n"
    if ($parts.Count -ne 4 -or $parts[0] -cne 'NCMG1' -or $parts[1] -cnotmatch '^[0-9a-f]{32}$' -or
        -not [IO.Path]::IsPathRooted($parts[2]) -or $parts[3] -ne '') { throw 'NCM_STARTUP_CONFIG_INVALID' }
    return [PSCustomObject]@{ token = $parts[1]; clientPath = $parts[2] }
}
function Assert-NcmStartupEnabled {
    param([string]$Token, [string]$ClientPath)
    $enabled = Read-NcmStartupEnabled
    if (-not $enabled -or $enabled.token -cne $Token -or $enabled.clientPath -ine $ClientPath) { throw 'NCM_STARTUP_CANCELLED' }
}
function Enter-NcmStartupLock {
    param([int]$TimeoutSeconds = 45)
    $directory = Get-NcmStartupStateDirectory
    [void][IO.Directory]::CreateDirectory($directory)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open((Join-Path $directory 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'NCM_STARTUP_BUSY' }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}
function Read-NcmNativeStartupReceipt {
    $text = Read-NcmStartupText (Join-Path (Get-NcmStartupStateDirectory) 'native.txt')
    if (-not $text) { return $null }
    $parts = $text -split "`n"
    if ($parts.Count -ne 8 -or $parts[0] -cne 'NCMG1' -or $parts[1] -notmatch '^\d+$' -or
        $parts[2] -notmatch '^\d+$' -or $parts[3] -notmatch '^\d+$' -or $parts[4] -cnotmatch '^[0-9a-f]{32}$' -or
        -not [IO.Path]::IsPathRooted($parts[6])) { return $null }
    $port = [int]$parts[3]
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    return [PSCustomObject]@{ processId = [int]$parts[1]; startedFileTime = $parts[2]; port = $port
        token = $parts[4]; stage = $parts[5]; clientPath = $parts[6] }
}
function Test-NcmStartupProcess {
    param([int]$ClientProcessId, [string]$StartedFileTime, [string]$ClientPath)
    $process = Get-Process -Id $ClientProcessId -ErrorAction SilentlyContinue
    return [bool]($process -and $process.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId -and
        $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $StartedFileTime -and $process.Path -ieq $ClientPath)
}
function Get-NcmStartupPort {
    $receipt = Read-NcmNativeStartupReceipt
    if ($receipt -and (Test-NcmStartupProcess $receipt.processId $receipt.startedFileTime $receipt.clientPath)) { return $receipt.port }
    return $null
}
function Assert-NcmStartupEndpoint {
    param([int]$Port, [int]$ClientProcessId)
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    $owned = @($listeners | Where-Object { $_.OwningProcess -eq $ClientProcessId })
    if (-not $owned.Count) { throw 'NCM_STARTUP_ENDPOINT_OWNER_MISMATCH' }
    if (@($owned | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }).Count) { throw 'NCM_STARTUP_ENDPOINT_NOT_LOOPBACK' }
}
function Disable-NcmStartup {
    # Revoke before waiting, so a queued or in-flight attach cannot reinstall.
    $path = Join-Path (Get-NcmStartupStateDirectory) 'enabled.txt'
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    if (Test-Path -LiteralPath (Get-NcmStartupStateDirectory)) {
        $operation = Enter-NcmStartupLock
        $operation.Dispose()
    }
}
function Get-NcmStartupStatus {
    $enabled = Read-NcmStartupEnabled
    $errorCode = $null
    $result = $null
    $text = Read-NcmStartupText (Join-Path (Get-NcmStartupStateDirectory) 'attach.json')
    if ($text) {
        $receipt = $text | ConvertFrom-Json
        if ($enabled -and $receipt.token -ceq $enabled.token) { $errorCode = $receipt.error; $result = $receipt.result }
    }
    return [PSCustomObject]@{ automaticEnabled = [bool]$enabled; automaticLastResult = $result; automaticLastError = $errorCode }
}
