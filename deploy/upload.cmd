@echo off
rem Uploads a new heavyboard program to the host: index.cgi (kpp --release --target freebsd heavyboard in
rem board\, or the path given) and, when this folder has one, control-password. The program's own page
rem then replaces a page posted with post-page.ps1 (page.html is removed). The host is in site.txt here (not
rem in git): line 1 the SSH login (user@host), line 2 the board's public folder, line 3 its data folder,
rem line 4 the web server's group (default web). A first install is board\install.sh instead.
setlocal
set "HERE=%~dp0"
if not exist "%HERE%site.txt" (echo deploy\site.txt is missing: see site.example.txt& exit /b 2)
set "GROUP=web"
for /f "usebackq tokens=1* delims=:" %%a in (`findstr /n "^" "%HERE%site.txt"`) do (
  if "%%a"=="1" set "SITE=%%b"
  if "%%a"=="2" set "PUBLIC=%%b"
  if "%%a"=="3" set "DATA=%%b"
  if "%%a"=="4" if not "%%b"=="" set "GROUP=%%b"
)
set "CGI=%HERE%..\board\build\release\heavyboard"
if not "%~1"=="" set "CGI=%~1"
if not exist "%CGI%" (echo no program at %CGI%: give its path& exit /b 2)
scp "%CGI%" "%SITE%:%PUBLIC%/index.cgi.new" || exit /b 1
if exist "%HERE%control-password" (scp "%HERE%control-password" "%SITE%:%DATA%/control-password" || exit /b 1)
ssh %SITE% "chmod 755 %PUBLIC%/index.cgi.new && mv -f %PUBLIC%/index.cgi.new %PUBLIC%/index.cgi && rm -f %DATA%/page.html && (test ! -f %DATA%/control-password || (chgrp %GROUP% %DATA%/control-password && chmod 640 %DATA%/control-password)) && echo uploaded"
