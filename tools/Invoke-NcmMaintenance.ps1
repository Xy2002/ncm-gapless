[CmdletBinding()]
param([switch]$CheckNow)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Ncm-Maintenance.ps1')
. (Join-Path $PSScriptRoot 'Ncm-ClientCompatibility.ps1')
$root = $PSScriptRoot
Assert-NcmAdminDirectory $root
$lock = $null
try { $lock = [IO.File]::Open((Join-Path $root 'maintenance.lock'),'OpenOrCreate','ReadWrite','None') }
catch [IO.IOException] { exit 0 }
$receipt = [ordered]@{ checkedUtc=[DateTime]::UtcNow.ToString('o'); result='idle'; error=$null; version=$null; clientVersion=$null }
$pending=$false; $rollback=$false; $active=$null; $release=$null; $state=$null
try {
    $config = Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
    if ($config.owner -cne 'ncm-gapless-maintenance-v1') { throw 'NCM_MAINTENANCE_CONFIG_INVALID' }
    if ($config.PSObject.Properties.Name -contains 'enabled' -and -not $config.enabled) { $receipt.result='disabled'; return }
    $clientDirectory = Split-Path $config.clientPath -Parent
    Assert-NcmAdminDirectory $clientDirectory
    $client = Assert-NcmOfficialClient $config.clientPath
    $receipt.clientVersion = $client.version
    $publicKey = [IO.File]::ReadAllText((Join-Path $root 'update-public-key.xml'))
    $statePath = Join-Path $root 'state.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $active = Get-Content -LiteralPath (Join-Path $root 'active.json') -Raw | ConvertFrom-Json
    $stored = Get-NcmStoredRelease $root $active $publicKey
    $release = $stored.release
    if ($state.PSObject.Properties.Name -notcontains 'failureDigest' -or $state.failureDigest -cne $release.digest) {
        $state | Add-Member -NotePropertyName failureDigest -NotePropertyValue $release.digest -Force
        $state | Add-Member -NotePropertyName failureCount -NotePropertyValue 0 -Force
        $state | Add-Member -NotePropertyName lastFailure -NotePropertyValue '' -Force
    }
    $updateError = $null
    if ($CheckNow -or [DateTime]::UtcNow -ge [DateTime]::Parse($state.nextCheckUtc).ToUniversalTime()) {
        try {
            $candidate = Read-NcmSignedRelease (Get-NcmHttpsBytes $script:NcmFeedUrl 131072) $publicKey
            Assert-NcmReleaseSequence $candidate $state
            if ($state.PSObject.Properties.Name -contains 'rejectedDigest' -and $state.rejectedDigest -ceq $candidate.digest) { throw 'NCM_UPDATE_QUARANTINED' }
            $state.highestSequence = $candidate.document.sequence; $state.highestDigest = $candidate.digest
            $state.nextCheckUtc = [DateTime]::UtcNow.AddHours(6).ToString('o')
            Write-NcmMaintenanceJson $statePath $state
            if ($candidate.digest -cne $release.digest) {
                $package = Get-NcmHttpsBytes $candidate.document.package.url 8388608
                $null = Read-NcmReleasePayload $package $candidate
                $cache = Join-Path $root ('releases\' + $candidate.digest)
                Write-NcmAtomicBytes (Join-Path $cache 'package.zip') $package
                Write-NcmAtomicBytes (Join-Path $cache 'manifest.json') $candidate.envelope
                Write-NcmMaintenanceJson (Join-Path $root 'pending.json') @{digest=$candidate.digest}
            }
        } catch {
            $updateError = 'NCM_UPDATE_CHECK_FAILED'
            if ($_.ToString() -match '(NCM_[A-Z_]+)') { $updateError = $Matches[1] }
            $state.nextCheckUtc = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
            Write-NcmMaintenanceJson $statePath $state
        }
    }
    if (-not [IO.File]::Exists((Join-Path $root 'pending.json')) -and [IO.File]::Exists((Join-Path $root 'previous.json'))) {
        $health=Get-NcmActivationHealth $config.clientPath $release.digest
        if ($health) {
            $identity="$($health.processId):$($health.startedFileTime)"
            if ($health.result -ceq 'installed') { $state | Add-Member -NotePropertyName failureCount -NotePropertyValue 0 -Force }
            elseif ($health.result -ceq 'failed' -and $health.error -notmatch 'CLIENT_|CANCELLED' -and
                ($state.PSObject.Properties.Name -notcontains 'lastFailure' -or $state.lastFailure -cne $identity)) {
                $count=$(if ($state.PSObject.Properties.Name -contains 'failureCount') { [int]$state.failureCount } else { 0 })
                $state | Add-Member -NotePropertyName failureCount -NotePropertyValue ($count+1) -Force
                $state | Add-Member -NotePropertyName lastFailure -NotePropertyValue $identity -Force
            }
            Write-NcmMaintenanceJson $statePath $state
            if ($state.PSObject.Properties.Name -contains 'failureCount' -and $state.failureCount -ge 3) {
                $previous=Get-Content -LiteralPath (Join-Path $root 'previous.json') -Raw|ConvertFrom-Json
                $stored=Get-NcmStoredRelease $root $previous $publicKey
                $state | Add-Member -NotePropertyName rejectedDigest -NotePropertyValue $release.digest -Force
                Write-NcmMaintenanceJson $statePath $state
                $release=$stored.release; $rollback=$true
            }
        }
    }
    $pending = [IO.File]::Exists((Join-Path $root 'pending.json'))
    if ($pending) {
        $pointer = Get-Content -LiteralPath (Join-Path $root 'pending.json') -Raw | ConvertFrom-Json
        try {
            $candidateStored = Get-NcmStoredRelease $root $pointer $publicKey
            Assert-NcmReleaseSequence $candidateStored.release $state
            $stored=$candidateStored; $release=$stored.release
        } catch {
            # An obsolete/partial pending download must never block cached active repair.
            [IO.File]::Delete((Join-Path $root 'pending.json')); $pending=$false
            $updateError='NCM_UPDATE_PENDING_REJECTED'
        }
    }
    $files = $stored.files
    $receipt.version = $release.document.version
    $running = @(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" | Where-Object { $_.ExecutablePath -ieq $config.clientPath })
    if ($running.Count) { $receipt.result = 'deferred-client-running'; $receipt.error=$updateError; return }
    $matches = $true
    foreach ($relative in @('ncm-gapless','ncm-gapless\versions',('ncm-gapless\versions\'+$release.digest))) {
        $path=Join-Path $clientDirectory $relative
        if ([IO.Directory]::Exists($path)) { Assert-NcmAdminDirectory $path }
    }
    foreach ($relative in @('tools','src','LICENSES')) {
        $path=Join-Path $clientDirectory ('ncm-gapless\versions\'+$release.digest+'\'+$relative)
        if ([IO.Directory]::Exists($path)) { Assert-NcmAdminDirectory $path }
    }
    foreach ($name in $files.Keys) {
        $relative = $(if ($name -ceq 'MSIMG32.dll') { $name } else { 'ncm-gapless/versions/'+$release.digest+'/'+$name.Substring(12) })
        $target = Join-Path $clientDirectory $relative
        if (-not [IO.File]::Exists($target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $release.document.files.$name.sha256) { $matches=$false; break }
    }
    $manifestPath = Join-Path $clientDirectory 'ncm-gapless\installation.json'
    $alias = Join-Path $clientDirectory 'ncm_gapless_msimg32.dll'
    $pointerPath = Join-Path $clientDirectory 'ncm-gapless\active.txt'
    if (-not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists($alias) -or
        -not [IO.File]::Exists($pointerPath) -or [IO.File]::ReadAllText($pointerPath) -cne $release.digest) { $matches=$false }
    if ([IO.File]::Exists($manifestPath)) {
        $installed=Read-NcmSmallJson $manifestPath
        if (-not $installed -or $installed.PSObject.Properties.Name -notcontains 'runtime' -or
            $installed.runtime.digest -cne $release.digest -or $installed.sha256.'MSIMG32.dll' -cne $release.document.files.'MSIMG32.dll'.sha256) { $matches=$false }
    }
    if ([IO.File]::Exists($alias) -and [IO.File]::Exists((Join-Path $root 'owned.json'))) {
        $owned = Get-Content -LiteralPath (Join-Path $root 'owned.json') -Raw|ConvertFrom-Json
        if ((Get-FileHash -LiteralPath $alias -Algorithm SHA256).Hash -ine $owned.sha256.'ncm_gapless_msimg32.dll') { throw 'NCM_STARTUP_OWNED_FILE_CHANGED' }
    }
    if (-not $matches) {
        if (-not [IO.File]::Exists($manifestPath) -and [IO.File]::Exists((Join-Path $root 'owned.json'))) {
            $owned = Get-Content -LiteralPath (Join-Path $root 'owned.json') -Raw | ConvertFrom-Json
            foreach ($entry in $owned.sha256.PSObject.Properties) {
                $path = Join-Path $clientDirectory $entry.Name
                if ([IO.File]::Exists($path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.Value) { throw 'NCM_STARTUP_INSTALLATION_CONFLICT' }
            }
            Write-NcmMaintenanceJson $manifestPath $owned
        }
        $stage = Join-Path $root 'stage'
        [void][IO.Directory]::CreateDirectory($stage)
        $hashes = [ordered]@{}
        foreach ($name in $files.Keys) { Write-NcmAtomicBytes (Join-Path $stage $name) $files[$name]; $hashes[$name.Replace('/','\')] = $release.document.files.$name.sha256 }
        Write-NcmMaintenanceJson (Join-Path $stage 'manifest.json') ([ordered]@{owner='ncm-gapless-windows-startup-v1';clientVersion=$client.version;sha256=$hashes})
        $operation = Join-Path $root 'Set-NcmStartupInstallation.ps1'
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $operation -ClientPath $config.clientPath -Payload $stage -ResultPath (Join-Path $stage 'result.json') -Repair -RuntimeDigest $release.digest
        $result = Get-Content -LiteralPath (Join-Path $stage 'result.json') -Raw | ConvertFrom-Json
        if ($LASTEXITCODE -or -not $result.success) { throw $result.error }
        Write-NcmAtomicBytes (Join-Path $root 'owned.json') ([IO.File]::ReadAllBytes($manifestPath))
        $receipt.result = 'repaired'
    } else { $receipt.result = 'healthy' }
    if ($pending) {
        Write-NcmMaintenanceJson (Join-Path $root 'previous.json') $active
        Write-NcmMaintenanceJson (Join-Path $root 'active.json') @{digest=$release.digest}
        [IO.File]::Delete((Join-Path $root 'pending.json'))
        $receipt.result = 'updated'
    }
    if ($rollback) {
        Write-NcmMaintenanceJson (Join-Path $root 'active.json') @{digest=$release.digest}
        [IO.File]::Delete((Join-Path $root 'previous.json'))
        $receipt.result='rolled-back'
    }
    if ($pending -or $rollback) {
        $state | Add-Member -NotePropertyName failureDigest -NotePropertyValue $release.digest -Force
        $state | Add-Member -NotePropertyName failureCount -NotePropertyValue 0 -Force
        $state | Add-Member -NotePropertyName lastFailure -NotePropertyValue '' -Force
        Write-NcmMaintenanceJson $statePath $state
    }
    if ($updateError) { $receipt.error = $updateError }
} catch {
    $receipt.result = 'failed'; $receipt.error = 'NCM_MAINTENANCE_FAILED'
    if ($_.ToString() -match '(NCM_[A-Z_]+)') { $receipt.error = $Matches[1] }
    if ($pending -and $release.digest -cne $active.digest) {
        $state | Add-Member -NotePropertyName rejectedDigest -NotePropertyValue $release.digest -Force
        Write-NcmMaintenanceJson $statePath $state
        [IO.File]::Delete((Join-Path $root 'pending.json'))
    }
} finally {
    try { Write-NcmMaintenanceJson (Join-Path $root 'status.json') $receipt } finally { $lock.Dispose() }
}
