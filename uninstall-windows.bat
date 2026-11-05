@echo off
rem Remove Routine VR (keeps your settings; run uninstall.ps1 -RemoveSettings to drop them).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\windows\uninstall.ps1" %*
pause
