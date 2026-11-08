@echo off
rem ===========================================================================
rem  Realtek Audio Console RPC Fix - one-click launcher
rem  Double-click this file. Windows will ask for Administrator rights.
rem ===========================================================================
setlocal
title Realtek Audio Console RPC Fix
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-RealtekAudioConsole.ps1" -Action Fix -LaunchApp
echo.
echo Done. Press any key to close this window.
pause >nul
endlocal
