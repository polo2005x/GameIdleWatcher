# Disables CPU idle states (like turning off C-States) only while a game from games.txt is running.
# Restores normal idle behavior when the game closes.
# games.txt is re-read every poll, so edits (by hand or from the settings window) apply without a restart.

$GamesFile = Join-Path $PSScriptRoot 'games.txt'
$PollSeconds = 5

# One process name per line (the .exe name without ".exe"); anything after # is a label/comment.
function Get-GameNames {
    if (-not (Test-Path -LiteralPath $GamesFile)) { return @() }
    Get-Content -LiteralPath $GamesFile |
        ForEach-Object { ($_ -split '#', 2)[0].Trim() } |
        Where-Object { $_ }
}

function Set-IdleDisable([int]$value) {
    powercfg /setacvalueindex scheme_current sub_processor IDLEDISABLE $value
    powercfg /setactive scheme_current
}

# Start from a known-good state in case a previous run was killed mid-game.
Set-IdleDisable 0
$active = $false

try {
    while ($true) {
        $names = @(Get-GameNames)
        # Match by name only: Vanguard hides League's path from normal processes.
        $running = $names.Count -gt 0 -and [bool](Get-Process -Name $names -ErrorAction SilentlyContinue)

        if ($running -and -not $active) {
            Set-IdleDisable 1
            $active = $true
        } elseif (-not $running -and $active) {
            Set-IdleDisable 0
            $active = $false
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Set-IdleDisable 0
}
