@echo off
rem Runs the x4cockpit3 tests. Never touches the real game, its window, its config or the companion.
rem   run-tests.cmd [-WorkDir <dir>] [-SourceConfig <config.xml to copy>] [-SkipWindow]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-tests.ps1" %*
exit /b %ERRORLEVEL%
