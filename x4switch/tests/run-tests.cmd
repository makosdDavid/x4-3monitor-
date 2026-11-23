@echo off
rem X4Switch tests against fakes only (fake game, copies of the scripts, stub server/browser). About 1 minute.
rem   tests\run-tests.cmd [-WorkDir <dir>] [-Port 8797]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-tests.ps1" %*
exit /b %ERRORLEVEL%
