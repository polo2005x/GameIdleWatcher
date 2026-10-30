# Disables CPU idle states (like turning off C-States) only while one of the games below is running.
# Restores normal idle behavior when the game closes.

# Process names (the .exe name without ".exe"). Add more games here.
$GameNames = @(
    'League of Legends'   # League of Legends\Game\League of Legends.exe (in a match only)
    'Warframe.x64'        # Warframe\Warframe.x64.exe
)
$PollSeconds = 5

function Set-IdleDisable([int]$value) {
    powercfg /setacvalueindex scheme_current sub_processor IDLEDISABLE $value
    powercfg /setactive scheme_current
}

# Start from a known-good state in case a previous run was killed mid-game.
Set-IdleDisable 0
$active = $false

try {
    while ($true) {
        # Match by name only: Vanguard hides the game's path from normal processes.
        $running = [bool](Get-Process -Name $GameNames -ErrorAction SilentlyContinue)

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
