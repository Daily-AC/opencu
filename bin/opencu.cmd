@echo off
setlocal
node "%~dp0..\scripts\opencu-win.mjs" %*
exit /b %errorlevel%
