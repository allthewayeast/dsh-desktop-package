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
echo   - Apply local overlays: npmMinimalAgeGate, npmRebuild, tray icons,
echo     pnpm.mjs patch
echo   - Build and package dsh-plugin-desktop to dist\win-unpacked
echo   - NOT create any ZIP package
echo.
echo Electron / dsh runtime versions FOLLOW THE UPSTREAM DECLARATION by default.
echo Extra arguments are forwarded to build.ps1, e.g.
echo   quick-build-overlay.bat -ElectronVersion 44.5.1
echo   quick-build-overlay.bat -HarnessVersion 0.2.0-rc.2
echo   quick-build-overlay.bat -HarnessVersion 0.2.1-alpha.1
echo   (the commit is derived from tag dsh-v^<version^>; pass -HarnessCommit only
echo    if that version has no such tag, or to pin some other commit)
echo Do NOT repeat -Target / -Overlay / -SkipSubmodule here: duplicate named
echo parameters are a hard error under pwsh -File.
echo.
rem echo Press Ctrl+C to cancel, or
rem pause
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Target package-dir -Overlay -SkipSubmodule %*
