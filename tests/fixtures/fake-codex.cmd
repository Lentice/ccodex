@echo off
pwsh -NoProfile -File "%~dp0fake-codex.ps1" %*
exit /b %ERRORLEVEL%
