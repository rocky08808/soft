@echo off
cd /d "%~dp0agent"
python -m pip install -r requirements.txt -q
python agent.py --config agent.config.json %*
