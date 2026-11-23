@echo off
REM Install the context menu (per-user, no admin needed). Options: -Classic Yes^|No  -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
