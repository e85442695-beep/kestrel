@echo off
rem ================================================================
rem  Kestrel - run the game through the recompiled runtime
rem
rem  usage:  tools\run.cmd "D:\path\to\package"
rem ================================================================
setlocal

set "GAME=%~1"
if "%GAME%"=="" (
  echo usage: tools\run.cmd "D:\path\to\GTA6.Xbox.v1.0.2.1-..."
  exit /b 2
)

set "RT=%~dp0..\..\Kestrel-out\gta6rt.exe"
if not exist "%RT%" set "RT=%~dp0..\..\Leonida-out\gta6rt.exe"
if not exist "%RT%" (
  echo [!] gta6rt.exe not found - run tools\build.cmd first
  exit /b 1
)

echo [*] %RT%
echo [*] %GAME%\game_scarlett_master.exe
echo.
"%RT%" --run "%GAME%\game_scarlett_master.exe"
echo.
echo [*] exit code %ERRORLEVEL%
