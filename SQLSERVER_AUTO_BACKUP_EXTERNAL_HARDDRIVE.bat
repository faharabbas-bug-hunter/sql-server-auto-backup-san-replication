@echo off
:: ====================================================================
:: Script created by Syed Fahar Abbas
:: Comprehensive Batch Script to:
:: 1. Verify/Request Administrator privileges and create a stable script copy.
:: 2. Grant NT AUTHORITY\SYSTEM database privileges and perform full SQL Server backup.
:: 3. Detect, or automatically download and silently install, WinRAR for compression.
:: 4. Compress the raw backup (.bak) into a high-compression RAR archive (.rar) and cleanup.
:: 5. Authenticate and map a network SAN share or external drive, auto-create directories, and copy the archive.
:: 6. Register/Update an advanced Windows Scheduled Task for daily execution at 8:00 AM with robust power/retry settings.
:: ====================================================================

SETLOCAL ENABLEDELAYEDEXPANSION

:: Capture the execution mode argument passed to the script (e.g., "AUTORUN" when triggered by Task Scheduler)
SET "RUN_MODE=%~1"

:: Step 0A: Ensure the script runs with elevated (Administrator) privileges for manual executions
IF /I NOT "%RUN_MODE%"=="AUTORUN" (
    net session >nul 2>&1
    IF NOT !ERRORLEVEL! EQU 0 (
        echo This script needs Administrator privileges to register the scheduled task. Requesting elevation...
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        EXIT /B
    )
)

:: ====================================================================
:: CONFIGURATION VARIABLES
:: NOTE: Provide valid database credentials, instance name, and paths below.
:: ====================================================================
SET SERVER_NAME=
SET DB_USER=
SET DB_PASS=
SET DB_NAME=
SET BACKUP_DIR=

:: --- Network SAN / External Drive Configuration ---
SET SAN_DRIVE=Z:
SET SAN_PATH=\\ip address\Backups
SET SAN_USER=
SET SAN_PASS=
SET EXTERNAL_DIR=Z:\
:: ====================================================================

:: Use the script file name (without extension) as the unique Scheduled Task name
SET TASK_NAME=%~n0

:: Ensure local backup destination directory exists
IF NOT EXIST "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

:: Create a stable working copy of the script inside a subfolder for reliable scheduled task execution
SET "SCRIPT_STORE_DIR=%BACKUP_DIR%\Scripts"
IF NOT EXIST "%SCRIPT_STORE_DIR%" mkdir "%SCRIPT_STORE_DIR%"
SET "STABLE_SCRIPT_PATH=%SCRIPT_STORE_DIR%\%~n0.bat"
copy /Y "%~f0" "%STABLE_SCRIPT_PATH%" >nul

:: Initialize and create the execution log file, overwriting any previous log
SET LOG_FILE=%BACKUP_DIR%\backup_log.txt
IF EXIST "%LOG_FILE%" del "%LOG_FILE%"

echo ==================================================================== > "%LOG_FILE%"
echo Execution Started: %DATE% %TIME% >> "%LOG_FILE%"
echo Running from: %~f0 >> "%LOG_FILE%"
echo Stable copy at: %STABLE_SCRIPT_PATH% >> "%LOG_FILE%"
echo Target External Directory: %EXTERNAL_DIR% >> "%LOG_FILE%"
echo ==================================================================== >> "%LOG_FILE%"

:: Generate a precise Date and Time timestamp (YYYY-MM-DD_HH-MM-SS) via WMIC for unique backup filenames
FOR /f "tokens=2 delims==" %%a in ('wmic OS Get localdatetime /value') do set dt=%%a
SET YY=%dt:~2,2%
SET YYYY=%dt:~0,4%
SET MM=%dt:~4,2%
SET DD=%dt:~6,2%
SET HH=%dt:~8,2%
SET Min=%dt:~10,2%
SET Sec=%dt:~12,2%

SET TIMESTAMP=%YYYY%-%MM%-%DD%_%HH%-%Min%-%Sec%
SET BACKUP_PATH=%BACKUP_DIR%\%DB_NAME%_%TIMESTAMP%.bak
SET RAR_PATH=%BACKUP_DIR%\%DB_NAME%_%TIMESTAMP%.rar

