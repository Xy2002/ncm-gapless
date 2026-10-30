# Shared signed-release validation. This file is installed in an admin-only directory.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:NcmReleaseFiles = @('MSIMG32.dll','ncm-gapless/tools/AutoAttach-NcmGapless.ps1',
    'ncm-gapless/tools/Ncm-StartupState.ps1','ncm-gapless/tools/Ncm-Cdp.ps1',
    'ncm-gapless/src/client-adapter.js','ncm-gapless/src/aac-timing.js',
    'ncm-gapless/src/gapless-engine.js','ncm-gapless/src/netease-gapless.js','ncm-gapless/LICENSES/CEF.txt')
$script:NcmFeedUrl = 'https://github.com/Xy2002/ncm-gapless/releases/download/windows-maintenance/windows-update.json'
$script:NcmAssetPrefix = 'https://github.com/Xy2002/ncm-gapless/releases/download/'
function Get-NcmDigest {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Write-NcmAtomicBytes {
    param([string]$Path,[byte[]]$Bytes)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Write-NcmMaintenanceJson {
    param([string]$Path,$Value)
    Write-NcmAtomicBytes $Path ((New-Object Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 12)))
}
function Read-NcmSignedRelease {
    param([byte[]]$Envelope,[string]$PublicKey)
    if ($Envelope.Length -gt 131072) { throw 'NCM_UPDATE_MANIFEST_TOO_LARGE' }
    $wrapper = [Text.Encoding]::UTF8.GetString($Envelope) | ConvertFrom-Json
    $bytes = [Convert]::FromBase64String($wrapper.payload)
    $signature = [Convert]::FromBase64String($wrapper.signature)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($PublicKey)
        if ($rsa.KeySize -lt 3072 -or -not $rsa.VerifyData($bytes,'SHA256',$signature)) { throw 'NCM_UPDATE_SIGNATURE_INVALID' }
    } finally { $rsa.Dispose() }
    $document = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($document.schema -ne 1 -or $document.channel -cne 'windows-maintenance' -or
        $document.sequence -isnot [ValueType] -or [long]$document.sequence -lt 1 -or [long]$document.sequence -ne $document.sequence -or
        $document.version -cnotmatch '^\d+\.\d+\.\d+(-[a-z0-9.]+)?$' -or
        $document.package.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $document.package.bytes -lt 1 -or $document.package.bytes -gt 8388608 -or
        -not $document.package.url.StartsWith($script:NcmAssetPrefix,[StringComparison]::Ordinal) -or
        $document.package.url -cnotmatch '^https://github\.com/Xy2002/ncm-gapless/releases/download/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+\.zip$') { throw 'NCM_UPDATE_MANIFEST_INVALID' }
    $properties = @($document.files.PSObject.Properties)
    if ($properties.Count -ne $script:NcmReleaseFiles.Count) { throw 'NCM_UPDATE_FILE_LIST_INVALID' }
    foreach ($entry in $properties) {
        if ($entry.Name -cnotin $script:NcmReleaseFiles -or $entry.Value.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $entry.Value.bytes -lt 1 -or $entry.Value.bytes -gt 2097152) { throw 'NCM_UPDATE_FILE_LIST_INVALID' }
    }
    return [PSCustomObject]@{ document=$document; digest=(Get-NcmDigest $bytes); envelope=$Envelope }
}
function Assert-NcmReleaseSequence {
    param($Release,$State)
    if ($Release.document.sequence -lt $State.highestSequence -or
        ($Release.document.sequence -eq $State.highestSequence -and $Release.digest -cne $State.highestDigest)) { throw 'NCM_UPDATE_ROLLBACK_REJECTED' }
}
function Read-NcmReleasePayload {
    param([byte[]]$Package,$Release)
    if ($Package.Length -ne $Release.document.package.bytes -or (Get-NcmDigest $Package) -cne $Release.document.package.sha256) { throw 'NCM_UPDATE_PACKAGE_HASH_INVALID' }
    Add-Type -AssemblyName System.IO.Compression
    $stream = New-Object IO.MemoryStream(,$Package)
    $archive = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read)
    $files = @{}
    try {
        if ($archive.Entries.Count -ne $script:NcmReleaseFiles.Count) { throw 'NCM_UPDATE_ARCHIVE_INVALID' }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -cnotin $script:NcmReleaseFiles -or $files.ContainsKey($entry.FullName)) { throw 'NCM_UPDATE_ARCHIVE_INVALID' }
            $expected = $Release.document.files.($entry.FullName)
            if ($entry.Length -ne $expected.bytes) { throw 'NCM_UPDATE_ARCHIVE_INVALID' }
            $inputStream = $entry.Open(); $outputStream = New-Object IO.MemoryStream
            try { $inputStream.CopyTo($outputStream); $bytes = $outputStream.ToArray() }
            finally { $inputStream.Dispose(); $outputStream.Dispose() }
            if ((Get-NcmDigest $bytes) -cne $expected.sha256) { throw 'NCM_UPDATE_FILE_HASH_INVALID' }
            $files[$entry.FullName] = $bytes
        }
    } finally { $archive.Dispose(); $stream.Dispose() }
    return $files
}
function Get-NcmRawHttpsBytes {
    param([string]$Url,[int]$MaximumBytes,[string]$Accept)
    if (-not $Url.StartsWith('https://',[StringComparison]::Ordinal)) { throw 'NCM_UPDATE_HTTPS_REQUIRED' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 15000; $request.ReadWriteTimeout = 15000; $request.UserAgent = 'NCMGapless-Maintenance/1'
    if ($Accept) { $request.Accept=$Accept }
    $response = $request.GetResponse()
    $outputStream = New-Object IO.MemoryStream
    try {
        if ($response.ResponseUri.Scheme -cne 'https' -or $response.ContentLength -gt $MaximumBytes) { throw 'NCM_UPDATE_DOWNLOAD_INVALID' }
        $stream = $response.GetResponseStream(); $buffer = New-Object byte[] 16384
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($outputStream.Length + $count -gt $MaximumBytes -or $clock.Elapsed.TotalSeconds -gt 45) { throw 'NCM_UPDATE_DOWNLOAD_TOO_LARGE' }
            $outputStream.Write($buffer,0,$count)
        }
        return ,$outputStream.ToArray()
    } finally { $outputStream.Dispose(); $response.Dispose() }
}
function Get-NcmHttpsBytes {
    param([string]$Url,[int]$MaximumBytes)
    try { return ,(Get-NcmRawHttpsBytes $Url $MaximumBytes) }
    catch {
        # Official asset API fallback avoids blocked github.com front-end downloads.
        # API metadata remains untrusted; the caller still verifies signature/hash.
        if ($Url -cnotmatch '^https://github\.com/Xy2002/ncm-gapless/releases/download/([a-zA-Z0-9._-]+)/([a-zA-Z0-9._-]+)$') { throw }
        $tag=$Matches[1]; $name=$Matches[2]
        $metadata=Get-NcmRawHttpsBytes ('https://api.github.com/repos/Xy2002/ncm-gapless/releases/tags/'+$tag) 1048576 'application/vnd.github+json'
        $release=[Text.Encoding]::UTF8.GetString($metadata)|ConvertFrom-Json
        $asset=@($release.assets|Where-Object {$_.name -ceq $name})
        if ($asset.Count -ne 1 -or $asset[0].id -isnot [ValueType] -or $asset[0].id -lt 1) { throw 'NCM_UPDATE_ASSET_MISSING' }
        return ,(Get-NcmRawHttpsBytes ('https://api.github.com/repos/Xy2002/ncm-gapless/releases/assets/'+[long]$asset[0].id) $MaximumBytes 'application/octet-stream')
    }
}
function Get-NcmMaintenanceInstallRelease {
    param([string]$SourceRoot,[string]$PublicKey,[switch]$Offline)
    $help = 'Download ncm-gapless-*-windows-maintenance.zip from https://github.com/Xy2002/ncm-gapless/releases, fully extract it, then run Install-NcmGaplessMaintenance.cmd. The source ZIP does not include the built maintenance files.'
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relative in @('updates','artifacts\windows-maintenance')) {
        $directory = Join-Path $SourceRoot $relative
        $manifestPath = Join-Path $directory 'windows-update.json'
        $packagePath = Join-Path $directory 'windows-payload.zip'
        if ([IO.File]::Exists($manifestPath) -and [IO.File]::Exists($packagePath)) {
            try {
                $envelope = [IO.File]::ReadAllBytes($manifestPath)
                $package = [IO.File]::ReadAllBytes($packagePath)
            } catch { throw "NCM_MAINTENANCE_PACKAGE_READ_FAILED: Cannot read windows-update.json and windows-payload.zip in '$directory'. $help Details: $_" }
            $release = Read-NcmSignedRelease $envelope $PublicKey
            $null = Read-NcmReleasePayload $package $release
            return [PSCustomObject]@{release=$release;package=$package}
        }
        foreach ($path in @($manifestPath,$packagePath)) {
            if (-not [IO.File]::Exists($path)) { $missing.Add($path) }
        }
    }
    if ($Offline) { throw "NCM_MAINTENANCE_PACKAGE_MISSING: No complete local pair of windows-update.json and windows-payload.zip was found. Missing: $($missing -join ', '). $help Alternatively, rerun without -Offline to download the signed release automatically." }
    Write-Host 'Local maintenance files (windows-update.json and windows-payload.zip) are missing or incomplete. Downloading the signed Windows maintenance release...'
    try { $envelope = Get-NcmHttpsBytes $script:NcmFeedUrl 131072 }
    catch { throw "NCM_MAINTENANCE_DOWNLOAD_FAILED: Cannot download windows-update.json; windows-payload.zip is also required. $help Check your network and retry. Details: $_" }
    # Only the signed manifest may supply the payload URL. Never download or run an installer script.
    $release = Read-NcmSignedRelease $envelope $PublicKey
    try { $package = Get-NcmHttpsBytes $release.document.package.url $release.document.package.bytes }
    catch { throw "NCM_MAINTENANCE_DOWNLOAD_FAILED: Cannot download windows-payload.zip for windows-update.json. $help Check your network and retry. Details: $_" }
    $null = Read-NcmReleasePayload $package $release
    Write-Host "Downloaded and verified Windows maintenance release $($release.document.version)."
    return [PSCustomObject]@{release=$release;package=$package}
}
function Wait-NcmMaintenanceClientExit {
    param([string]$ClientPath,[ValidateRange(1,900)][int]$TimeoutSeconds=300)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $announced=$false
    while (@(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" -ErrorAction Stop |
        Where-Object { -not $_.ExecutablePath -or $_.ExecutablePath -ieq $ClientPath }).Count) {
        if (-not $announced) {
            Write-Host '请从托盘菜单彻底退出网易云。安装器正在等待进程结束，退出后会自动继续；按 Ctrl+C 可取消。'
            $announced=$true
        }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'NCM_MAINTENANCE_CLIENT_EXIT_TIMEOUT: 网易云仍在运行，尚未开始安装。请彻底退出后重新运行安装器。' }
        Start-Sleep -Milliseconds 500
    }
}
function Wait-NcmMaintenanceSetup {
    param([string]$Root,[string]$InstallationId,[ValidateRange(1,900)][int]$TimeoutSeconds=300)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $announced=$false
    Write-Host '正在确认首次安装/修复结果，请暂时保持网易云关闭。'
    do {
        $config=Read-NcmSmallJson (Join-Path $Root 'config.json')
        if ($config) {
            if ($config.owner -cne 'ncm-gapless-maintenance-v1') { throw 'NCM_MAINTENANCE_CONFIG_INVALID' }
            if ($config.PSObject.Properties.Name -notcontains 'installationId' -or $config.installationId -cne $InstallationId) { throw 'NCM_MAINTENANCE_INSTALLATION_CHANGED: 安装配置已被另一次操作替换，请重新运行安装器。' }
            if ($config.PSObject.Properties.Name -contains 'enabled' -and -not $config.enabled) { throw 'NCM_MAINTENANCE_SETUP_CANCELLED: 自动维护已停用，安装确认已取消。' }
        }
        $receipt=Read-NcmSmallJson (Join-Path $Root 'setup-result.json')
        if ($config -and $receipt -and $receipt.PSObject.Properties.Name -contains 'installationId' -and $receipt.installationId -ceq $InstallationId) {
            if ($receipt.result -in @('healthy','repaired','updated','rolled-back')) {
                if ($receipt.error) { Write-Warning "启动文件已就绪，但本轮维护检查报告 $($receipt.error)。可运行 Get-NcmGaplessStatus.cmd 查看详情。" }
                return $receipt
            }
            if ($receipt.result -eq 'failed') { throw "NCM_MAINTENANCE_INITIAL_REPAIR_FAILED: 首次修复失败：$($receipt.error)。请保持网易云关闭，运行 Get-NcmGaplessStatus.cmd 查看详情后重试。" }
            if ($receipt.result -eq 'disabled') { throw 'NCM_MAINTENANCE_SETUP_CANCELLED: 自动维护已停用。' }
            if ($receipt.result -eq 'deferred-client-running' -and -not $announced) {
                Write-Host '检测到网易云在安装期间重新运行。请彻底退出并保持关闭，维护任务会继续修复。'
                $announced=$true
            }
        }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'NCM_MAINTENANCE_SETUP_PENDING: 维护任务已注册，首次修复尚未确认完成。请保持网易云关闭后重试安装器，或运行 Get-NcmGaplessStatus.cmd 查看结果；任务仍会按分钟继续检查。' }
        Start-Sleep -Milliseconds 500
    } while ($true)
}
function Assert-NcmAdminDirectory {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NCM_MAINTENANCE_UNSAFE_PATH' }
        $acl = Get-Acl -LiteralPath $item.FullName
        $trusted = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'NCM_MAINTENANCE_TARGET_USER_OWNED' }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
            $sid = $rule.IdentityReference.Value
            # Creating unrelated children at a volume root does not permit replacing
            # an existing protected tree. DELETE_CHILD and ACL/owner changes do.
            $mask = $(if (-not $item.Parent) { 0x500d0150 } else { 0x500d0156 })
            $write = [long]$rule.FileSystemRights -band $mask
            if ($write -and $sid -notin $trusted) { throw 'NCM_MAINTENANCE_TARGET_USER_WRITABLE' }
        }
        $parent = $item.Parent
        if (-not $parent) { break }
        $item = $parent
    }
}
function Get-NcmStoredRelease {
    param([string]$Root,$Pointer,[string]$PublicKey)
    if ($Pointer.digest -cnotmatch '^[0-9a-f]{64}$') { throw 'NCM_UPDATE_POINTER_INVALID' }
    $directory = Join-Path $Root ('releases\' + $Pointer.digest)
    $release = Read-NcmSignedRelease ([IO.File]::ReadAllBytes((Join-Path $directory 'manifest.json'))) $PublicKey
    if ($release.digest -cne $Pointer.digest) { throw 'NCM_UPDATE_POINTER_INVALID' }
    $files = Read-NcmReleasePayload ([IO.File]::ReadAllBytes((Join-Path $directory 'package.zip'))) $release
    return [PSCustomObject]@{ release=$release; files=$files }
}
function Read-NcmSmallJson {
    param([string]$Path)
    try {
        $stream=[IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $buffer=New-Object byte[] 32769; $length=0
            while ($length -lt $buffer.Length -and ($count=$stream.Read($buffer,$length,$buffer.Length-$length)) -gt 0) { $length+=$count }
            if ($length -gt 32768) { return $null }
            return ([Text.Encoding]::UTF8.GetString($buffer,0,$length)|ConvertFrom-Json)
        } finally { $stream.Dispose() }
    } catch { return $null }
}
function Get-NcmActivationHealth {
    param([string]$ClientPath,[string]$Digest)
    $latest=$null; $latestTime=[DateTime]::MinValue
    foreach ($profile in @(Get-CimInstance Win32_UserProfile -Filter 'Special=False')) {
        $path=Join-Path $profile.LocalPath 'AppData\Local\NCMGapless\startup\attach-health.json'
        if (-not [IO.File]::Exists($path)) { $path=Join-Path $profile.LocalPath 'AppData\Local\NCMGapless\startup\attach.json' }
        if (-not [IO.File]::Exists($path)) { continue }
        $value=Read-NcmSmallJson $path
        if (-not $value -or $value.PSObject.Properties.Name -notcontains 'runtimeDigest' -or $value.runtimeDigest -cne $Digest -or $value.clientPath -ine $ClientPath) { continue }
        $time=[IO.File]::GetLastWriteTimeUtc($path)
        if ($time -gt $latestTime) { $latest=$value; $latestTime=$time }
    }
    return $latest
}
