@echo off
rem Updates CS2 Bot Improver in this game/csgo folder.
rem Extra options are passed to the updater, e.g. -Check to only see what would change.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0addons\cs2botimprover\update.ps1" %*
set "CODE=%ERRORLEVEL%"
echo.
pause
exit /b %CODE%