:: Determine whether to use Windows Integrated Authentication (-E) or SQL Server Credentials (-U / -P)
IF "%DB_USER%"=="" (
    SET "AUTH_FLAGS=-E"
) ELSE (
    SET AUTH_FLAGS=-U %DB_USER% -P %DB_PASS%
)

:: ---------------------------------------------------------------
:: Automatically grant NT AUTHORITY\SYSTEM login and sysadmin role permissions 
:: to prevent permission denied errors (Msg 916) when executed via Task Scheduler as SYSTEM.
:: ---------------------------------------------------------------
echo [%DATE% %TIME%] Granting NT AUTHORITY\SYSTEM access to SQL Server... >> "%LOG_FILE%"
sqlcmd -S "%SERVER_NAME%" -E -Q "IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS; ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];" >> "%LOG_FILE%" 2>&1

echo [%DATE% %TIME%] Checking effective SQL Server login/permissions... >> "%LOG_FILE%"
sqlcmd -S "%SERVER_NAME%" %AUTH_FLAGS% -Q "SELECT SYSTEM_USER AS CurrentLogin, IS_SRVROLEMEMBER('sysadmin') AS IsSysAdmin;" >> "%LOG_FILE%" 2>&1

echo.
echo ====================================================================
echo STEP 1: Running immediate backup for database '%DB_NAME%'...
echo ====================================================================
echo [%DATE% %TIME%] Starting SQL Backup... >> "%LOG_FILE%"

:: Execute sqlcmd to generate a full database backup with a formatted media name
sqlcmd -S "%SERVER_NAME%" %AUTH_FLAGS% -Q "BACKUP DATABASE [%DB_NAME%] TO DISK = N'%BACKUP_PATH%' WITH FORMAT, MEDIANAME = 'SQLServerBackups', NAME = 'Full Backup of %DB_NAME%';" >> "%LOG_FILE%" 2>&1

IF !ERRORLEVEL! EQU 0 (
    echo [SUCCESS] SQL Backup completed successfully!
    echo File saved to: %BACKUP_PATH%
    echo [%DATE% %TIME%] SQL Backup Successful: %BACKUP_PATH% >> "%LOG_FILE%"
) ELSE (
    echo [ERROR] Database backup failed. Check log file for details: %LOG_FILE%
    echo [%DATE% %TIME%] [ERROR] SQL Backup Failed with ERRORLEVEL !ERRORLEVEL! >> "%LOG_FILE%"
    GOTO SCHEDULE_TASK
)

echo.
echo ====================================================================
echo STEP 2: Checking for WinRAR / Rar.exe utility...
echo ====================================================================

:: Search standard Program Files locations and local Tools directory for existing Rar.exe binary
SET "RAR_EXE="
IF EXIST "%ProgramFiles%\WinRAR\Rar.exe" SET "RAR_EXE=%ProgramFiles%\WinRAR\Rar.exe"
IF EXIST "%ProgramFiles(x86)%\WinRAR\Rar.exe" SET "RAR_EXE=%ProgramFiles(x86)%\WinRAR\Rar.exe"
IF EXIST "C:\Program Files\WinRAR\Rar.exe" SET "RAR_EXE=C:\Program Files\WinRAR\Rar.exe"
IF EXIST "C:\Program Files (x86)\WinRAR\Rar.exe" SET "RAR_EXE=C:\Program Files (x86)\WinRAR\Rar.exe"
IF EXIST "%BACKUP_DIR%\Tools\WinRAR\Rar.exe" SET "RAR_EXE=%BACKUP_DIR%\Tools\WinRAR\Rar.exe"

