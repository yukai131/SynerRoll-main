@echo off
chcp 65001 >nul
echo 正在停止 SynerRoll 所有服务...
taskkill /f /im julia.exe >nul 2>&1
taskkill /f /im electron.exe >nul 2>&1
echo.
echo 已停止。请手动结束 node.exe（如有残留）。
echo 如需诊断日志，运行 export-diagnostics.bat
pause
