@echo off
setlocal
if exist "%~dp0..\node\node.exe" (
  "%~dp0..\node\node.exe" "%~dp0..\scripts\opencu-win.mjs" %*
) else (
  node "%~dp0..\scripts\opencu-win.mjs" %*
)
exit /b %errorlevel%
