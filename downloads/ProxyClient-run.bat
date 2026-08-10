@echo off
REM Edit device-id and token, then double-click this file.
REM device.id on remote PC: %%LOCALAPPDATA%%\ReProxy\device.id

set SERVER=wss://olxp.cc
set DEVICE_ID=REPLACE_WITH_DEVICE_ID
set TOKEN=REPLACE_WITH_TOKEN
set LISTEN=127.0.0.1:1080

cd /d "%~dp0"
ProxyClient.exe --server %SERVER% --device-id %DEVICE_ID% --token %TOKEN% --listen %LISTEN%
echo.
echo ProxyClient exited with code %ERRORLEVEL%
pause
