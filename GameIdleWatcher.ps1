# Keeps CPU cores out of deep sleep states only while a game from games.txt is running.
# Restores normal idle behavior when the game closes.
# games.txt and settings.txt are re-read every poll, so edits (by hand or from the settings window)
# apply without a restart.
#
# Modes:
#   full  - Processor idle disable = on. Cores never sleep (like Global C-State Control = Disabled).
#   light - Idle promote/demote thresholds = 100%. Cores still use the shallow C1 state but never
#           go into the deeper, slower-to-wake states. Less heat and power than full.
# Each game in games.txt can set its own mode ("Name | light"); games without one use the default
# from settings.txt (mode=full or mode=light). If several games run at once, full wins over light.

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

# One game per line: "ProcessName", optionally "ProcessName | full" or "ProcessName | light".
# The process name is the .exe name without ".exe"; anything after # is a label/comment.
function Get-Games {
    if (-not (Test-Path -LiteralPath $GamesFile)) { return @() }
    foreach ($line in Get-Content -LiteralPath $GamesFile) {
        $fields = ($line -split '#', 2)[0] -split '\|', 2
        $name = $fields[0].Trim()
        if (-not $name) { continue }
        $mode = if ($fields.Count -gt 1) { $fields[1].Trim().ToLower() } else { '' }
        if ($mode -notin 'full', 'light') { $mode = 'default' }
        [pscustomobject]@{ Name = $name; Mode = $mode }
    }
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
$prevDefault = $null
$startGames = @(Get-Games) | ForEach-Object { if ($_.Mode -eq 'default') { $_.Name } else { "$($_.Name) ($($_.Mode))" } }
Write-Log ("Watcher started. Default mode: {0}. Games: {1}. Normal thresholds: promote {2} / demote {3}." -f
    (Get-Mode), ($startGames -join ', '), $script:OrigPromote, $script:OrigDemote)

try {
    while ($true) {
        $games = @(Get-Games)
        $defaultMode = Get-Mode
        # Match by name only: Vanguard hides League's path from normal processes.
        $runningNames = if ($games) { @(Get-Process -Name $games.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique | Sort-Object) } else { @() }
        $running = $runningNames.Count -gt 0

        # Effective mode: each running game's own mode (or the default); full wins over light.
        $wanted = foreach ($n in $runningNames) {
            $g = $games | Where-Object Name -eq $n | Select-Object -First 1
            if ($g.Mode -eq 'default') { $defaultMode } else { $g.Mode }
        }
        $mode = if (@($wanted) -contains 'full') { 'full' } else { 'light' }

        if ($prevDefault -and $defaultMode -ne $prevDefault) { Write-Log "Default mode changed: $prevDefault -> $defaultMode" }
        $prevDefault = $defaultMode
        foreach ($n in $runningNames) { if ($prevRunning -notcontains $n) { Write-Log "Game started: $n" } }
        foreach ($n in $prevRunning)  { if ($runningNames -notcontains $n) { Write-Log "Game closed: $n" } }
        $prevRunning = $runningNames

        if ($running -and $activeMode -ne $mode) {
            if ($activeMode) { Restore-Idle }   # mode switched while a game is running
            Enable-Mode $mode
            $activeMode = $mode
            Write-Log ("ON ({0} mode) for {1}: {2}" -f $mode, ($runningNames -join ', '),
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
