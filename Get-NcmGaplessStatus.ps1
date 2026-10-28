[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Ncm-Cdp.ps1')
. (Join-Path $PSScriptRoot 'tools\Ncm-StartupState.ps1')
$result = [PSCustomObject]@{ installed = $false }
try {
    $port = Find-NcmPort
    $result = Invoke-NcmExpression -Port $port -Expression 'window.NcmGapless?.status?.() || ({installed:false})'
} catch { if ($_.ToString() -notmatch 'NCM_NOT_RUNNING|NCM_EXIT_AND_RESTART_WITH_LAUNCHER') { throw } }
$automatic = Get-NcmStartupStatus
foreach ($field in $automatic.PSObject.Properties) { $result | Add-Member -NotePropertyName $field.Name -NotePropertyValue $field.Value -Force }
$result | ConvertTo-Json -Depth 6
