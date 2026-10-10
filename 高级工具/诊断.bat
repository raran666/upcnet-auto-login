@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\upcnet.ps1" -Action diag
echo.
pause >nul
