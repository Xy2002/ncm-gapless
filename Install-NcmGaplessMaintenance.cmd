@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NcmGaplessMaintenance.ps1"
if errorlevel 1 pause
