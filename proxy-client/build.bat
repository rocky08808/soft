@echo off
cd /d "%~dp0"

if exist ..\agent\agent.config.json (
    powershell -NoProfile -Command "$c=Get-Content -Raw '..\agent\agent.config.json'|ConvertFrom-Json; @{server=$c.server;token=$c.token}|ConvertTo-Json|Set-Content -Encoding UTF8 'default.config.json'"
) else if exist ..\proxy-go\agent.config.json (
    powershell -NoProfile -Command "$c=Get-Content -Raw '..\proxy-go\agent.config.json'|ConvertFrom-Json; @{server=$c.server;token=$c.token}|ConvertTo-Json|Set-Content -Encoding UTF8 'default.config.json'"
)

go mod tidy
if errorlevel 1 (
    echo go mod tidy failed.
    pause
    exit /b 1
)

if not exist dist mkdir dist
echo Building ProxyClient (Web UI) ...
go build -trimpath -ldflags "-s -w -H windowsgui" -o dist\ProxyClient.exe .
if errorlevel 1 (
    echo Build failed.
    pause
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads
copy /Y dist\ProxyClient.exe ..\downloads\ProxyClient.exe >nul

echo Done: dist\ProxyClient.exe
echo Copied: downloads\ProxyClient.exe
exit /b 0
