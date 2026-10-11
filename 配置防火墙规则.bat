@echo off
chcp 65001 >nul
title DaXiaoZhou LAN - Firewall Setup

rem ============================================================
rem  大小周历 · 防火墙放行（入站 TCP）
rem  作用：让局域网内其他电脑能访问本机的大小周历服务
rem  端口自动读取 server-config.json，读不到则用 8080
rem  可重复执行：每次先删除旧规则再重建
rem ============================================================

rem ---- 提权检查：非管理员则用 UAC 重新启动自身 ----
net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator permission, please click "Yes" in the popup...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

cd /d "%~dp0"

rem ---- 读取端口 ----
set "PORT=8080"
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "try{(Get-Content -LiteralPath '%~dp0server-config.json' -Raw -Encoding UTF8 ^| ConvertFrom-Json).port}catch{8080}"`) do set "PORT=%%p"

echo.
echo   Port to open: %PORT%
echo.

rem ---- 删除旧规则（忽略不存在的情况）----
netsh advfirewall firewall delete rule name="DaXiaoZhou LAN" >nul 2>&1

rem ---- 添加入站放行规则 ----
netsh advfirewall firewall add rule name="DaXiaoZhou LAN" dir=in action=allow protocol=TCP localport=%PORT% profile=any enable=yes

echo.
echo   ---- current rule ----
netsh advfirewall firewall show rule name="DaXiaoZhou LAN"

echo.
echo   Done. Colleagues on the LAN can now open http://YOUR-IP:%PORT%/
echo   To undo: run  netsh advfirewall firewall delete rule name="DaXiaoZhou LAN"  as administrator
echo.
pause
