@echo off
cd /d %~dp0
REM Quick build: DSH NEXT (dsh-desktop-next), compile + unpacked dir (NO ZIP)
echo ========================================================================
echo Quick Build - DSH NEXT (experimental, no ZIP)
echo ========================================================================
echo.
echo This will:
echo   - Pull dsh-desktop and align deepseek-harness to the pinned commit
echo   - Add dsh-desktop-next back to the root workspaces (stable excluded;
echo     beta stays installed because Next shares Beta's renderer build)
echo   - Apply the next overlay: startup-config code patch + ASAR re-enable
echo   - Run yarn install (keeps deps in sync with the freshly pulled code)
echo   - Build and package dsh-desktop-next to its dist\win-unpacked
echo   - NOT create any ZIP package
echo.
echo Optional: extra build-next.ps1 arguments are forwarded, e.g.
echo   quick-build-next.bat -ElectronVersion 44.4.5
echo   quick-build-next.bat -SkipPull
echo.
rem echo Press Ctrl+C to cancel, or
rem pause
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-next.ps1" -Target package-dir -SkipSubmodule %*
