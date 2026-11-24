@echo off
rem ================================================================
rem  Kestrel - build the runtime against your own copy of the game
rem
rem  usage:  tools\build.cmd "D:\path\to\package" [out] [work]
rem ================================================================
setlocal EnableDelayedExpansion

set "GAME=%~1"
if "%GAME%"=="" (
  echo usage: tools\build.cmd "D:\path\to\GTA6.Xbox.v1.0.2.1-..." [out-dir] [work-dir]
  exit /b 2
)
set "OUT=%~2"
if "%OUT%"=="" set "OUT=%~dp0..\..\Kestrel-out"
set "WORK=%~3"
if "%WORK%"=="" set "WORK=%~dp0..\..\Kestrel-work"

rem --- toolchain, adjust if yours lives elsewhere ---
if "%LLVM_MC%"=="" set "LLVM_MC=%USERPROFILE%\.leonida\llvm-mc\llvm-mc.exe"
if not exist "%LLVM_MC%" (
  echo [!] llvm-mc with the AMDGPU target not found: %LLVM_MC%
  echo     build one with scripts\build_llvm_mc.ps1
  exit /b 1
)

set "VK="
if exist "C:\VulkanSDK" for /d %%d in ("C:\VulkanSDK\*") do set "VK=%%d\Bin"
if defined VK set "PATH=%VK%;%PATH%"
where spirv-as >nul 2>&1 || (
  echo [!] spirv-as not found - install the Vulkan SDK
  exit /b 1
)

rem gta6rt needs root signature 1.2 from the 26100 SDK; vcvars keeps picking the older one
if exist "C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0" (
  set "WindowsSdkDir=C:\Program Files (x86)\Windows Kits\10\"
  set "WindowsSDKVersion=10.0.26100.0\"
)

set "PY=%~dp0..\..\..\python\python.exe"
where python >nul 2>&1 && set "PY=python"

cd /d "%~dp0.."
echo [*] game  %GAME%
echo [*] out   %OUT%
echo [*] work  %WORK%
%PY% -I make_game.py --stages check,runtime --game "%GAME%" --out "%OUT%" --work "%WORK%" --no-tui
exit /b %ERRORLEVEL%
