@echo off
cd /d "%~dp0"
echo.
echo === ReSA - target PC installer ===
echo Do NOT double-click ReSA.exe directly.
echo Run this script instead.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-on-target.ps1"
exit /b %ERRORLEVEL%
