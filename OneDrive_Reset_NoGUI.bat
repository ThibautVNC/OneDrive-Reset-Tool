@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: =====================================================================
::  OneDrive Reset Tool - no-GUI edition v1.0
::  Created by Thibaut VNC
::
::  Same job as the GUI version, but as a plain console script:
::    1. Stop OneDrive for the current user
::    2. Export the registry keys it is about to change to .reg files
::    3. Remove OneDrive / SharePoint entries from the Explorer nav pane
::    4. Delete the OneDrive configuration (signs out all accounts)
::    5. Start OneDrive again
::
::  Only HKEY_CURRENT_USER is changed: run this AS THE AFFECTED USER.
::  Local files are never deleted.
::
::  Usage:  OneDrive_Reset_NoGUI.bat        (asks for confirmation)
::          OneDrive_Reset_NoGUI.bat /Y     (no prompt, for RMM / login scripts)
:: =====================================================================

:: ---- Configuration: 1 = yes, 0 = no ---------------------------------
set "CLEAN_NAMESPACE=1"
:: 0 = only OneDrive / SharePoint entries, 1 = every entry (old script behaviour)
set "NAMESPACE_ALL=0"
set "RESET_CONFIG=1"
set "START_ONEDRIVE=1"
set "RESTART_EXPLORER=0"

:: ---- Constants ------------------------------------------------------
set "NS_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace"
set "OD_KEY=HKCU\Software\Microsoft\OneDrive"
set "BACKUP_ROOT=%LOCALAPPDATA%\OneDriveResetTool\Backups"

set "SKIP_PROMPT=0"
if /i "%~1"=="/y" set "SKIP_PROMPT=1"

title OneDrive Reset Tool - no GUI

:: ---- Backup folder for this run -------------------------------------
:: Timestamp via wmic; on builds where wmic is gone, fall back to a random name.
set "STAMP="
for /f "skip=1 tokens=1 delims=." %%T in ('wmic os get LocalDateTime 2^>nul') do if not defined STAMP set "STAMP=%%T"
if defined STAMP set "STAMP=!STAMP:~0,14!"
if not defined STAMP set "STAMP=%RANDOM%%RANDOM%"

set "BACKUP_DIR=%BACKUP_ROOT%\%STAMP%"
mkdir "%BACKUP_DIR%" 2>nul
if not exist "%BACKUP_DIR%" (
    echo Could not create the backup folder: %BACKUP_DIR%
    echo Nothing was changed.
    goto :End
)
set "LOG=%BACKUP_DIR%\log.txt"

echo.
call :Log "OneDrive Reset Tool (no GUI) v1.0 - Created by Thibaut VNC"
call :Log "User: %USERDOMAIN%\%USERNAME%"
call :Log "Backup folder: %BACKUP_DIR%"
echo.

:: ---- Confirmation ---------------------------------------------------
if "%SKIP_PROMPT%"=="0" (
    echo This closes OneDrive and signs out every OneDrive account of this user.
    echo Save and close open Office documents first.
    echo.
    set /p "ANSWER=Continue? [Y/N] "
    if /i not "!ANSWER!"=="Y" (
        call :Log "Cancelled by the user."
        goto :End
    )
    echo.
)

:: ---- Locate OneDrive.exe BEFORE the configuration is removed --------
set "OD_EXE="
if exist "%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe" set "OD_EXE=%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe"
if not defined OD_EXE if exist "%ProgramFiles%\Microsoft OneDrive\OneDrive.exe" set "OD_EXE=%ProgramFiles%\Microsoft OneDrive\OneDrive.exe"
if not defined OD_EXE if exist "%ProgramFiles(x86)%\Microsoft OneDrive\OneDrive.exe" set "OD_EXE=%ProgramFiles(x86)%\Microsoft OneDrive\OneDrive.exe"
if defined OD_EXE (call :Log "OneDrive found: !OD_EXE!") else (call :Log "OneDrive.exe not found in the standard locations.")

