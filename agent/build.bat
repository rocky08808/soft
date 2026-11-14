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



echo Building ReSA onedir ...

for /f "delims=" %%V in ('python ..\scripts\write_versions.py resa') do set BUILD_VERSION=%%V
echo Version: %BUILD_VERSION%

python -m PyInstaller --clean --noconfirm agent.spec

if errorlevel 1 (

    echo Build failed.

    pause
    exit /b 1

)

if not exist dist\ReSA\ReSA.exe (
    echo dist\ReSA\ReSA.exe missing
    pause
    exit /b 1
)

if not exist ..\downloads mkdir ..\downloads

echo Packing downloads\ReSA.zip ...
python ..\scripts\pack_resa_zip.py dist\ReSA ..\downloads\ReSA.zip
if errorlevel 1 (
    echo Failed to create ReSA.zip
    pause
    exit /b 1
)

python ..\scripts\write_versions.py resa %BUILD_VERSION% >nul

echo.
echo Done: downloads\ReSA.zip
echo Config from agent.config.json is built into the folder. Device ID = computer name.
echo.
echo Next: upload downloads\ReSA.zip , downloads\install.ps1 and downloads\versions.json
echo   https://your-domain/install.html
echo.

exit /b 0

