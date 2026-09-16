@echo off
cd /d %~dp0
REM DSH Desktop - Deploy freshly built win-unpacked to X:\App\DSH-Desktop

echo Is X:\App\DSH-Desktop installed?
echo   - Close any running program / terminal window first
pause

set "distDir=%cd%\dsh-desktop\dsh-plugin-desktop\dist\win-unpacked"

rename "%distDir%\locales\en-US.pak" "en-US.pak.bak"
rename "%distDir%\locales\zh-CN.pak" "zh-CN.pak.bak"

del /f /q "%distDir%\locales\*.pak"
del /f /q "%distDir%\LICENSES.chromium.html"
del /f /q "%distDir%\LICENSE.electron.txt"

rename "%distDir%\locales\en-US.pak.bak" "en-US.pak"
rename "%distDir%\locales\zh-CN.pak.bak" "zh-CN.pak"

copy /y "%cd%\overlay\startup.json" "%distDir%"
robocopy "%distDir%" "X:\App\DSH-Desktop" /mir /xf "startup.json"

echo The dist\win-unpacked directory will now be deleted.
echo   - Close any running program / terminal window first
pause

rmdir /s /q "%distDir%"

echo Update complete.