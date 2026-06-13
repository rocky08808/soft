@echo off

cd /d "%~dp0"

echo Installing build dependencies...

python -m pip install -r requirements.txt -q

python -m pip install "pyinstaller>=6.0" -q



if not exist agent.config.json (
    echo.
    echo [错误] 未找到 agent.config.json
    echo 请复制 agent.config.example.json 为 agent.config.json 并填写 server / token
    echo.
    pause
    exit /b 1
)



echo Building ReSA.exe ...

python -m PyInstaller --clean --noconfirm agent.spec

if errorlevel 1 (

    echo Build failed.

    exit /b 1

)



echo.

echo Done: dist\ReSA.exe

echo Config from agent.config.json is built into the exe. Device ID = computer name.

echo.

echo Copying to downloads/ for online install...

if not exist ..\downloads mkdir ..\downloads

copy /Y dist\ReSA.exe ..\downloads\ >nul

echo.

echo Next: upload downloads\ReSA.exe to server, then use install page

echo   https://your-domain/install.html

echo.

pause

