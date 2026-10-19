@echo off
chcp 65001 >nul
title SynerRoll 备用启动（命令行模式）
echo ============================================
echo   SynerRoll 命令行启动
echo   若 Electron 图形界面异常，可用此脚本
echo ============================================
echo.

set ROOT=%~dp0
set JULIA_PORT=8080
set BFF_PORT=3000
set HOST=127.0.0.1

echo [1/2] 启动 Julia 计算引擎 (port %JULIA_PORT%)...
set JULIA_DEPOT_PATH=%ROOT%runtime\julia-depot
set JULIA_PROJECT=%ROOT%app\backend
set SYNERROLL_DATA_DIR=%ROOT%data
start "SynerRoll-Julia" /min "%ROOT%runtime\julia\bin\julia.exe" --project="%ROOT%app\backend" "%ROOT%app\backend\server.jl"

echo 等待计算引擎就绪（约 20-40 秒）...
timeout /t 25 /nobreak >nul

echo [2/2] 启动应用服务 (port %BFF_PORT%)...
set PORT=%BFF_PORT%
set NITRO_PORT=%BFF_PORT%
set HOST=%HOST%
set NITRO_HOST=%HOST%
set JULIA_BACKEND_URL=http://%HOST%:%JULIA_PORT%
set NUXT_PUBLIC_JULIA_WS_BASE=ws://%HOST%:%JULIA_PORT%
start "SynerRoll-BFF" /min cmd /c "node "%ROOT%app\.output\server\index.mjs""

echo 等待应用服务就绪...
timeout /t 5 /nobreak >nul

echo.
echo ============================================
echo   启动完成
echo   浏览器访问: http://%HOST%:%BFF_PORT%
echo   健康检查:   http://%HOST%:%BFF_PORT%/api/v1/health
echo   按任意键打开浏览器...
echo ============================================
pause >nul
start "" "http://%HOST%:%BFF_PORT%"
echo.
echo 关闭此窗口不会停止服务。
echo 停止服务请在任务管理器中结束 julia.exe 和 node.exe，
echo 或双击 启动器\stop-all.bat
