@echo off
setlocal

set "EDITION=%~1"
if not defined EDITION set "EDITION=Main"

if /i "%EDITION%"=="Main" (
  set "CLIENT_SOURCE=client-source-current"
  set "CLIENT_BUILD=client-build-current"
  set "QMAKE_EDITION_ARG="
) else if /i "%EDITION%"=="Government" (
  set "CLIENT_SOURCE=client-source-government"
  set "CLIENT_BUILD=client-build-government"
  set "QMAKE_EDITION_ARG=CONFIG+=edition_government"
) else (
  echo Unsupported client edition: %EDITION%
  echo Expected Main or Government.
  exit /b 2
)

echo Building AetherStudy client edition: %EDITION%
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%

cd /d "%~dp0"
if not exist "%CLIENT_BUILD%" mkdir "%CLIENT_BUILD%"
cd /d "%CLIENT_BUILD%"

rem Qt 5 and Qt 6 object files are ABI-incompatible. Remove old outputs
rem before qmake so a Qt upgrade cannot link stale Qt 5 objects.
if exist "release" rmdir /s /q "release"
if exist "debug" rmdir /s /q "debug"
if exist "Makefile" del /f /q "Makefile"

if defined QMAKE_EDITION_ARG (
  "D:\Qt\6.8.3\msvc2022_64\bin\qmake.exe" "..\%CLIENT_SOURCE%\MedClaw.pro" -spec win32-msvc "CONFIG+=release" "%QMAKE_EDITION_ARG%"
) else (
  "D:\Qt\6.8.3\msvc2022_64\bin\qmake.exe" "..\%CLIENT_SOURCE%\MedClaw.pro" -spec win32-msvc "CONFIG+=release"
)
if errorlevel 1 exit /b %errorlevel%

"D:\Qt\Tools\QtCreator\bin\jom\jom.exe" release
if errorlevel 1 exit /b %errorlevel%

rem Deploy Qt 6 runtime DLLs, plugins, QML modules, and WebEngine files beside AetherStudy.exe.
"D:\Qt\6.8.3\msvc2022_64\bin\windeployqt.exe" --release --qmldir "%~dp0%CLIENT_SOURCE%" --no-translations "release\AetherStudy.exe"
exit /b %errorlevel%
