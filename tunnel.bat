@echo off
setlocal enabledelayedexpansion

rem ============================================================
rem  Claude Code tunnel launcher (Windows)
rem  ---------------------------------------
rem  Reads configuration from .env in the same folder.
rem  Copy .env.example to .env and edit it first.
rem ============================================================

cd /d "%~dp0"

rem ---- Load .env ----
if not exist ".env" (
    echo [ERROR] .env file not found.
    echo         Copy .env.example to .env and fill in your settings.
    pause
    exit /b 1
)
for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    set "%%a=%%b"
)

rem ---- Defaults ----
if "%PROXY_HOST%"=="" set "PROXY_HOST=127.0.0.1"
if "%PROXY_PORT%"=="" set "PROXY_PORT=1080"
if "%REMOTE_PORT%"=="" set "REMOTE_PORT=%PROXY_PORT%"

echo ============================================================
echo  Claude Code tunnel launcher
echo  ------------------------------
echo  SSH host   : %SSH_HOST%
echo  Proxy      : %PROXY_HOST%:%PROXY_PORT%
echo  Remote port: %REMOTE_PORT%
echo ============================================================
echo.

rem ---- Check prerequisites ----
set "MISSING="
where python >nul 2>nul  || set "MISSING=!MISSING! python"
where ssh    >nul 2>nul  || set "MISSING=!MISSING! ssh"
if defined MISSING (
    echo [ERROR] Missing on PATH:!MISSING!
    pause
    exit /b 1
)

rem ---- 1. Start proxy ----
echo [1/2] Starting local proxy (%PROXY_HOST%:%PROXY_PORT%)...
start "claude-proxy" /min cmd /c "python proxy.py"
timeout /t 2 /nobreak >nul

rem ---- 2. Open SSH reverse tunnel ----
echo [2/2] Opening SSH reverse tunnel to %SSH_HOST%...
echo       remote 127.0.0.1:%REMOTE_PORT% ^<- local 127.0.0.1:%PROXY_PORT%
echo.
echo       Press Ctrl+C to stop.
echo.
ssh -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -R %REMOTE_PORT%:127.0.0.1:%PROXY_PORT% %SSH_HOST%

echo.
echo Tunnel closed. Run stop-all.bat to kill the proxy.
pause
