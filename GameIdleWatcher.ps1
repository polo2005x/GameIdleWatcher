# Keeps CPU cores out of deep sleep states only while a game from games.txt is running.
# Restores normal idle behavior when the game closes.
# games.txt and settings.txt are re-read every poll, so edits (by hand or from the settings window)
# apply without a restart.
#
# Modes (settings.txt: mode=full or mode=light):
#   full  - Processor idle disable = on. Cores never sleep (like Global C-State Control = Disabled).
#   light - Idle promote/demote thresholds = 100%. Cores still use the shallow C1 state but never
#           go into the deeper, slower-to-wake states. Less heat and power than full.

$GamesFile    = Join-Path $PSScriptRoot 'games.txt'
$SettingsFile = Join-Path $PSScriptRoot 'settings.txt'
$LogFile      = Join-Path $PSScriptRoot 'log.txt'
$PollSeconds  = 5

function Write-Log([string]$message) {
    try {
        Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $message)
        # Keep the log small: once it passes ~256 KB, keep the newest 1000 lines.
        if ((Get-Item -LiteralPath $LogFile).Length -gt 256KB) {
            $keep = Get-Content -LiteralPath $LogFile -Tail 1000
            Set-Content -LiteralPath $LogFile -Value $keep
        }
    } catch { }
}

# One process name per line (the .exe name without ".exe"); anything after # is a label/comment.
function Get-GameNames {
    if (-not (Test-Path -LiteralPath $GamesFile)) { return @() }
    Get-Content -LiteralPath $GamesFile |
        ForEach-Object { ($_ -split '#', 2)[0].Trim() } |
        Where-Object { $_ }
}

function Get-Mode {
    if (Test-Path -LiteralPath $SettingsFile) {
        $line = Get-Content -LiteralPath $SettingsFile | Where-Object { $_ -match '^\s*mode\s*=' } | Select-Object -First 1
        if ($line -match '=\s*light\s*$') { return 'light' }
    }
    'full'
}

function Get-PowerValue([string]$setting) {
    # Last two hex values in the output are the AC and DC indices (works on any Windows language).
    $hex = [regex]::Matches((powercfg /qh scheme_current sub_processor $setting | Out-String), '0x[0-9a-fA-F]+')
    [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16)
}

function Set-PowerValues([hashtable]$values) {
    foreach ($k in $values.Keys) { powercfg /setacvalueindex scheme_current sub_processor $k $values[$k] }
    powercfg /setactive scheme_current
}

function Enable-Mode([string]$mode) {
    if ($mode -eq 'light') { Set-PowerValues @{ IDLEPROMOTE = 100; IDLEDEMOTE = 100 } }
    else                   { Set-PowerValues @{ IDLEDISABLE = 1 } }
}

function Restore-Idle {
    Set-PowerValues @{ IDLEDISABLE = 0; IDLEPROMOTE = $script:OrigPromote; IDLEDEMOTE = $script:OrigDemote }
}

# Remember the plan's normal thresholds. Both at 100 means a previous run was killed in light mode,
# so fall back to the Windows defaults.
$script:OrigPromote = Get-PowerValue IDLEPROMOTE
$script:OrigDemote  = Get-PowerValue IDLEDEMOTE
if ($script:OrigPromote -eq 100 -and $script:OrigDemote -eq 100) {
    $script:OrigPromote = 60
    $script:OrigDemote  = 40
}

# Start from a known-good state in case a previous run was killed mid-game.
Restore-Idle
$activeMode = $null   # $null = not active, otherwise the mode currently applied
$prevRunning = @()
$prevMode = $null
Write-Log ("Watcher started. Mode: {0}. Games: {1}. Normal thresholds: promote {2} / demote {3}." -f
    (Get-Mode), ((@(Get-GameNames)) -join ', '), $script:OrigPromote, $script:OrigDemote)

try {
    while ($true) {
        $names = @(Get-GameNames)
        # Match by name only: Vanguard hides League's path from normal processes.
        $runningNames = if ($names) { @(Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique | Sort-Object) } else { @() }
        $running = $runningNames.Count -gt 0
        $mode = Get-Mode

        if ($prevMode -and $mode -ne $prevMode) { Write-Log "Mode changed: $prevMode -> $mode" }
        $prevMode = $mode
        foreach ($n in $runningNames) { if ($prevRunning -notcontains $n) { Write-Log "Game started: $n" } }
        foreach ($n in $prevRunning)  { if ($runningNames -notcontains $n) { Write-Log "Game closed: $n" } }
        $prevRunning = $runningNames

        if ($running -and $activeMode -ne $mode) {
            if ($activeMode) { Restore-Idle }   # mode switched while a game is running
            Enable-Mode $mode
            $activeMode = $mode
            Write-Log ("ON ({0} mode): {1}" -f $mode,
                $(if ($mode -eq 'light') { 'promote/demote thresholds set to 100%' } else { 'processor idle disabled' }))
        } elseif (-not $running -and $activeMode) {
            Restore-Idle
            $activeMode = $null
            Write-Log 'OFF: no listed game running, normal CPU idle restored'
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Restore-Idle
    Write-Log 'Watcher stopped, normal CPU idle restored'
}
