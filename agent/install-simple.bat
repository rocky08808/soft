@echo off
chcp 65001 >nul
cd /d "%~dp0"

set "SRC=%~dp0ReSA.exe"
set "DIR=%LOCALAPPDATA%\ReSA"
set "EXE=%DIR%\ReSA.exe"
set "TASK=ReSA"

if not exist "%SRC%" (
    echo [错误] 找不到 ReSA.exe
    echo 请将此脚本与 exe 放在同一文件夹。
    pause
    exit /b 1
)

echo.
echo === ReSA 一键安装 ===
echo.

if not exist "%DIR%" mkdir "%DIR%"
copy /Y "%SRC%" "%EXE%" >nul
if errorlevel 1 (
    echo [错误] 复制失败
    pause
    exit /b 1
)

powershell -NoProfile -Command "Unblock-File -LiteralPath '%EXE%' -ErrorAction SilentlyContinue" 2>nul

schtasks /Create /TN "%TASK%" /TR "\"%EXE%\"" /SC ONLOGON /RL LIMITED /F >nul 2>&1
if errorlevel 1 (
    echo [提示] 计划任务创建失败，改用启动文件夹自启...
    set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
    powershell -NoProfile -Command "$s=New-Object -ComObject WScript.Shell;$l=$s.CreateShortcut('%STARTUP%\ReSA.lnk');$l.TargetPath='%EXE%';$l.WorkingDirectory='%DIR%';$l.Save()" 2>nul
)

start "" /B "%EXE%"
echo.
echo 已安装: %EXE%
echo 已设置登录自启（计划任务或启动文件夹）
echo 设备 ID 见: %DIR%\device.id
echo 日志: %DIR%\agent.log
echo.
pause
