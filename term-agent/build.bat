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

echo Building ReST.exe ...
python -m PyInstaller --clean --noconfirm term_agent.spec
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads
copy /Y dist\ReST.exe ..\downloads\ >nul
echo Done: dist\ReST.exe
echo Copied to downloads\ReST.exe
pause
