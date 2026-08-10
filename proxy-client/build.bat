@echo off
cd /d "%~dp0"

go mod tidy
if errorlevel 1 (
    echo go mod tidy failed.
    pause
    exit /b 1
)

if not exist dist mkdir dist
echo Building ProxyClient ...
go build -trimpath -ldflags "-s -w" -o dist\ProxyClient.exe .
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
