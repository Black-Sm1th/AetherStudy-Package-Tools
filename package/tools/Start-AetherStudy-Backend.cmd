@echo off
setlocal
title Start AetherStudy OpenClaw Backend

fltmc.exe >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges...
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "START_SCRIPT=%~dp0start-backend.ps1"
if not exist "%START_SCRIPT%" set "START_SCRIPT=%ProgramFiles%\AetherStudy\tools\start-backend.ps1"
if not exist "%START_SCRIPT%" set "START_SCRIPT=%LOCALAPPDATA%\Programs\AetherStudy\tools\start-backend.ps1"

if not exist "%START_SCRIPT%" (
  echo Backend start script was not found.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%START_SCRIPT%"
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" (
  echo OpenClaw backend is running on 127.0.0.1:18789.
) else (
  echo OpenClaw backend failed to start. Exit code: %RESULT%
)
pause
exit /b %RESULT%
