# Executes the real attach script with controlled process/CDP I/O and real locks.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $repository ('.local\windows-startup-attach-' + [Guid]::NewGuid().ToString('N'))
$toolsDirectory = Join-Path $fixture 'tools'
[void][IO.Directory]::CreateDirectory($toolsDirectory)
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'src'))
foreach ($name in @('AutoAttach-NcmGapless.ps1','Ncm-StartupState.ps1')) { Copy-Item -LiteralPath (Join-Path $repository "tools\$name") -Destination (Join-Path $toolsDirectory $name) }
foreach ($name in @('client-adapter.js','aac-timing.js','gapless-engine.js','netease-gapless.js')) { [IO.File]::WriteAllText((Join-Path $fixture "src\$name"), '// controlled fixture') }
$transport = @'
function Get-Process {
    [CmdletBinding()]param([int]$Id)
    if ($env:NCM_TEST_CASE -eq 'closed') { return $null }
    $started = [DateTime]::FromFileTimeUtc([long]$env:NCM_TEST_STARTED)
    if ($env:NCM_TEST_CASE -eq 'reused-pid') { $started = $started.AddSeconds(1) }
    [PSCustomObject]@{ SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId; StartTime=$started; Path=$env:NCM_TEST_CLIENT }
}
function Get-NetTCPConnection {
    [CmdletBinding()]param($State,$LocalPort)
    [PSCustomObject]@{ OwningProcess=$(if ($env:NCM_TEST_CASE -eq 'foreign-port') { 999 } else { 42 }); LocalAddress=$(if ($env:NCM_TEST_CASE -eq 'non-loopback') { '0.0.0.0' } else { '127.0.0.1' }) }
}
function Invoke-NcmExpression {
    param([int]$Port,[string]$Expression,[switch]$UserGesture)
    if ($Expression.StartsWith('/* ncm-startup-readiness */')) {
        if ($env:NCM_TEST_CASE -eq 'cancel-during-ready') { [IO.File]::Delete((Join-Path $env:LOCALAPPDATA 'NCMGapless\startup\enabled.txt')) }
        if ($env:NCM_TEST_CASE -eq 'new-generation') {
            $path=Join-Path $env:LOCALAPPDATA 'NCMGapless\startup\enabled.txt'
            [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace('0123456789abcdef0123456789abcdef','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), (New-Object Text.UTF8Encoding($false)))
        }
        return [PSCustomObject]@{ready=$true;error=$null;documentState='interactive'}
    }
    if ($env:NCM_TEST_CASE -eq 'unsupported') { throw 'CLIENT_VERSION_UNVERIFIED' }
    [IO.File]::AppendAllText((Join-Path $env:LOCALAPPDATA 'injections.txt'), "injected`n")
    [PSCustomObject]@{installed=$true}
}
'@
[IO.File]::WriteAllText((Join-Path $toolsDirectory 'Ncm-Cdp.ps1'), $transport, [Text.Encoding]::ASCII)
$cases = @(
    @{ name='ready'; installed=$true; result='installed'; enabled=$true },
    @{ name='closed'; installed=$false; result='closed'; enabled=$true },
    @{ name='reused-pid'; installed=$false; result='closed'; enabled=$true },
    @{ name='cancel-during-ready'; installed=$false; result='failed'; enabled=$true },
    @{ name='new-generation'; installed=$false; result='failed'; enabled=$true },
    @{ name='foreign-port'; installed=$false; result='failed'; enabled=$true },
    @{ name='non-loopback'; installed=$false; result='failed'; enabled=$true },
    @{ name='unsupported'; installed=$false; result='failed'; enabled=$true },
    @{ name='disabled'; installed=$false; result=$null; enabled=$false }
)
foreach ($case in $cases) {
    $profile = Join-Path $fixture $case.name
    $state = Join-Path $profile 'NCMGapless\startup'
    [void][IO.Directory]::CreateDirectory($state)
    $client = Join-Path $fixture 'cloudmusic.exe'
    if ($case.enabled) { [IO.File]::WriteAllText((Join-Path $state 'enabled.txt'), "NCMG1`n0123456789abcdef0123456789abcdef`n$client`n", (New-Object Text.UTF8Encoding($false))) }
    $started = [DateTime]::UtcNow.ToFileTimeUtc().ToString()
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Port 49321 -ClientProcessId 42 -StartedFileTime {1} -Token 0123456789abcdef0123456789abcdef -StartupTimeoutSeconds 1' -f (Join-Path $toolsDirectory 'AutoAttach-NcmGapless.ps1'),$started
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.EnvironmentVariables['LOCALAPPDATA']=$profile
    $start.EnvironmentVariables['NCM_TEST_CASE']=$case.name
    $start.EnvironmentVariables['NCM_TEST_CLIENT']=$client
    $start.EnvironmentVariables['NCM_TEST_STARTED']=$started
    $process=[Diagnostics.Process]::Start($start)
    $output=$process.StandardOutput.ReadToEnd(); $errors=$process.StandardError.ReadToEnd(); $process.WaitForExit()
    if ($process.ExitCode) { throw "ATTACH_FIXTURE_FAILED $($case.name): $output $errors" }
    $injected=Test-Path -LiteralPath (Join-Path $profile 'injections.txt')
    if ($injected -ne $case.installed) { throw "ATTACH_INJECTION_MISMATCH $($case.name)" }
    if ($case.result) {
        $receipt=Get-Content -LiteralPath (Join-Path $state 'attach.json') -Raw | ConvertFrom-Json
        if ($receipt.result -cne $case.result -or $receipt.installed -ne $case.installed) { throw "ATTACH_RECEIPT_MISMATCH $($case.name)" }
    }
    Write-Host "PASS startup attach $($case.name)"
}
Write-Host "$($cases.Count) real PowerShell attach lifecycle checks passed. No real client or network was used."
