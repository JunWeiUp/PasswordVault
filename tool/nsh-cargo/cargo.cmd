@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0cargo.ps1" %*
exit /b %ERRORLEVEL%
