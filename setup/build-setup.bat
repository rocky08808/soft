@echo off
cd /d "%~dp0"

if not exist ..\agent\agent.config.json (
    echo [错误] 未找到 agent\agent.config.json
    echo 请先配置 agent.config.json
    pause
    exit /b 1
)

echo Building ReSA-Setup.exe ...
python -m pip install "pyinstaller>=6.0" -q
python -m PyInstaller --clean --noconfirm setup.spec
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads
copy /Y dist\ReSA-Setup.exe ..\downloads\ >nul
echo Done: downloads\ReSA-Setup.exe
if /i not "%~1"=="nopause" pause
