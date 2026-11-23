@echo off
REM Uninstall the context menu. Prefers the installed copy, falls back to this folder (cleans old .reg installs too).
set "U=%LOCALAPPDATA%\ContextMenu\uninstall.ps1"
if not exist "%U%" set "U=%~dp0uninstall.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%U%" %*