:: If WinRAR command-line utility is missing, attempt to download and install it silently
IF "%RAR_EXE%"=="" (
    echo WinRAR command-line tool ^(Rar.exe^) not found. Attempting to download...
    echo [%DATE% %TIME%] WinRAR not found. Attempting download... >> "%LOG_FILE%"

    IF NOT EXIST "%BACKUP_DIR%\Tools" mkdir "%BACKUP_DIR%\Tools"

    :: Download WinRAR installer via PowerShell using TLS 1.2 security protocol
    powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $url='https://www.rarlab.com/rar/winrar-x64-621.exe'; $output='%BACKUP_DIR%\Tools\wrar.exe'; (New-Object System.Net.WebClient).DownloadFile($url, $output); Write-Host 'Download complete.' } catch { Write-Host \"Download failed: $_\"; exit 1 }" >> "%LOG_FILE%" 2>&1

    IF EXIST "%BACKUP_DIR%\Tools\wrar.exe" (
        echo Installing WinRAR utility components silently...
        start /wait "" "%BACKUP_DIR%\Tools\wrar.exe" /s

        :: Re-verify path to Rar.exe after silent installation completes
        SET "RAR_EXE="
        IF EXIST "%ProgramFiles%\WinRAR\Rar.exe" SET "RAR_EXE=%ProgramFiles%\WinRAR\Rar.exe"
        IF EXIST "%ProgramFiles(x86)%\WinRAR\Rar.exe" SET "RAR_EXE=%ProgramFiles(x86)%\WinRAR\Rar.exe"
        IF EXIST "C:\Program Files\WinRAR\Rar.exe" SET "RAR_EXE=C:\Program Files\WinRAR\Rar.exe"
        IF EXIST "C:\Program Files (x86)\WinRAR\Rar.exe" SET "RAR_EXE=C:\Program Files (x86)\WinRAR\Rar.exe"
        IF EXIST "%BACKUP_DIR%\Tools\WinRAR\Rar.exe" SET "RAR_EXE=%BACKUP_DIR%\Tools\WinRAR\Rar.exe"
    )
)

echo.
echo ====================================================================
echo STEP 3: Compressing .bak file into .rar...
echo ====================================================================

IF NOT "%RAR_EXE%"=="" (
    echo [SUCCESS] WinRAR is available at: %RAR_EXE%
    echo [%DATE% %TIME%] WinRAR verified successfully at %RAR_EXE% >> "%LOG_FILE%"

    :: Compress backup using maximum compression (-m5) and exclude file paths (-ep)
    "%RAR_EXE%" a -m5 -ep "%RAR_PATH%" "%BACKUP_PATH%" >> "%LOG_FILE%" 2>&1

    IF !ERRORLEVEL! EQU 0 (
        echo [SUCCESS] Backup compressed successfully to: %RAR_PATH%
        echo [%DATE% %TIME%] Compression Successful: %RAR_PATH% >> "%LOG_FILE%"

        echo Cleaning up raw .bak file...
        del /f /q "%BACKUP_PATH%"
        echo [%DATE% %TIME%] Raw .bak file deleted. >> "%LOG_FILE%"
    ) ELSE (
        echo [WARNING] Compression encountered an issue, keeping the original .bak file.
        echo [%DATE% %TIME%] [WARNING] Compression failed with ERRORLEVEL !ERRORLEVEL! >> "%LOG_FILE%"
    )
) ELSE (
    echo [ERROR] Could not download or locate WinRAR automatically.
    echo [%DATE% %TIME%] [ERROR] WinRAR could not be downloaded or located. >> "%LOG_FILE%"
)

echo.
echo ====================================================================
echo STEP 4: Authenticating and Copying compressed archive to SAN / External Drive...
echo ====================================================================

