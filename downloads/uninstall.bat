@echo off
chcp 65001 >nul
title ReSA 卸载
echo.
echo === ReSA 卸载 ===
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
exit /b %ERRORLEVEL%
