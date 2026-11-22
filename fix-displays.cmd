@echo off
rem Sets every monitor to its proper mode and arrangement (see fix-displays.ps1).
rem   fix-displays.cmd            apply
rem   fix-displays.cmd -WhatIf    only show what it would do
rem   fix-displays.cmd -Revert    back to the settings saved before the last apply
rem   fix-displays.cmd -Swap      the two Dells are the other way round
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-displays.ps1" %*
if errorlevel 1 pause
