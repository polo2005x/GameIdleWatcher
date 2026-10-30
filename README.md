# Game Idle Watcher

Stops your CPU cores from going to sleep while you play, to prevent micro-stutters and random FPS drops. Turns back off when the game closes.

CPU cores drop into sleep modes (C-states) to save power, and waking them back up takes a tiny moment. In games that can show up as stutters. Turning off Global C-States in the BIOS fixes that, but it also keeps the CPU awake all the time. This does the same thing only while a game is running.

## Supported games

| Game | Process | When it kicks in |
|---|---|---|
| League of Legends | `League of Legends` | During a match (not in the client/lobby) |
| Warframe | `Warframe.x64` | Whenever the game is open |

To add a game, put its process name (the `.exe` name without `.exe`, see Task Manager → Details) in the `$GameNames` list at the top of `GameIdleWatcher.ps1`, then run the installer again.

## Install

1. Keep all files in the same folder, somewhere permanent.
2. Double-click `Install-GameIdleWatcher.bat`. No admin needed.
3. If Windows shows "Windows protected your PC", click **More info → Run anyway**.

It runs hidden in the background and starts automatically at every logon. If you move the folder, run the installer again.

## Uninstall

Double-click `Uninstall-GameIdleWatcher.bat`. It removes the logon task and turns CPU idle states back to normal.

## How it works

Every 5 seconds the script checks whether a listed game is running. If one is, it sets the Windows power setting **Processor idle disable** (`IDLEDISABLE`) to on for the active power plan; when the game closes, it sets it back off. It also resets the setting to off every time it starts, so it can't get stuck on.

Notes:

- Task Manager will **not** show 100% CPU while it's active on newer Windows 11 builds. To verify, check `\Processor(_Total)\% Idle Time` in Performance Monitor: it drops to 0% while a game is running.
- On laptops it only applies while plugged in (AC power).
- Expect slightly higher power draw and temperatures while a game is running.
- It only helps if the stutter is caused by cores waking up from sleep. If nothing improves after a few games, uninstall it.
