# In-memory ACLs: no filesystem permissions, drives or tasks are changed.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Ncm-Maintenance.ps1')
$admin=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
$users=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
function New-FixtureAcl($Rights) {
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($admin)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,$Rights,'Allow')))
    return $acl
}
$volume=[PSCustomObject]@{FullName='D:\';Parent=$null;Attributes=[IO.FileAttributes]::Directory}
$apps=[PSCustomObject]@{FullName='D:\Apps';Parent=$volume;Attributes=[IO.FileAttributes]::Directory}
$client=[PSCustomObject]@{FullName='D:\Apps\CloudMusic';Parent=$apps;Attributes=[IO.FileAttributes]::Directory}
$protected=New-FixtureAcl 'ReadAndExecute'
$script:rootAcl=New-FixtureAcl 'CreateDirectories'
$script:rootRead=$false
function Get-Item { param($LiteralPath) return $client }
function Get-Acl {
    param($LiteralPath)
    if ($LiteralPath -eq 'D:\') { $script:rootRead=$true;return $script:rootAcl }
    return $protected
}
Assert-NcmAdminDirectory $client.FullName
if (-not $script:rootRead) { throw 'VOLUME_ROOT_WAS_NOT_CHECKED' }
Write-Host 'PASS protected tree allows only unrelated volume-root creation'
foreach ($rights in @('DeleteSubdirectoriesAndFiles','ChangePermissions','TakeOwnership','FullControl')) {
    $script:rootAcl=New-FixtureAcl $rights
    try { Assert-NcmAdminDirectory $client.FullName;throw 'EXPECTED_UNSAFE_ROOT_REJECTION' }
    catch { if ($_.ToString() -notmatch 'NCM_MAINTENANCE_TARGET_USER_WRITABLE') { throw } }
    Write-Host "PASS unsafe volume-root $rights rejected"
}
Write-Host '5 volume-root permission checks passed without filesystem changes.'
