@echo off
REM DeepSeek Harness Desktop - One-click Build Script
REM Usage:
REM   build.bat                    - Default: yarn build
REM   build.bat dist-win-portable  - Windows portable ZIP
REM   build.bat dist-win           - Windows NSIS installer
REM   build.bat check              - Full CI check
REM   build.bat dev                - Build and launch GUI
REM   build.bat --no-proxy         - Disable proxy
REM   build.bat --skip-pull        - Skip submodule alignment (use existing source)
REM   build.bat --overlay          - Apply local overlays (electron pin, icons, pnpm patch)

setlocal enabledelayedexpansion

set "TARGET=build"
set "NO_PROXY_FLAG="
set "SKIP_INSTALL_FLAG="
set "SKIP_SUBMODULE_FLAG="
set "SKIP_PULL_FLAG="
set "OVERLAY_FLAG="

:parse_args
if "%~1"=="" goto end_parse
if /i "%~1"=="--no-proxy" (
    set "NO_PROXY_FLAG=-NoProxy"
    shift
    goto parse_args
)
if /i "%~1"=="--skip-install" (
    set "SKIP_INSTALL_FLAG=-SkipInstall"
    shift
    goto parse_args
)
if /i "%~1"=="--skip-submodule" (
    set "SKIP_SUBMODULE_FLAG=-SkipSubmodule"
    shift
    goto parse_args
)
if /i "%~1"=="--skip-pull" (
    set "SKIP_PULL_FLAG=-SkipPull"
    shift
    goto parse_args
)
if /i "%~1"=="--overlay" (
    set "OVERLAY_FLAG=-Overlay"
    shift
    goto parse_args
)
if "!TARGET!"=="build" (
    set "TARGET=%~1"
)
shift
goto parse_args

:end_parse

echo ========================================================================
echo DeepSeek Harness Desktop - Windows Build
echo ========================================================================
echo.
echo Target: %TARGET%
if defined OVERLAY_FLAG (
    echo Overlay: ON (local customizations)
) else (
    echo Overlay: OFF (upstream code only)
)
if defined NO_PROXY_FLAG (
    echo Proxy: Disabled
) else (
    echo Proxy: http://127.0.0.1:15715 [default]
)
echo.

where pwsh >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] PowerShell 7+ not found.
    echo Install from: https://github.com/PowerShell/PowerShell/releases
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Target %TARGET% %NO_PROXY_FLAG% %SKIP_INSTALL_FLAG% %SKIP_SUBMODULE_FLAG% %SKIP_PULL_FLAG% %OVERLAY_FLAG%

exit /b %ERRORLEVEL%