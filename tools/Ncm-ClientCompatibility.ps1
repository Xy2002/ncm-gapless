# No client code is executed by this probe, including when called as SYSTEM.
function Assert-NcmOfficialClient {
    param([string]$ClientPath)
    $file = Get-Item -LiteralPath $ClientPath
    if ($file.Name -ine 'cloudmusic.exe') { throw 'NCM_CLIENT_NAME_INVALID' }
    $cursor = $file
    while ($cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NCM_STARTUP_TARGET_REPARSE_POINT' }
        $cursor = $(if ($cursor -is [IO.FileInfo]) { $cursor.Directory } else { $cursor.Parent })
    }
    $stream = [IO.File]::OpenRead($file.FullName)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'NCM_CLIENT_ARCHITECTURE_UNSUPPORTED' }
        $stream.Position = 0x3c; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset + 6 -gt $stream.Length) { throw 'NCM_CLIENT_ARCHITECTURE_UNSUPPORTED' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'NCM_CLIENT_ARCHITECTURE_UNSUPPORTED' }
    } finally { $reader.Dispose() }
    # The observed executable remains usable offline even if certificate revocation is unavailable.
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne '1d593a307e074368cb9539d3aa86577231c8b53c6e966d43bf7661a25f165ad3') {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne 'NetEase (Hangzhou) Network Co., Ltd') { throw 'NCM_CLIENT_PUBLISHER_UNVERIFIED' }
    }
    return [PSCustomObject]@{ path=$file.FullName; version=$file.VersionInfo.ProductVersion; sha256=$hash }
}
