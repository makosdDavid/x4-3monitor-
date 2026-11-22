@echo off
rem Start X4 with the native window hook (one borderless window over side | centre | side).
rem   cockpit-launch.cmd -GameArgs "-debug all -logfile debug.log"
rem   cockpit-launch.cmd -WhatIf          (checks and prints the command, starts nothing)
rem   cockpit-launch.cmd -Rect "-1920,0,7280,1440" -GameArgs "..."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cockpit-launch.ps1" %*
exit /b %ERRORLEVEL%
