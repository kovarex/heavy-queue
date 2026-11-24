@echo off
rem heavy-queue's lock: runs COMMAND LINE while holding the machine's one heavy slot (heavy.ps1 says how).
rem heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s, 10m or 2h] COMMAND LINE...   heavy.cmd --status
setlocal
set "HEAVY_QUEUE_COMMAND=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0heavy.ps1"
exit /b %errorlevel%
