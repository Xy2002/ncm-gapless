@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NcmGaplessMaintenance.ps1" %*
set "NCM_MAINTENANCE_EXIT=%errorlevel%"
echo.
pause
exit /b %NCM_MAINTENANCE_EXIT%
