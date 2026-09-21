@echo off
cd /d %~dp0
REM Quick build: stable channel, compile + unpacked dir (skip submodule, NO ZIP)
echo ========================================================================
echo Quick Build - Stable Channel (no ZIP)
echo ========================================================================
echo.
echo This will:
echo   - Align dsh-desktop submodule to pinned commit (overlay reset, then re-applied)
echo   - Skip submodule update
echo   - Run yarn install (fast when cached; always keeps deps in sync with the
echo     freshly pulled code - never skip it or packaging can crash)
echo   - Apply local overlays: electron (default 44.4.3), npmMinimalAgeGate,
echo     npmRebuild, tray icons, pnpm.mjs patch
echo   - Build and package dsh-plugin-desktop to dist\win-unpacked
echo   - NOT create any ZIP package
echo.
echo Optional: extra build.ps1 arguments are forwarded, e.g.
echo   quick-build-overlay.bat -ElectronVersion 45.0.0
echo.
rem echo Press Ctrl+C to cancel, or
rem pause
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Target package-dir -Overlay -SkipSubmodule %*
