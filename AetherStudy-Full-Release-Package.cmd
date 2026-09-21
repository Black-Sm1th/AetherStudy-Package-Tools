@echo off
setlocal
title AetherStudy Full Release Package

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

echo Starting clean full release build...
echo This mode rebuilds backend and client and uses maximum compression.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACK_SCRIPT%" -Edition Main -Clean
set "RESULT=%ERRORLEVEL%"
echo.

if not "%RESULT%"=="0" (
  echo Packaging failed with exit code %RESULT%.
) else (
  echo Packaging completed successfully.
  echo Output directory:
  echo %~dp0output
)

pause
exit /b %RESULT%
