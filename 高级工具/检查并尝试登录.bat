@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\upcnet.ps1" -Action demo
echo.
pause >nul
