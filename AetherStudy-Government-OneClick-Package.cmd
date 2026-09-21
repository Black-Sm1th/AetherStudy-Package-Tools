@echo off
setlocal
title AetherStudy Government Fast One-Click Package

fltmc.exe >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges...
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo Running with administrator privileges.
echo.

set "PACK_SCRIPT=%~dp0package-all.ps1"

if not exist "%PACK_SCRIPT%" (
  echo Packaging script not found:
  echo %PACK_SCRIPT%
  pause
  exit /b 1
)

echo Starting optimized government edition package build...
echo Unchanged backend/client components will be reused automatically.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACK_SCRIPT%" -Edition Government -Fast
set "RESULT=%ERRORLEVEL%"
echo.

if not "%RESULT%"=="0" (
  echo Packaging failed with exit code %RESULT%.
) else (
  echo Packaging completed successfully.
  echo Output directory:
  echo %~dp0output-government
)

pause
exit /b %RESULT%
