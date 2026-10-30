@echo off
rem Removes the Game Idle Watcher and restores normal CPU idle behavior.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "foreach ($old in 'League Idle Watcher', 'Game Idle Watcher') { Stop-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue };" ^
  "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.ProcessId -ne $PID -and ($_.CommandLine -like '*GameIdleWatcher.ps1*' -or $_.CommandLine -like '*LeagueIdleWatcher.ps1*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force };" ^
  "powercfg /setacvalueindex scheme_current sub_processor IDLEDISABLE 0;" ^
  "$ac = { param($s) $h = [regex]::Matches((powercfg /qh scheme_current sub_processor $s | Out-String), '0x[0-9a-fA-F]+'); [Convert]::ToInt32($h[$h.Count - 2].Value, 16) };" ^
  "if ((& $ac IDLEPROMOTE) -eq 100 -and (& $ac IDLEDEMOTE) -eq 100) { powercfg /setacvalueindex scheme_current sub_processor IDLEPROMOTE 60; powercfg /setacvalueindex scheme_current sub_processor IDLEDEMOTE 40 };" ^
  "powercfg /setactive scheme_current;" ^
  "Write-Host 'Game Idle Watcher removed. CPU idle states are back to normal.'"

pause
