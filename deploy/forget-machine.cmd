@echo off
rem Removes a machine's card from the board (after a rename): forget-machine.cmd NAME. The site is in
rem site.txt here (see upload.cmd).
setlocal
if "%~1"=="" (echo usage: forget-machine.cmd NAME& exit /b 2)
for /f "usebackq tokens=1* delims=:" %%a in (`findstr /n "^" "%~dp0site.txt"`) do (
  if "%%a"=="1" set "SITE=%%b"
  if "%%a"=="3" set "DATA=%%b"
)
ssh %SITE% "rm -f %DATA%/seen-%~1 %DATA%/status-%~1.json %DATA%/open-%~1 && echo forgot %~1"
