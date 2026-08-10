@echo off
cd /d "%~dp0"

if exist ..\agent\agent.config.json (
    copy /Y ..\agent\agent.config.json agent.config.json >nul
) else (
    copy /Y default.config.json agent.config.json >nul
)

for /f "delims=" %%V in ('python ..\scripts\write_versions.py proxy') do set BUILD_VERSION=%%V
echo Version: %BUILD_VERSION%

go mod tidy
if errorlevel 1 (
    echo go mod tidy failed.
    pause
    exit /b 1
)

if not exist dist mkdir dist
echo Building ReProxy (Go) ...
go build -trimpath -ldflags "-s -w -H windowsgui -X main.version=%BUILD_VERSION%" -o dist\Proxy.exe .
if errorlevel 1 (
    echo Build failed.
    pause
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads
copy /Y dist\Proxy.exe ..\downloads\Proxy.exe >nul

echo Done: dist\Proxy.exe
echo Copied: downloads\Proxy.exe
exit /b 0
