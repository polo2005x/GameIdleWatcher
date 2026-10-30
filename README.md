# Game Idle Watcher

Stops your CPU cores from going to sleep while you play, to prevent micro-stutters and random FPS drops. Turns back off when the game closes.

CPU cores drop into sleep modes (C-states) to save power, and waking them back up takes a tiny moment. In games that can show up as stutters. Turning off Global C-States in the BIOS fixes that, but it also keeps the CPU awake all the time. This does the same thing only while a game is running.

## Install

1. Download the ZIP (**Code → Download ZIP**) and extract it somewhere permanent. Keep all files in the same folder.
2. Double-click `GameIdleWatcher-Settings.bat` and click **Install**. No admin needed.
   (Or just run `Install-GameIdleWatcher.bat`.)
3. If Windows shows "Windows protected your PC", click **More info → Run anyway**.

It runs hidden in the background and starts automatically at every logon. If you move the folder, open the settings and click **Reinstall**.

## Settings window

Open `GameIdleWatcher-Settings.bat` to:

- See whether the watcher is running and whether CPU idle is currently disabled.
- **Live check**: measures what the cores are actually doing (idle, light sleep C1, deep sleep C2+C3) and says whether it's WORKING, NOT WORKING, STUCK or inactive.
- **View log**: opens `log.txt`, which records when the watcher started, when games opened/closed, mode changes, and when the fix turned on/off.
- Pick the **mode** used while a game runs (see below).
- **Add running program...**: start the game, then pick it from the list of open programs.
- **Add by process name...**: type the `.exe` name (Task Manager → Details).
- **Remove** a game.
- **Install / Reinstall / Uninstall** the watcher.

Changes to the game list apply within 5 seconds, no reinstall needed.

## Modes

| Mode | What it does | Trade-off |
|---|---|---|
| **Full** (default) | Processor idle disable = on. Cores never sleep, same effect as Global C-State Control = Disabled in the BIOS. | Strongest fix, most heat and power while gaming. |
| **Light** | Idle promote/demote thresholds = 100%. Cores still use the shallow C1 state (wakes almost instantly) but never enter the deeper, slow-to-wake states. | Less heat and power. Try it; if stutters come back, switch to Full. |

The mode can be changed while a game is running and applies within 5 seconds. Your choice is saved in `settings.txt` (`mode=full` or `mode=light`).

## Games list

The list lives in `games.txt`, one process name per line (the `.exe` name without `.exe`). Text after `#` is the display name. You can edit it by hand too. Included by default:

| Game | Process | When it kicks in |
|---|---|---|
| League of Legends | `League of Legends` | During a match (not in the client/lobby) |
| Warframe | `Warframe.x64` | Whenever the game is open |

## Uninstall

Click **Uninstall** in the settings window, or run `Uninstall-GameIdleWatcher.bat`. It removes the logon task and turns CPU idle states back to normal.

## How it works

Every 5 seconds `GameIdleWatcher.ps1` re-reads `games.txt` and checks whether a listed game is running. If one is, it changes the active power plan: **Processor idle disable** (`IDLEDISABLE`) on in Full mode, or **Processor idle promote/demote threshold** (`IDLEPROMOTE`/`IDLEDEMOTE`) at 100% in Light mode. Idle stays changed until the last listed game closes, then it's restored. It also restores normal idle every time it starts, so it can't get stuck on.

Notes:

- Task Manager will **not** show 100% CPU while it's active on newer Windows 11 builds. To verify, check `\Processor(_Total)\% Idle Time` in Performance Monitor: it drops to 0% while a game is running.
- On laptops it only applies while plugged in (AC power).
- Expect slightly higher power draw and temperatures while a game is running.
- It only helps if the stutter is caused by cores waking up from sleep. If nothing improves after a few games, uninstall it.
