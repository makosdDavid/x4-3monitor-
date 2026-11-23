@echo off
rem Switch X4's config.xml to cockpit mode (game must be closed). Add -WhatIf to only show the diff.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cockpit.ps1" on %*
exit /b %ERRORLEVEL%
