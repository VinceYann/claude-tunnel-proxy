@echo off
setlocal
rem ============================================================
rem  Stop Claude Code local proxy (Windows)
rem  ---------------------------------------
rem  Kills only python.exe processes whose command line contains
rem  "proxy.py", so unrelated Python programs stay untouched.
rem ============================================================
cd /d "%~dp0"
set "KILLED=0"

for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter 'Name=''python.exe''' | Where-Object { $_.CommandLine -like '*proxy.py*' } | ForEach-Object { $_.ProcessId }"`) do (
    echo Killing PID %%P ...
    taskkill /f /pid %%P >nul 2>nul
    if errorlevel 1 (
        echo   [WARN] Could not kill PID %%P (already gone or access denied).
    ) else (
        echo   [OK] PID %%P terminated.
        set /a KILLED+=1
    )
)

echo.
if "%KILLED%"=="0" (
    echo No proxy.py process found. Nothing to stop.
) else (
    echo Done. Stopped %KILLED% proxy process(es).
)
echo.
pause
