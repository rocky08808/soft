@echo off
chcp 65001 >nul
title ReSA 卸载
echo.
echo === ReSA 卸载 ===
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set "RC=%ERRORLEVEL%"
echo.
if %RC% NEQ 0 (
    echo [错误] 卸载未完全成功，错误码: %RC%
) else (
    echo 卸载已完成。
)
pause
exit /b %RC%
