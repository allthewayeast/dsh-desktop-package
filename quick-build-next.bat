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
echo   - Apply the next overlay: startup-config code patch (+ place the new
echo     startup-config.ts files); ASAR itself is upstream-owned, no patch
echo   - Inject build.buildVersion so the exe reports 2.0.x.0 (not 2.0.0.0)
echo   - Run yarn install (keeps deps in sync with the freshly pulled code)
echo   - Build and package dsh-desktop-next to its dist\win-unpacked
echo   - NOT create any ZIP package
echo.
echo Optional: extra build-next.ps1 arguments are forwarded, e.g.
echo   quick-build-next.bat -ElectronVersion 44.9.2
echo   quick-build-next.bat -HarnessVersion 0.2.1-rc.2   (dsh runtime version)
echo   quick-build-next.bat -PnpmVersion 11.28.5         (needs overlay\pnpm\pnpm@^<ver^>.patch)
echo   quick-build-next.bat -Preview                     (inject only, print diff, no build)
echo   quick-build-next.bat -SkipPull
echo   quick-build-next.bat -FixedTokenPatch -ListenAllNetworkPatch
echo     ^(these are PATCH SWITCHES, not values: they only add the code that READS
echo      DSH_WEB_TOKEN / DSH_NEXT_WEB_HOST. The actual values go into startup.json
echo      beside the exe -- change them there later without rebuilding:
echo        { "version": 1, "env": {
echo            "DSH_NEXT_WEB_HOST": "0.0.0.0",
echo            "DSH_WEB_TOKEN": "MyFixedToken_2026",
echo            "DSH_WEB_TRUSTED_HOSTS": "[\"139.9.73.189\"]" } }
echo      ^(DSH_WEB_TRUSTED_HOSTS is a JSON array string, same format as upstream
echo       DSH_NEXT_TRUSTED_HOSTS; a plain "1.2.3.4,5.6.7.8" is accepted too^)
echo      Neither switch = upstream behaviour: loopback only + random token per launch.^)
echo.
rem echo Press Ctrl+C to cancel, or
rem pause
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-next.ps1" -Target package-dir -SkipSubmodule %*
