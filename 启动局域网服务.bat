@echo off
chcp 65001 >nul
title DaXiaoZhou LAN Server
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
echo.
echo Server stopped. Press any key to close this window.
pause >nul
