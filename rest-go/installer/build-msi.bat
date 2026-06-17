@echo off
cd /d "%~dp0\.."

if not exist dist\ReST.exe (
    echo Building ReST.exe first...
    call build.bat
    if errorlevel 1 exit /b 1
)

echo Building ReST.msi ...
python installer\build_msi.py
if errorlevel 1 (
    echo MSI build failed.
    pause
    exit /b 1
)

echo Output: ..\downloads\ReST.msi
exit /b 0
