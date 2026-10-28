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
function Get-NcmHttpsBytes {
    param([string]$Url,[int]$MaximumBytes)
    if (-not $Url.StartsWith('https://',[StringComparison]::Ordinal)) { throw 'NCM_UPDATE_HTTPS_REQUIRED' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 15000; $request.ReadWriteTimeout = 15000; $request.UserAgent = 'NCMGapless-Maintenance/1'
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
            $write = [long]$rule.FileSystemRights -band 0x500d0156
            if ($write -and $sid -notin $trusted) { throw 'NCM_MAINTENANCE_TARGET_USER_WRITABLE' }
        }
        # The system volume root permits creation of unrelated children; do not treat that as permission on this tree.
        $parent = $item.Parent
        if (-not $parent -or -not $parent.Parent) { break }
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
        $path=Join-Path $profile.LocalPath 'AppData\Local\NCMGapless\startup\attach.json'
        if (-not [IO.File]::Exists($path)) { continue }
        $value=Read-NcmSmallJson $path
        if (-not $value -or $value.PSObject.Properties.Name -notcontains 'runtimeDigest' -or $value.runtimeDigest -cne $Digest -or $value.clientPath -ine $ClientPath) { continue }
        $time=[IO.File]::GetLastWriteTimeUtc($path)
        if ($time -gt $latestTime) { $latest=$value; $latestTime=$time }
    }
    return $latest
}
