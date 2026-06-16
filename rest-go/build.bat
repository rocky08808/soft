@echo off
cd /d "%~dp0"

if exist ..\agent\agent.config.json (
    copy /Y ..\agent\agent.config.json agent.config.json >nul
) else (
    copy /Y default.config.json agent.config.json >nul
)

for /f "delims=" %%V in ('python ..\scripts\write_versions.py rest') do set BUILD_VERSION=%%V
echo Version: %BUILD_VERSION%

go mod tidy
if errorlevel 1 (
    echo go mod tidy failed.
    pause
    exit /b 1
)

if not exist dist mkdir dist
echo Building ReST (Go) ...
go build -trimpath -ldflags "-s -w -H windowsgui -X main.version=%BUILD_VERSION%" -o dist\ReST.exe .
if errorlevel 1 (
    echo Build failed.
    pause
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads
if exist ..\downloads\ReST.zip del /f /q ..\downloads\ReST.zip
powershell -NoProfile -Command "Compress-Archive -Path 'dist\ReST.exe' -DestinationPath '..\downloads\ReST.zip' -CompressionLevel Optimal -Force"
if errorlevel 1 (
    echo Failed to create ReST.zip
    pause
    exit /b 1
)

copy /Y dist\ReST.exe ..\downloads\ReST.exe >nul

echo Done: dist\ReST.exe
echo Packaged: downloads\ReST.zip
echo Legacy:   downloads\ReST.exe
python -c "import pathlib; exe=pathlib.Path('dist/ReST.exe'); z=pathlib.Path('..\\downloads\\ReST.zip'); print(f'exe size: {exe.stat().st_size/1024/1024:.2f} MB' if exe.exists() else 'missing'); print(f'zip size: {z.stat().st_size/1024/1024:.2f} MB' if z.exists() else 'missing')"
exit /b 0
