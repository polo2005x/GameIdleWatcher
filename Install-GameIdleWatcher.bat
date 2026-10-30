@echo off
rem Installs the Game Idle Watcher: disables CPU idle states only while a listed game is running.
rem The game list is at the top of GameIdleWatcher.ps1, which must be in the same folder as this file.

set "SCRIPT=%~dp0GameIdleWatcher.ps1"

if not exist "%SCRIPT%" (
    echo Could not find "%SCRIPT%"
    echo Keep GameIdleWatcher.ps1 in the same folder as this .bat file.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$q = [char]34;" ^
  "foreach ($old in 'League Idle Watcher', 'Game Idle Watcher') { Stop-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue };" ^
  "$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $q + $env:SCRIPT + $q);" ^
  "$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME;" ^
  "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew;" ^
  "Register-ScheduledTask -TaskName 'Game Idle Watcher' -Action $action -Trigger $trigger -Settings $settings -Description 'Disables CPU idle states while a listed game is running (see GameIdleWatcher.ps1).' | Out-Null;" ^
  "Start-ScheduledTask -TaskName 'Game Idle Watcher';" ^
  "Write-Host 'Game Idle Watcher installed and running. It will start automatically at every logon.'"

pause
