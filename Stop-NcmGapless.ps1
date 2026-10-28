[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Ncm-Cdp.ps1')
. (Join-Path $PSScriptRoot 'tools\Ncm-StartupState.ps1')
Disable-NcmStartup
try { $port = Find-NcmPort }
catch {
    if ($_.ToString() -notmatch 'NCM_NOT_RUNNING|NCM_EXIT_AND_RESTART_WITH_LAUNCHER') { throw }
    [PSCustomObject]@{ installed = $false; automaticEnabled = $false } | ConvertTo-Json
    return
}
$result = Invoke-NcmExpression -Port $port -Expression 'window.NcmGapless?.uninstall ? window.NcmGapless.uninstall() : ({installed:false})' -UserGesture
$result | Add-Member -NotePropertyName automaticEnabled -NotePropertyValue $false -Force
$result | ConvertTo-Json -Depth 6
