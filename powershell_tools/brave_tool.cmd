@echo off
setlocal
cd /d "%~dp0"

:: Launch PowerShell inline directly inside this Command Prompt window
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0brave_tool.ps1"

exit /b %errorlevel%