@echo off
REM ReST Uninstall Script
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-rest.ps1"
exit /b %ERRORLEVEL%
