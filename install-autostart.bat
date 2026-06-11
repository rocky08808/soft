@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0agent\install-autostart.ps1" %*
