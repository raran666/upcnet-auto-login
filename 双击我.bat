@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0upcnet.ps1" -Action panel
echo.
pause >nul
