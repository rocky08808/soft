@echo off
cd /d "%~dp0server"
if not exist node_modules npm install
set ACCESS_TOKEN=rxODt12ykrc4vN5Fl3Qm2srm0v3sr-ZHf1kAU9PJzCQ
node index.js
