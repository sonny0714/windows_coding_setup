@echo off
chcp 65001 > nul 2>&1
powershell -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & ([scriptblock]::Create([System.IO.File]::ReadAllText('%~dp0setup-wt-wsl.ps1', [System.Text.Encoding]::UTF8)))"
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] PowerShell 실행 실패. 에러코드: %errorlevel%
    pause
)
exit /b %errorlevel%
