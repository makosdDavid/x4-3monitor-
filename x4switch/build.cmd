@echo off
rem Builds X4Switch.exe next to this file with Zig (see build.ps1 for where zig.exe is looked up).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %ERRORLEVEL%
