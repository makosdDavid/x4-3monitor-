@echo off
rem x4cockpit3 launcher (Windows PowerShell 5.1).
rem   x4cockpit3.cmd                  arrangement check, changes nothing
rem   x4cockpit3.cmd uw-left-only     stretch the running game window (first test step, no rearranging)
rem   x4cockpit3.cmd triple           stretch over side | centre | side
rem   x4cockpit3.cmd single           back to the centre monitor
rem   x4cockpit3.cmd -Restore         window back to how it was before the first stretch
set "_X4C3_ARG1=%~1"
if not defined _X4C3_ARG1 goto run
if "%_X4C3_ARG1:~0,1%"=="-" goto run
set "_X4C3_ARG1="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0x4cockpit3.ps1" -Preset %*
exit /b %ERRORLEVEL%
:run
set "_X4C3_ARG1="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0x4cockpit3.ps1" %*
exit /b %ERRORLEVEL%
