@echo off
cd /d "%~dp0agent"
call build.bat
if errorlevel 1 exit /b 1
echo.
echo To create setup.exe, install Inno Setup 6 and compile installer.iss
echo Or run: powershell -ExecutionPolicy Bypass -File install-agent.ps1
pause
