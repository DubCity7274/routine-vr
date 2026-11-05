@echo off
rem Routine VR for Windows. Double-click, or drag the PPV zip onto this file
rem to install the PPV/SML pak mod too.
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\windows\install.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\windows\install.ps1" -PpvZip "%~1"
)
pause
