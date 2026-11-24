@echo off
rem Uploads a new heavyboard program (index.cgi, built with kpp --release --target freebsd heavyboard in
rem board\) and, when this folder has one, control-password. The site is in site.txt here (not in git):
rem line 1 the SSH login (user@host), line 2 the board's public folder, line 3 its data folder.
rem A first install is board\install.sh instead.
setlocal
set "HERE=%~dp0"
if not exist "%HERE%site.txt" (echo deploy\site.txt is missing: see site.example.txt& exit /b 2)
for /f "usebackq tokens=1* delims=:" %%a in (`findstr /n "^" "%HERE%site.txt"`) do (
  if "%%a"=="1" set "SITE=%%b"
  if "%%a"=="2" set "PUBLIC=%%b"
  if "%%a"=="3" set "DATA=%%b"
)
set "CGI=%HERE%..\board\build\release\heavyboard"
if not "%~1"=="" set "CGI=%~1"
if not exist "%CGI%" (echo no program at %CGI%: give its path& exit /b 2)
scp "%CGI%" "%SITE%:%PUBLIC%/index.cgi" || exit /b 1
if exist "%HERE%control-password" (scp "%HERE%control-password" "%SITE%:%DATA%/control-password" || exit /b 1)
ssh %SITE% "chmod 755 %PUBLIC%/index.cgi && (test ! -f %DATA%/control-password || (chgrp web %DATA%/control-password && chmod 640 %DATA%/control-password)) && echo uploaded"
