@echo off
cd /d "%~dp0"

if not exist ..\agent\agent.config.json (
    echo [错误] 未找到 agent\agent.config.json
    echo 请复制 agent.config.example.json 并填写 server / token
    pause
    exit /b 1
)

python -m pip install -r requirements.txt -q
python -m pip install "pyinstaller>=6.0" -q

echo Building ReST (onedir) ...
python -m PyInstaller --clean --noconfirm term_agent.spec
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads
if exist ..\downloads\ReST.zip del /f /q ..\downloads\ReST.zip
powershell -NoProfile -Command "Compress-Archive -Path 'dist\ReST\*' -DestinationPath '..\downloads\ReST.zip' -Force"
if errorlevel 1 (
    echo Failed to create ReST.zip
    exit /b 1
)

echo Done: dist\ReST\ReST.exe
echo Packaged: downloads\ReST.zip
pause
