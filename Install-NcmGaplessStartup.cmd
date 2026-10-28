@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NcmGaplessStartup.ps1" %*
set "NCM_HOOK_EXIT=%errorlevel%"
echo.
pause
exit /b %NCM_HOOK_EXIT%
