[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\Ncm-Cdp.ps1')
$port = Find-NcmPort
Invoke-NcmExpression -Port $port -Expression 'window.NcmGapless?.uninstall ? window.NcmGapless.uninstall() : ({installed:false})' -UserGesture | ConvertTo-Json -Depth 6
