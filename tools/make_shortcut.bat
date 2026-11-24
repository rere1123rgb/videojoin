@echo off
title Video Joiner - Create Shortcut
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_shortcut.ps1" -AppDir "%~dp0."
echo.
pause
