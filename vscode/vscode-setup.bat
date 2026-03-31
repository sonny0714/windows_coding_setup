@echo off
chcp 65001 >nul 2>&1
title VSCode Setting Setup
powershell -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & ([scriptblock]::Create([System.IO.File]::ReadAllText('%~dp0vscode-setup.ps1', [System.Text.Encoding]::UTF8)))"
echo.
echo Press any key to exit...
pause >nul
