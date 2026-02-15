@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

:: ============================================================================
:: Veyon Installation Tool Launcher
:: Handles elevation, validation, and logging
:: ============================================================================

set "SCRIPT_NAME=VeyonSetup.ps1"
set "LOG_FILE=%~dp0Launcher.log"
set "NEED_PAUSE=0"
set "PS_EXIT_CODE=0"

:: Initialize log file and clear old contents
(
    echo [%date% %time%] Launcher started
) > "%LOG_FILE%"

:: ============================================================================
:: Main Script
:: ============================================================================

cls
echo.
echo ================================================================================
echo  Veyon Installation Tool Launcher
echo ================================================================================
echo.
echo [INFO] Initializing...

(echo [%date% %time%] Checking for script file...) >> "%LOG_FILE%"

:: Verify script exists
if not exist "%SCRIPT_NAME%" (
    echo.
    echo [ERROR] CRITICAL: %SCRIPT_NAME% not found!
    echo.
    echo Expected location: %~dp0%SCRIPT_NAME%
    echo.
    (echo [%date% %time%] [ERROR] Script not found at %~dp0%SCRIPT_NAME%) >> "%LOG_FILE%"
    set "NEED_PAUSE=1"
    goto :End
)

echo [INFO] Found %SCRIPT_NAME%
(echo [%date% %time%] Script file found) >> "%LOG_FILE%"

:: ============================================================================
:: Elevation Check
:: ============================================================================

echo [INFO] Checking for administrator privileges...
(echo [%date% %time%] Checking admin privileges) >> "%LOG_FILE%"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo [INFO] Administrator access required - requesting elevation...
    echo Please click YES in the User Account Control prompt.
    echo.
    (echo [%date% %time%] User lacks admin privileges - requesting elevation) >> "%LOG_FILE%"
    
    :: Request elevation via PowerShell
    powershell -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\"' -Verb RunAs" 2>>"%LOG_FILE%"
    set "UAC_CODE=!errorLevel!"
    
    if !UAC_CODE! equ 0 (
        (echo [%date% %time%] Elevation request successful) >> "%LOG_FILE%"
    ) else (
        (echo [%date% %time%] Elevation denied or failed with code !UAC_CODE!) >> "%LOG_FILE%"
    )
    exit /b !UAC_CODE!
)

echo [SUCCESS] Running with administrator privileges
(echo [%date% %time%] Confirmed: running as administrator) >> "%LOG_FILE%"

:: ============================================================================
:: Execute PowerShell Script
:: ============================================================================

echo.
echo ================================================================================
echo  Launching Veyon Setup Script
echo ================================================================================
echo.

(echo [%date% %time%] Launching PowerShell script) >> "%LOG_FILE%"
(echo [%date% %time%] Command: powershell -NoProfile -ExecutionPolicy Bypass -File %SCRIPT_NAME%) >> "%LOG_FILE%"

:: Run the PowerShell script with proper error handling
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_NAME%" 2>>"%LOG_FILE%"

set "PS_EXIT_CODE=!errorLevel!"

(echo [%date% %time%] PowerShell script exited with code !PS_EXIT_CODE!) >> "%LOG_FILE%"

:: ============================================================================
:: Cleanup and Exit
:: ============================================================================

:End
echo.
echo ================================================================================
echo  Launcher Completed
echo ================================================================================
echo.
echo Log file: %LOG_FILE%
echo Exit code: %PS_EXIT_CODE%
echo.

(echo [%date% %time%] Launcher preparing to exit with code %PS_EXIT_CODE%) >> "%LOG_FILE%"

if "%NEED_PAUSE%"=="1" (
    echo.
    echo Press any key to close this window...
    (echo [%date% %time%] Paused for user due to error) >> "%LOG_FILE%"
    pause > nul
) else (
    if %PS_EXIT_CODE% neq 0 (
        echo.
        echo Script completed with status code: %PS_EXIT_CODE%
        echo.
        echo Press any key to close this window...
        pause > nul
    )
)

(echo [%date% %time%] Launcher closed) >> "%LOG_FILE%"
exit /b %PS_EXIT_CODE%

