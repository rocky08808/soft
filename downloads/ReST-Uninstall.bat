@echo off
powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Product ReST
exit /b %ERRORLEVEL%