IF EXIST "%RAR_PATH%" (
    :: Map Network SAN share to the designated drive letter if SAN path credentials are provided
    IF NOT "%SAN_PATH%"=="" (
        echo [%DATE% %TIME%] Connecting SAN share %SAN_PATH% to drive %SAN_DRIVE%... >> "%LOG_FILE%"
        
        :: Drop any existing connection to avoid network conflict error 85
        net use "%SAN_DRIVE%" /delete >nul 2>&1

        net use "%SAN_DRIVE%" "%SAN_PATH%" "%SAN_PASS%" /user:"%SAN_USER%" /persistent:no >> "%LOG_FILE%" 2>&1
        
        IF !ERRORLEVEL! EQU 0 (
            echo [%DATE% %TIME%] Successfully connected to SAN share on %SAN_DRIVE%. >> "%LOG_FILE%"
        ) else (
            echo [%DATE% %TIME%] [ERROR] net use failed with errorlevel !ERRORLEVEL!. Check IP, Share Name, and credentials. >> "%LOG_FILE%"
            echo [ERROR] Failed to connect to SAN share. Skipping external copy.
            GOTO SKIP_EXTERNAL_COPY
        )
    )

    :: Auto-create destination directory on the external drive or SAN if it does not exist
    IF NOT EXIST "%EXTERNAL_DIR%" (
        echo Target folder not found on external destination. Creating directory: %EXTERNAL_DIR%...
        echo [%DATE% %TIME%] Target folder not found. Creating directory: %EXTERNAL_DIR%... >> "%LOG_FILE%"
        mkdir "%EXTERNAL_DIR%" >nul 2>&1
    )

    :: Verify target existence and copy the compressed RAR archive over
    IF EXIST "%EXTERNAL_DIR%" (
        echo [%DATE% %TIME%] Copying %RAR_PATH% to "%EXTERNAL_DIR%\"... >> "%LOG_FILE%"
        copy /Y "%RAR_PATH%" "%EXTERNAL_DIR%\" >nul 2>&1

        IF !ERRORLEVEL! EQU 0 (
            echo [SUCCESS] Backup successfully copied to External/SAN Drive: %EXTERNAL_DIR%
            echo [%DATE% %TIME%] External Copy Successful: %EXTERNAL_DIR%\%DB_NAME%_%TIMESTAMP%.rar >> "%LOG_FILE%"
        ) ELSE (
            echo [ERROR] Failed to copy backup to External Drive/SAN.
            echo [%DATE% %TIME%] [ERROR] External Copy Failed with ERRORLEVEL !ERRORLEVEL! >> "%LOG_FILE%"
        )
    ) ELSE (
        echo [WARNING] Could not create or access external directory '%EXTERNAL_DIR%'.
        echo Check network connection, permissions, or if the drive is plugged in.
        echo [%DATE% %TIME%] [WARNING] External directory '%EXTERNAL_DIR%' could not be created/accessed. Skipping copy. >> "%LOG_FILE%"
    )
) ELSE (
    echo [SKIP] RAR file not found. Skipping copy to external drive.
    echo [%DATE% %TIME%] [SKIP] RAR file missing, skipping external drive copy. >> "%LOG_FILE%"
)

:SKIP_EXTERNAL_COPY

:SCHEDULE_TASK

:: Skip task registration if script is currently executing in automated mode
IF /I "%RUN_MODE%"=="AUTORUN" (
    echo [%DATE% %TIME%] AUTORUN mode - scheduled task registration left untouched. >> "%LOG_FILE%"
    GOTO END_SCRIPT
)

echo.
echo ====================================================================
echo STEP 5: Creating/Updating daily scheduled task ('%TASK_NAME%') for 8:00 AM...
echo ====================================================================

echo [%DATE% %TIME%] Registering scheduled task '%TASK_NAME%'... >> "%LOG_FILE%"

:: Delete existing task if present (suppressing output/errors if task does not exist on first run)
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

:: Create a new scheduled task running daily at 08:00 AM under the SYSTEM account with highest privileges
schtasks /Create /TN "%TASK_NAME%" /TR "cmd.exe /D /C CALL \"\"%STABLE_SCRIPT_PATH%\"\" AUTORUN" /SC DAILY /ST 08:00 /RU "SYSTEM" /RL HIGHEST /F >> "%LOG_FILE%" 2>&1

:: Configure advanced task settings via PowerShell (start when available, run on battery power, multi-instance ignore, and automatic retry policy)
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $t=Get-ScheduledTask -TaskName '%TASK_NAME%'; $s=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5); Set-ScheduledTask -TaskName '%TASK_NAME%' -Settings $s;" >> "%LOG_FILE%" 2>&1

echo.
echo ====================================================================
echo STEP 6: Confirming task registration...
echo ====================================================================
:: Query the scheduled task details and filter for key configuration parameters
schtasks /Query /TN "%TASK_NAME%" /FO LIST | findstr /I /C:"TaskName:" /C:"Next Run Time:" /C:"Status:" /C:"Logon Mode:" /C:"Run As User:" /C:"Run Level:" /C:"Task To Run:" 

:END_SCRIPT
echo ====================================================================
echo Process completed! Check log at: %LOG_FILE%
echo ====================================================================
echo Execution Ended: %DATE% %TIME% >> "%LOG_FILE%"
echo -------------------------------------------------------------------- >> "%LOG_FILE%"