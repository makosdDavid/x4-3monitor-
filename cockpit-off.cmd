@echo off
rem Restore X4's config.xml values from before cockpit-on (game must be closed). Add -WhatIf to only show the diff.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cockpit.ps1" off %*
exit /b %ERRORLEVEL%
