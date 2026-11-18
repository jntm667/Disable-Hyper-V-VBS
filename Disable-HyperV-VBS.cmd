@echo off
if not exist "%~dpn0.ps1" (
    echo The .ps1 file was not found next to this launcher.
    pause
    exit /b 1
)
fltmc >nul 2>&1
if errorlevel 1 (
    set "SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1"
echo.
pause