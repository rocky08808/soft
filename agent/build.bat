@echo off
cd /d "%~dp0"
echo Installing build dependencies...
python -m pip install -r requirements.txt -q
python -m pip install "pyinstaller>=6.0" -q

echo Preparing embedded config...
if exist agent.config.json (
    python -c "import json; c=json.load(open('agent.config.json',encoding='utf-8')); json.dump({k:c[k] for k in ('server','token','monitor','fps','quality') if k in c}, open('embedded.defaults.json','w',encoding='utf-8'), indent=2)"
) else (
    copy /Y embedded.defaults.template.json embedded.defaults.json >nul
)

echo Building RemoteScreenAgent.exe ...
python -m PyInstaller --clean --noconfirm agent.spec
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

echo.
echo Done: dist\RemoteScreenAgent.exe
echo Server/token are built into the exe. Device ID = computer name.
echo Double-click to run, no config file needed.
echo.
pause
