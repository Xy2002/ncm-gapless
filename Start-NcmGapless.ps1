[CmdletBinding()]
param([string]$ClientPath, [switch]$ActivateCurrent)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Ncm-Cdp.ps1')
$port = Find-NcmPort -Launch -ClientPath $ClientPath
$ready = $false
$startup = [Diagnostics.Stopwatch]::StartNew()
while ($startup.Elapsed.TotalSeconds -lt 30) {
    try {
        $ready = [bool](Invoke-NcmExpression -Port $port -Expression "Boolean(document.readyState === 'complete' && window.channel && window.webpackJsonp && document.getElementById('root')?._reactRootContainer)")
        if ($ready) { break }
    } catch { }
    Start-Sleep -Milliseconds 500
}
if (-not $ready) { throw 'NCM_STARTUP_NOT_READY' }
$sources = @('client-adapter.js', 'aac-timing.js', 'gapless-engine.js', 'netease-gapless.js')
$code = ($sources | ForEach-Object { [IO.File]::ReadAllText((Join-Path $PSScriptRoot "src\$_"), [Text.Encoding]::UTF8) }) -join "`n"
$code += "`n;if (!window.NcmGapless.installed) window.NcmGapless.install();"
if ($ActivateCurrent) { $code += "`n;window.NcmGapless.activateCurrent();" }
$code += "`n;window.NcmGapless.status();"
$result = Invoke-NcmExpression -Port $port -Expression $code -UserGesture
$result | ConvertTo-Json -Depth 6
if ($result.installed) { Write-Host 'Enabled. Select a song in NetEase Cloud Music to begin.' }
