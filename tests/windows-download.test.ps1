Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Ncm-Maintenance.ps1')
$script:requests=New-Object 'System.Collections.Generic.List[string]'
function Get-NcmRawHttpsBytes($Url,$MaximumBytes,$Accept) {
    $script:requests.Add($Url)
    if ($Url.StartsWith('https://github.com/')) { throw 'controlled TLS failure' }
    if ($Url -match '/tags/') {
        return ,([Text.Encoding]::UTF8.GetBytes('{"assets":[{"id":42,"name":"windows-update.json","url":"https://untrusted.example/ignored"}]}'))
    }
    if ($Url -cne 'https://api.github.com/repos/Xy2002/ncm-gapless/releases/assets/42' -or $Accept -cne 'application/octet-stream') { throw 'UNEXPECTED_API_REQUEST' }
    return ,([byte[]]@(1,2,3))
}
$value=Get-NcmHttpsBytes $script:NcmFeedUrl 131072
if ($value.Length -ne 3 -or $value[2] -ne 3 -or $script:requests.Count -ne 3) { throw 'ASSET_API_FALLBACK_FAILED' }
Write-Host 'PASS official API fallback uses fixed asset endpoint and ignores untrusted URL metadata'
try { $null=Get-NcmHttpsBytes 'https://github.com/other/repo/releases/download/tag/windows-update.json' 100;throw 'EXPECTED_REJECTION' }
catch { if ($_.ToString() -notmatch 'controlled TLS failure') { throw } }
Write-Host 'PASS an unrelated repository cannot enter the API fallback'
Write-Host '2 HTTPS fallback checks passed without network.'
