@echo off
rem x4cockpit3 native tests (build + launcher/hook/cockpit-launch against testtarget.exe). Never touches X4.exe.
rem   run-native-tests.cmd [-WorkDir <dir>] [-SkipBuild] [-Visible]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-native-tests.ps1" %*
exit /b %ERRORLEVEL%
