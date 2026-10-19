@echo off
chcp 65001 >nul
set ROOT=%~dp0
set OUT=%ROOT%logs\diagnostics-%date:~0,4%%date:~5,2%%date:~8,2%-%time:~0,2%%time:~3,2%.zip
set OUT=%OUT: =0%

echo 打包诊断信息...
powershell -Command "Compress-Archive -Path '%ROOT%logs\*' -DestinationPath '%OUT%' -Force"
if exist "%OUT%" (
  echo 诊断包已生成: %OUT%
  echo 请将此文件发送给技术支持。
) else (
  echo 生成失败，请手动压缩 logs 目录。
)
pause
