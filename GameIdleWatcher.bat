@echo off
rem Opens the Game Idle Watcher settings window (add/remove games, install/uninstall).
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0GameIdleWatcher-Settings.ps1"
