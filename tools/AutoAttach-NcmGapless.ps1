[CmdletBinding()]
param([Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$ClientProcessId,
    [Parameter(Mandatory = $true)][string]$StartedFileTime,
    [Parameter(Mandatory = $true)][string]$Token,
    [ValidateRange(1,60)][int]$StartupTimeoutSeconds = 60)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Ncm-StartupState.ps1')
. (Join-Path $PSScriptRoot 'Ncm-Cdp.ps1')
$enabled = Read-NcmStartupEnabled
if (-not $enabled -or $enabled.token -cne $Token) { exit 0 }
$operation = $null
$receipt = [ordered]@{ token = $Token; processId = $ClientProcessId; startedFileTime = $StartedFileTime
    port = $Port; result = 'waiting'; error = $null; installed = $false
    clientPath = $enabled.clientPath; runtimeDigest = (Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf)
    readinessAttempts = 0; lastReadinessError = $null; documentState = $null }
try {
    $operation = Enter-NcmStartupLock
    Assert-NcmStartupEnabled $Token $enabled.clientPath
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'NCM_STARTUP_PORT_INVALID' }
    $root = Split-Path $PSScriptRoot -Parent
    $probe = "/* ncm-startup-readiness */`n" + [IO.File]::ReadAllText((Join-Path $root 'src\client-adapter.js'), [Text.Encoding]::UTF8) + "`n;window.NcmGaplessClient.startupReadiness(window);"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-NcmStartupEnabled $Token $enabled.clientPath
        if (-not (Test-NcmStartupProcess $ClientProcessId $StartedFileTime $enabled.clientPath)) { $receipt.result = 'closed'; return }
        try {
            $receipt.readinessAttempts++
            Assert-NcmStartupEndpoint $Port $ClientProcessId
            $readiness = Invoke-NcmExpression -Port $Port -Expression $probe
            $receipt.documentState = $readiness.documentState
            $receipt.lastReadinessError = $readiness.error
            if ($readiness.ready) { break }
        } catch {
            $match = [regex]::Match($_.ToString(), 'NCM_[A-Z_]+')
            $receipt.lastReadinessError = $(if ($match.Success) { $match.Value } else { 'NCM_STARTUP_TRANSPORT_NOT_READY' })
        }
        if ($receipt.lastReadinessError -in @('CLIENT_VERSION_UNVERIFIED','CLIENT_PLAYBACK_CONTRACT_UNSUPPORTED')) { throw $receipt.lastReadinessError }
        if ($clock.Elapsed.TotalSeconds -ge $StartupTimeoutSeconds) { throw $(if ($receipt.lastReadinessError) { $receipt.lastReadinessError } else { 'NCM_STARTUP_NOT_READY' }) }
        Start-Sleep -Milliseconds 200
    } while ($true)
    $code = (@('client-adapter.js', 'aac-timing.js', 'gapless-engine.js', 'netease-gapless.js') |
        ForEach-Object { [IO.File]::ReadAllText((Join-Path $root "src\$_"), [Text.Encoding]::UTF8) }) -join "`n"
    $code += "`n;if (!window.NcmGapless.installed) window.NcmGapless.install(); window.NcmGapless.status();"
    Assert-NcmStartupEnabled $Token $enabled.clientPath
    if (-not (Test-NcmStartupProcess $ClientProcessId $StartedFileTime $enabled.clientPath)) { $receipt.result = 'closed'; return }
    Assert-NcmStartupEndpoint $Port $ClientProcessId
    Assert-NcmStartupEnabled $Token $enabled.clientPath
    $status = Invoke-NcmExpression -Port $Port -Expression $code -UserGesture
    if (-not $status.installed) { throw 'NCM_STARTUP_INSTALL_FAILED' }
    $receipt.result = 'installed'; $receipt.installed = $true
} catch {
    $match = [regex]::Match($_.ToString(), '(?:NCM_|CLIENT_|PLAYBACK_|WEBPACK_)[A-Z_]+')
    $receipt.result = 'failed'
    $receipt.error = $(if ($match.Success) { $match.Value } else { 'NCM_STARTUP_ATTACH_FAILED' })
} finally {
    if ($operation) {
        try {
            Write-NcmStartupText 'attach.json' ($receipt | ConvertTo-Json -Depth 4)
            Write-NcmStartupHealth $receipt
        }
        finally { $operation.Dispose() }
    }
}
