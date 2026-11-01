@echo off
setlocal
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nvidia_monitor.ps1"

if %errorlevel% neq 0 (
    echo.
    echo  [!] Script terminated with error code %errorlevel%.
    pause
)

exit /b %errorlevel%