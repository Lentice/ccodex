:: ccodex.cmd
@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ccodex.ps1" %*
exit /b %ERRORLEVEL%
