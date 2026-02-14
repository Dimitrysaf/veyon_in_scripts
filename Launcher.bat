@echo off
setlocal
cd /d "%~dp0"

:: Elevation Check
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [INFO] Requesting Admin...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

:: Execution
powershell -NoProfile -ExecutionPolicy Bypass -File "VeyonSetup.ps1"
pause
