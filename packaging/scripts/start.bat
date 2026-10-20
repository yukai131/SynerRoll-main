@echo off
chcp 65001 >nul
title SynerRoll
cd /d "%~dp0"
start "" "%~dp0node_modules\electron\dist\electron.exe" "%cd%"
