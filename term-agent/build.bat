@echo off
cd /d "%~dp0"

echo [note] Release builds use rest-go\build.bat. This builds legacy Python ReST locally only.

if not exist ..\agent\agent.config.json (
    echo [错误] 未找到 agent\agent.config.json
    echo 请复制 agent.config.example.json 并填写 server / token
    pause
    exit /b 1
)

python -m pip install -r requirements.txt -q
python -m pip install "pyinstaller>=6.0" -q

echo Building ReST Python (onedir) ...
python -m PyInstaller --clean --noconfirm term_agent.spec
if errorlevel 1 (
    echo Build failed.
    pause
    exit /b 1
)

echo Done: dist\ReST\ReST.exe
python -c "import pathlib; d=pathlib.Path('dist/ReST'); dist=sum(f.stat().st_size for f in d.rglob('*') if f.is_file()) if d.exists() else 0; print(f'dist size: {dist/1024/1024:.2f} MB')"
exit /b 0
