@echo off
rem ===========================================================================
rem  Realtek Audio Console RPC Fix - read-only diagnostic launcher
rem  Double-click this file. No administrator rights are required.
rem ===========================================================================
setlocal
title Realtek Audio Console RPC Fix - Diagnose
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-RealtekAudioConsole.ps1" -Action Diagnose
echo.
echo Done. Press any key to close this window.
pause >nul
endlocal
