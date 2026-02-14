@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

:: ============================================================================
:: Veyon Installation Tool Launcher
:: Handles elevation, validation, and logging
:: ============================================================================

set "SCRIPT_NAME=VeyonSetup.ps1"
set "LOG_FILE=%~dp0Launcher.log"
set "TIMESTAMP=%date% %time%"

:: Initialize log file
if not exist "%LOG_FILE%" (
    type nul > "%LOG_FILE%"
)

:: ============================================================================
:: Functions
:: ============================================================================

:LogMessage
:: Usage: call :LogMessage "message" "level"
:: Level: INFO, WARN, ERROR, SUCCESS
set "msg=%~1"
set "level=%~2"
if "%level%"=="" set "level=INFO"

echo [!TIMESTAMP!] [%level%] %msg% >> "%LOG_FILE%"
goto :eof

:LogError
set "msg=%~1"
echo [!TIMESTAMP!] [ERROR] %msg% >> "%LOG_FILE%"
color 0C
echo.
echo ================================================================================
echo  ERROR
echo ================================================================================
echo.
echo %msg%
echo.
echo For more details, see: %LOG_FILE%
echo.
color 07
goto :eof

:LogSuccess
set "msg=%~1"
echo [!TIMESTAMP!] [SUCCESS] %msg% >> "%LOG_FILE%"
color 0A
echo.
echo ================================================================================
echo  SUCCESS
echo ================================================================================
echo.
echo %msg%
echo.
color 07
goto :eof

:LogInfo
set "msg=%~1"
echo [!TIMESTAMP!] [INFO] %msg% >> "%LOG_FILE%"
echo [INFO] %msg%
goto :eof

:: ============================================================================
:: Main Script
:: ============================================================================

:Main
cls
echo.
echo ================================================================================
echo  Veyon Installation Tool Launcher
echo ================================================================================
echo.

call :LogMessage "Launcher started" "INFO"

:: Verify script exists
if not exist "%SCRIPT_NAME%" (
    call :LogError "Critical: %SCRIPT_NAME% not found in %~dp0"
    call :LogMessage "Expected location: %~dp0%SCRIPT_NAME%" "ERROR"
    set "NEED_PAUSE=1"
    goto :End
)

call :LogInfo "Found: %SCRIPT_NAME%"

:: Check if script is readable
for /f %%A in ('wmic datafile where name="%~dp0%SCRIPT_NAME:\=\\%" get filesize 2^>nul') do (
    if "%%A" equ "FileSize" goto :CheckAdminPrivileges
    if "%%A" gtr "100000" (
        call :LogInfo "Script size: %%A bytes"
        goto :CheckAdminPrivileges
    )
)

call :LogError "Script file appears corrupted or too small"
set "NEED_PAUSE=1"
goto :End

:: ============================================================================
:: Elevation Check
:: ============================================================================

:CheckAdminPrivileges
echo [INFO] Checking for administrator privileges...
net session >nul 2>&1
if %errorLevel% neq 0 (
    call :LogMessage "User does not have admin privileges - requesting elevation" "INFO"
    echo.
    echo [INFO] Requesting Administrator access...
    echo Please click YES in the User Account Control prompt.
    echo.
    
    :: Request elevation
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"%~f0\"' -Verb RunAs" 2>>"%LOG_FILE%"
    
    if !errorLevel! equ 0 (
        call :LogMessage "Elevation successful" "SUCCESS"
    ) else (
        call :LogMessage "Elevation denied or failed (error code: !errorLevel!)" "ERROR"
        call :LogError "Administrator privileges are required to run this tool."
        set "NEED_PAUSE=1"
    )
    exit /b !errorLevel!
)

call :LogSuccess "Running with administrator privileges"

:: ============================================================================
:: Execute PowerShell Script
:: ============================================================================

:ExecuteScript
echo.
echo ================================================================================
echo  Launching Veyon Setup Script
echo ================================================================================
echo.

call :LogMessage "Executing: powershell -NoProfile -ExecutionPolicy Bypass -File %SCRIPT_NAME%" "INFO"
echo [INFO] Starting PowerShell script execution...
echo.

:: Run the PowerShell script
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_NAME%" 2>>"%LOG_FILE%"

set "PS_EXIT_CODE=!errorLevel!"

if !PS_EXIT_CODE! equ 0 (
    call :LogMessage "PowerShell script completed successfully (exit code: !PS_EXIT_CODE!)" "SUCCESS"
) else (
    call :LogMessage "PowerShell script exited with code: !PS_EXIT_CODE!" "WARN"
)

goto :End

:: ============================================================================
:: Cleanup and Exit
:: ============================================================================

:End
echo.
echo ================================================================================
echo  Launcher Complete
echo ================================================================================
echo.
echo Log file: %LOG_FILE%
echo.

if "%NEED_PAUSE%"=="1" (
    call :LogMessage "Pausing due to error" "INFO"
    echo Press any key to close this window...
    pause > nul
) else (
    if !PS_EXIT_CODE! neq 0 (
        echo Script exited with a status code. Logs have been recorded.
        echo.
        echo Press any key to close this window...
        pause > nul
    )
)

call :LogMessage "Launcher closed" "INFO"
exit /b !PS_EXIT_CODE!

