# Real Windows loader / IAT / CEF callback integration against a fake client.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'tools\build_windows_startup.ps1') -NoPublish
$fixture = Join-Path $repository ('.local\windows-startup-native-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$resourceCompiler = Join-Path $sdk "bin\$($sdkVersion.Name)\x64\rc.exe"
Push-Location $fixture
try {
    & $compiler /nologo /LD /MT /EHsc (Join-Path $repository 'tests\native\fake_cef.cpp') /Felibcef.dll
    if ($LASTEXITCODE) { throw 'FIXTURE_CEF_BUILD_FAILED' }
    & $compiler /nologo /LD /MT /EHsc (Join-Path $repository 'tests\native\fake_cloudmusic.cpp') /Fecloudmusic.dll /link libcef.lib msimg32.lib
    if ($LASTEXITCODE) { throw 'FIXTURE_CLIENT_BUILD_FAILED' }
    & $resourceCompiler /nologo /foclient-version.res (Join-Path $repository 'tests\native\client-version.rc')
    if ($LASTEXITCODE) { throw 'FIXTURE_RESOURCE_BUILD_FAILED' }
    & $compiler /nologo /MT /EHsc (Join-Path $repository 'tests\native\fake_main.cpp') /Fecloudmusic.exe /link client-version.res
    if ($LASTEXITCODE) { throw 'FIXTURE_MAIN_BUILD_FAILED' }
    Copy-Item -LiteralPath (Join-Path $output 'MSIMG32.dll') -Destination (Join-Path $fixture 'MSIMG32.dll') -Force
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\msimg32.dll') -Destination (Join-Path $fixture 'ncm_gapless_msimg32.dll') -Force
    $helperDirectory = Join-Path $fixture 'ncm-gapless\tools'
    [void][IO.Directory]::CreateDirectory($helperDirectory)
    $helper = @'
param([int]$Port,[int]$ClientProcessId,[string]$StartedFileTime,[string]$Token)
@{port=$Port;processId=$ClientProcessId;started=$StartedFileTime;token=$Token} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'marker.json') -Encoding UTF8
'@
    [IO.File]::WriteAllText((Join-Path $helperDirectory 'AutoAttach-NcmGapless.ps1'), $helper, [Text.Encoding]::ASCII)
    $cases = @(
        @{ name='ordinary'; args=''; enabled=$true; expect=$true; helper=$true; calls=1 },
        @{ name='versioned-runtime'; args=''; enabled=$true; expect=$true; helper=$true; calls=1 },
        @{ name='invalid-runtime-pointer'; args=''; enabled=$true; expect=$true; helper=$false; calls=1 },
        @{ name='existing-port'; args='--existing-port'; enabled=$true; expect=$true; helper=$true; calls=1 },
        @{ name='disabled'; args=''; enabled=$false; expect=$false; helper=$false; calls=1 },
        @{ name='unknown-cef'; args='--unverified-cef'; enabled=$true; expect=$false; helper=$false; calls=1 },
        @{ name='changed-cef-abi'; args='--mismatched-api'; enabled=$true; expect=$false; helper=$false; calls=1 },
        @{ name='readonly'; args='--readonly'; enabled=$true; expect=$false; helper=$false; calls=1 },
        @{ name='small-command'; args='--small-command'; enabled=$true; expect=$false; helper=$false; calls=1 },
        @{ name='renderer'; args='--type=renderer --renderer-process'; enabled=$true; expect=$false; helper=$false; calls=1 },
        @{ name='filename-with-switch-text'; args='"D:\album --type=renderer track.wav"'; enabled=$true; expect=$true; helper=$true; calls=1 },
        @{ name='null-app'; args='--null-app'; enabled=$true; expect=$false; helper=$false; calls=0 },
        @{ name='null-callback'; args='--null-callback'; enabled=$true; expect=$true; helper=$true; calls=0 },
        @{ name='failed-initialize'; args='--init-failed'; enabled=$true; expect=$true; helper=$false; calls=1 },
        @{ name='cancel-in-original'; args='--cancel-during-original'; enabled=$true; expect=$false; helper=$false; calls=1 },
        @{ name='cancel-after-before'; args='--cancel-after-before'; enabled=$true; expect=$true; helper=$false; calls=1 }
    )
    foreach ($case in $cases) {
        $pointer=Join-Path $fixture 'ncm-gapless\active.txt'
        [IO.File]::Delete($pointer)
        if ($case.name -eq 'versioned-runtime') {
            $digest='a'*64
            $versioned=Join-Path $fixture "ncm-gapless\versions\$digest\tools"
            [void][IO.Directory]::CreateDirectory($versioned)
            [IO.File]::WriteAllText((Join-Path $versioned 'AutoAttach-NcmGapless.ps1'),$helper,[Text.Encoding]::ASCII)
            [IO.File]::WriteAllText($pointer,$digest)
        } elseif ($case.name -eq 'invalid-runtime-pointer') { [IO.File]::WriteAllText($pointer,'../../escape') }
        $profile = Join-Path $fixture $case.name
        $state = Join-Path $profile 'NCMGapless\startup'
        [void][IO.Directory]::CreateDirectory($state)
        if ($case.enabled) { [IO.File]::WriteAllText((Join-Path $state 'enabled.txt'), "NCMG1`n0123456789abcdef0123456789abcdef`n$(Join-Path $fixture 'cloudmusic.exe')`n", (New-Object Text.UTF8Encoding($false))) }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $fixture 'cloudmusic.exe'; $start.Arguments = $case.args; $start.WorkingDirectory = $fixture
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.EnvironmentVariables['LOCALAPPDATA'] = $profile
        $process = [Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEnd(); $errors = $process.StandardError.ReadToEnd(); $process.WaitForExit()
        if ($process.ExitCode) { throw "FIXTURE_FAILED $($case.name): $output $errors exit=$($process.ExitCode)" }
        $reports = @($output -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $flags = $reports | Where-Object { $_.PSObject.Properties.Name -contains 'loopback' }
        $callback = $reports | Where-Object { $_.PSObject.Properties.Name -contains 'originalCalls' }
        $forwarding = $reports | Where-Object { $_.PSObject.Properties.Name -contains 'forwardedExports' }
        if (-not $flags -or -not $callback -or -not $forwarding -or $flags.ownershipErrors -ne 0 -or $flags.commandReferences -ne 0 -or
            $callback.appOwnershipErrors -ne 0 -or $callback.appReferences -ne $(if ($case.name -eq 'null-app') { 1 } else { 0 }) -or
            $flags.loopback -ne $case.expect -or $flags.port -ne $case.expect -or
            $callback.originalCalls -ne $case.calls -or -not $callback.callbackRestored -or $forwarding.forwardedExports -ne 5) { throw "CALLBACK_MISMATCH $($case.name): $output" }
        $marker = Join-Path $profile 'marker.json'
        if ($case.helper) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $marker) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
        }
        if ([bool](Test-Path -LiteralPath $marker) -ne $case.helper) { throw "HELPER_MISMATCH $($case.name): $output" }
        Write-Host "PASS native startup $($case.name)"
    }
    Write-Host "$($cases.Count) real Windows loader checks passed. No real client was started."
} finally { Pop-Location }
