@echo off
chcp 65001 >nul
title VSCode Setting Setup
powershell -ExecutionPolicy Bypass -File "%~dp0vscode-setup.ps1"
echo.
echo Press any key to exit...
pause >nul
