@echo off
chcp 65001 > nul 2>&1
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0setup-wt-wsl.ps1"
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] PowerShell 실행 실패. 에러코드: %errorlevel%
    pause
)
exit /b %errorlevel%
