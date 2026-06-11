@echo off
cd /d "%~dp0agent"
python agent.py --config agent.config.json %*
pause