:: ---- 1. Stop OneDrive (only this user's processes) -------------------
taskkill /fi "USERNAME eq %USERNAME%" /f /im OneDrive.exe >nul 2>&1
if errorlevel 1 (call :Log "OneDrive was not running.") else (call :Log "Stopped OneDrive.")
:: Give it a moment to release its registry handles.
ping -n 3 127.0.0.1 >nul

:: ---- 2. Backups first; abort before deleting if one fails ------------
if "%CLEAN_NAMESPACE%"=="1" (
    reg query "%NS_KEY%" >nul 2>&1
    if not errorlevel 1 (
        reg export "%NS_KEY%" "%BACKUP_DIR%\Explorer-NameSpace.reg" /y >nul
        if errorlevel 1 (
            call :Log "ERROR: backup of the NameSpace key failed. Nothing was removed."
            goto :End
        )
        call :Log "Backed up %NS_KEY%"
    )
)
if "%RESET_CONFIG%"=="1" (
    reg query "%OD_KEY%" >nul 2>&1
    if not errorlevel 1 (
        reg export "%OD_KEY%" "%BACKUP_DIR%\OneDrive-Config.reg" /y >nul
        if errorlevel 1 (
            call :Log "ERROR: backup of the OneDrive key failed. Nothing was removed."
            goto :End
        )
        call :Log "Backed up %OD_KEY%"
    )
)

:: ---- 3. File Explorer navigation pane entries ------------------------
if "%CLEAN_NAMESPACE%"=="1" (
    if "%NAMESPACE_ALL%"=="1" (
        :: Old script behaviour: wipes Dropbox, Google Drive and iCloud entries too.
        reg delete "%NS_KEY%" /f >nul 2>&1
        call :Log "Removed ALL File Explorer navigation entries."
    ) else (
        :: Walk the subkeys and only remove the OneDrive / SharePoint ones.
        for /f "delims=" %%K in ('reg query "%NS_KEY%" 2^>nul ^| find "\{"') do call :HandleEntry "%%K"
    )
)

:: ---- 4. OneDrive configuration --------------------------------------
if "%RESET_CONFIG%"=="1" (
    reg query "%OD_KEY%" >nul 2>&1
    if errorlevel 1 (
        call :Log "No OneDrive configuration found, skipping."
    ) else (
        reg delete "%OD_KEY%" /f >nul
        if errorlevel 1 (
            call :Log "ERROR: could not remove the OneDrive configuration."
        ) else (
            call :Log "Removed the OneDrive configuration (all accounts signed out)."
        )
    )
)

:: ---- 5. Restart Explorer (optional) ----------------------------------
if "%RESTART_EXPLORER%"=="1" (
    taskkill /fi "USERNAME eq %USERNAME%" /f /im explorer.exe >nul 2>&1
    ping -n 4 127.0.0.1 >nul
    tasklist /fi "IMAGENAME eq explorer.exe" | find /i "explorer.exe" >nul || start "" explorer.exe
    call :Log "Restarted File Explorer."
)

:: ---- 6. Start OneDrive again ----------------------------------------
if "%START_ONEDRIVE%"=="1" (
    if defined OD_EXE (
        start "" "!OD_EXE!"
        call :Log "Started OneDrive."
    ) else (
        call :Log "OneDrive.exe not found; start or reinstall it manually."
    )
)

echo.
call :Log "Done. Sign in to OneDrive again and re-sync the SharePoint / Teams libraries."
call :Log "Undo: close OneDrive and double-click the .reg files in the backup folder."

:End
echo.
if "%SKIP_PROMPT%"=="0" pause
endlocal
exit /b

:: =====================================================================
::  Subroutines
:: =====================================================================

:: Removes one navigation pane entry if its display name mentions OneDrive
:: or SharePoint; otherwise it is left alone.
:HandleEntry
set "SUBKEY=%~1"
set "ENTRY="
for /f "tokens=2,*" %%A in ('reg query "%SUBKEY%" /ve 2^>nul ^| find "REG_SZ"') do set "ENTRY=%%B"
if not defined ENTRY set "ENTRY=(no name)"
echo !ENTRY! | find /i "OneDrive" >nul && goto :HandleEntryRemove
echo !ENTRY! | find /i "SharePoint" >nul && goto :HandleEntryRemove
call :Log "  [keep]   !ENTRY!"
goto :eof
:HandleEntryRemove
reg delete "%SUBKEY%" /f >nul 2>&1
call :Log "  [remove] !ENTRY!"
goto :eof

:: Writes one line to both the console and the log file.
:Log
echo %~1
>>"%LOG%" echo [%TIME:~0,8%] %~1
goto :eof
