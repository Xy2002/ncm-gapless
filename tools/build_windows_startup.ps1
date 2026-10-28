[CmdletBinding()]
param([switch]$NoPublish)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'NCM_BUILD_REQUIRES_MSVC_X64' }
$tools = Get-ChildItem -LiteralPath (Join-Path $visualStudio 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkVersion = Get-ChildItem -LiteralPath (Join-Path $sdk 'Include') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h') } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVersion) { throw 'NCM_BUILD_REQUIRES_WINDOWS_SDK' }
$env:INCLUDE = (@((Join-Path $tools.FullName 'include')) + @('ucrt','shared','um','winrt' | ForEach-Object { Join-Path $sdkVersion.FullName $_ })) -join ';'
$env:LIB = @((Join-Path $tools.FullName 'lib\x64'), (Join-Path $sdk "Lib\$($sdkVersion.Name)\ucrt\x64"), (Join-Path $sdk "Lib\$($sdkVersion.Name)\um\x64")) -join ';'
$compiler = Join-Path $tools.FullName 'bin\Hostx64\x64\cl.exe'
$linker = Join-Path $tools.FullName 'bin\Hostx64\x64\link.exe'
$librarian = Join-Path $tools.FullName 'bin\Hostx64\x64\lib.exe'
$outputBase = Join-Path $root 'artifacts\windows-startup'
$output = Join-Path $outputBase ('build-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
Push-Location $output
try {
    $definition = '/DEF:' + (Join-Path $root 'native\windows\msimg32.def')
    & $compiler /nologo /c /MT /O2 /W4 /std:c++14 /EHsc /guard:cf (Join-Path $root 'native\windows\startup.cpp') /Fostartup.obj
    if ($LASTEXITCODE -ne 0) { throw 'NCM_NATIVE_COMPILE_FAILED' }
    & $librarian /nologo /MACHINE:X64 $definition /OUT:MSIMG32.lib
    if ($LASTEXITCODE -ne 0) { throw 'NCM_NATIVE_EXPORT_BUILD_FAILED' }
    & $linker /nologo /DLL /MACHINE:X64 /GUARD:CF /DYNAMICBASE /NXCOMPAT /Brepro /OUT:MSIMG32.dll /IMPLIB:MSIMG32-final.lib MSIMG32.exp startup.obj version.lib ws2_32.lib
    if ($LASTEXITCODE -ne 0) { throw 'NCM_NATIVE_BUILD_FAILED' }
    if (-not $NoPublish) {
        Copy-Item -LiteralPath (Join-Path $output 'MSIMG32.dll') -Destination (Join-Path $root 'native\windows\MSIMG32.dll') -Force
        Copy-Item -LiteralPath (Join-Path $output 'MSIMG32.dll') -Destination (Join-Path $outputBase 'MSIMG32.dll') -Force
    }
    Get-FileHash -LiteralPath (Join-Path $output 'MSIMG32.dll') -Algorithm SHA256 | Select-Object Hash,Path
} finally { Pop-Location }
