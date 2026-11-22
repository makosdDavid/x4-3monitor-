@echo off
rem Build launcher.exe, x4c3hook.dll and testtarget.exe into native\out\ with Zig. Options: -Zig <path to zig.exe>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %ERRORLEVEL%
