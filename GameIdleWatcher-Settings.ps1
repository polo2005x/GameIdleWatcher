# Settings window for Game Idle Watcher: add/remove games, see status, install/uninstall.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$GamesFile = Join-Path $PSScriptRoot 'games.txt'
$TaskName  = 'Game Idle Watcher'
$Header = @(
    '# Games that disable CPU idle states while running.'
    '# One process name per line (the .exe name without ".exe"). Text after # is a label.'
    '# Optional per-game mode: "Name | full" or "Name | light". Without it the default mode is used.'
)

# ---------- games.txt ----------

function Read-Games {
    if (-not (Test-Path -LiteralPath $GamesFile)) { return @() }
    foreach ($line in Get-Content -LiteralPath $GamesFile) {
        $parts = $line -split '#', 2
        $fields = $parts[0] -split '\|', 2
        $name = $fields[0].Trim()
        if (-not $name) { continue }
        $mode = if ($fields.Count -gt 1) { $fields[1].Trim().ToLower() } else { '' }
        if ($mode -notin 'full', 'light') { $mode = 'default' }
        $label = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { $name }
        [pscustomobject]@{ Name = $name; Mode = $mode; Label = $label }
    }
}

function Save-Games($games) {
    $lines = $Header + @($games | ForEach-Object {
        if ($_.Mode -in 'full', 'light') { "$($_.Name) | $($_.Mode)  # $($_.Label)" }
        else { "$($_.Name)  # $($_.Label)" }
    })
    Set-Content -LiteralPath $GamesFile -Value $lines -Encoding UTF8
}

function Get-ModeText([string]$mode) {
    switch ($mode) {
        'full'  { 'Full' }
        'light' { 'Light' }
        default { "Default ($((Get-Culture).TextInfo.ToTitleCase((Read-Mode))))" }
    }
}

# Mode the watcher should apply for the given running games (full wins over light).
function Get-ExpectedMode($runningGames) {
    $default = Read-Mode
    $wanted = foreach ($g in $runningGames) { if ($g.Mode -eq 'default') { $default } else { $g.Mode } }
    if (@($wanted) -contains 'full') { 'full' } else { 'light' }
}

function Normalize-ProcessName([string]$name) {
    ($name.Trim() -replace '\.exe$', '').Trim()
}

# ---------- status ----------

function Get-PowerValue([string]$setting) {
    # Last two hex values in the output are the AC and DC indices (works on any Windows language).
    $hex = [regex]::Matches((powercfg /qh scheme_current sub_processor $setting | Out-String), '0x[0-9a-fA-F]+')
    if ($hex.Count -lt 2) { return -1 }
    [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16)
}

# ---------- settings.txt (mode) ----------

$SettingsFile = Join-Path $PSScriptRoot 'settings.txt'
$Modes = @(
    [pscustomobject]@{ Key = 'full';  Text = 'Full - cores never sleep (strongest)' }
    [pscustomobject]@{ Key = 'light'; Text = 'Light - shallow sleep only (less heat/power)' }
)

function Read-Mode {
    if (Test-Path -LiteralPath $SettingsFile) {
        $line = Get-Content -LiteralPath $SettingsFile | Where-Object { $_ -match '^\s*mode\s*=' } | Select-Object -First 1
        if ($line -match '=\s*light\s*$') { return 'light' }
    }
    'full'
}

function Save-Mode([string]$mode) {
    $lines = if (Test-Path -LiteralPath $SettingsFile) { @(Get-Content -LiteralPath $SettingsFile) } else { @() }
    if ($lines -match '^\s*mode\s*=') { $lines = $lines -replace '^\s*mode\s*=.*$', "mode=$mode" }
    else { $lines += "mode=$mode" }
    Set-Content -LiteralPath $SettingsFile -Value $lines -Encoding UTF8
}

function Update-Status {
    Sync-Watcher
    $games = @(Read-Games)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $games) {
        $watcherLabel.Text = 'Watcher: off (add a game to turn it on)'
        $watcherLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
    } elseif ($task -and $task.State -eq 'Running') {
        $watcherLabel.Text = 'Watcher: running (starts automatically at logon)'
        $watcherLabel.ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $watcherLabel.Text = 'Watcher: not running - trying to start it...'
        $watcherLabel.ForeColor = [System.Drawing.Color]::Firebrick
    }

    $openNames = if ($games) { @(Get-Process -Name $games.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique) } else { @() }
    $openGames = @($games | Where-Object { $openNames -contains $_.Name })
    $label = if ($openGames) { ($openGames.Label) -join ' + ' } else { $null }
    $expected = if ($openGames) { Get-ExpectedMode $openGames } else { $null }

    $applied = if ((Get-PowerValue IDLEDISABLE) -eq 1) { 'full' }
               elseif ((Get-PowerValue IDLEPROMOTE) -eq 100 -and (Get-PowerValue IDLEDEMOTE) -eq 100) { 'light' }
               else { $null }

    switch ($applied) {
        'full'  { $idleLabel.Text = 'CPU idle setting: DISABLED (full mode)' }
        'light' { $idleLabel.Text = 'CPU idle setting: SHALLOW ONLY (light mode)' }
        default { $idleLabel.Text = 'CPU idle setting: normal' }
    }
    $idleLabel.ForeColor = if ($applied) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.SystemColors]::ControlText }

    Update-LiveCheck $label $applied $expected
}

# ---------- live check: measure what the cores are actually doing ----------

# Same counters as Performance Monitor (Processor > % C1/C2/C3/Idle Time). The first read is
# always 0, so values are meaningful from the second timer tick on.
$script:Counters = $null
try {
    $script:Counters = @{}
    foreach ($c in '% Idle Time', '% C1 Time', '% C2 Time', '% C3 Time') {
        $pc = New-Object System.Diagnostics.PerformanceCounter('Processor', $c, '_Total', $true)
        [void]$pc.NextValue()
        $script:Counters[$c] = $pc
    }
} catch { $script:Counters = $null }

$script:GameSeenAt  = $null   # when a listed game was first seen running
$script:GameGoneAt  = $null   # when the last listed game was seen closing
$script:LastLabel   = $null   # running games last tick (a game opening/closing changes the mode)
$script:ChangedAt   = $null   # when a mode was last changed in this window
$Grace = [TimeSpan]::FromSeconds(8)   # watcher polls every 5 s

function Update-LiveCheck($gameLabel, $applied, $expected) {
    $now = Get-Date
    if ($gameLabel) { if (-not $script:GameSeenAt) { $script:GameSeenAt = $now }; $script:GameGoneAt = $null }
    else            { if ($script:GameSeenAt) { $script:GameGoneAt = $now }; $script:GameSeenAt = $null }
    if ($gameLabel -ne $script:LastLabel) { $script:ChangedAt = $now; $script:LastLabel = $gameLabel }

    if (-not $script:Counters) {
        $checkLabel.Text = 'Live check: unavailable (CPU counters could not be read)'
        $checkLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
        $numbersLabel.Text = ''
        return
    }

    $idle = $script:Counters['% Idle Time'].NextValue()
    $c1   = $script:Counters['% C1 Time'].NextValue()
    $deep = $script:Counters['% C2 Time'].NextValue() + $script:Counters['% C3 Time'].NextValue()
    $numbersLabel.Text = 'Measured now:  idle {0:N0}%   light sleep (C1) {1:N0}%   deep sleep (C2+C3) {2:N0}%' -f $idle, $c1, $deep

    $ok    = [System.Drawing.Color]::ForestGreen
    $bad   = [System.Drawing.Color]::Firebrick
    $plain = [System.Drawing.SystemColors]::ControlText
    $settling = ($script:GameSeenAt -and ($now - $script:GameSeenAt) -lt $Grace) -or
                ($script:GameGoneAt -and ($now - $script:GameGoneAt) -lt $Grace) -or
                ($script:ChangedAt -and ($now - $script:ChangedAt) -lt $Grace)

    if ($gameLabel -and $applied -and $applied -ne $expected) {
        if ($settling) { $checkLabel.Text = "Live check: switching to $expected mode... (watcher checks every 5 seconds)"; $checkLabel.ForeColor = $plain }
        else { $checkLabel.Text = "Live check: NOT WORKING - expected $expected mode for $gameLabel but $applied is applied"; $checkLabel.ForeColor = $bad }
    } elseif ($gameLabel -and $applied -eq 'full') {
        if ($idle -lt 2) { $checkLabel.Text = "Live check: WORKING - $gameLabel running, cores never sleep"; $checkLabel.ForeColor = $ok }
        else             { $checkLabel.Text = "Live check: NOT WORKING - idle is disabled but cores still idle $([math]::Round($idle))%"; $checkLabel.ForeColor = $bad }
    } elseif ($gameLabel -and $applied -eq 'light') {
        if ($deep -lt 2) { $checkLabel.Text = "Live check: WORKING - $gameLabel running, no deep sleep"; $checkLabel.ForeColor = $ok }
        else             { $checkLabel.Text = "Live check: NOT WORKING - light mode on but deep sleep is $([math]::Round($deep))% (try Full)"; $checkLabel.ForeColor = $bad }
    } elseif ($settling) {
        $checkLabel.Text = 'Live check: switching... (watcher checks every 5 seconds)'
        $checkLabel.ForeColor = $plain
    } elseif ($gameLabel) {
        $checkLabel.Text = "Live check: NOT WORKING - $gameLabel is running but idle was not changed. Is the watcher running?"
        $checkLabel.ForeColor = $bad
    } elseif ($applied) {
        $checkLabel.Text = 'Live check: STUCK - idle is still changed but no listed game is running. Reopen this window to repair.'
        $checkLabel.ForeColor = $bad
    } else {
        $checkLabel.Text = 'Live check: inactive - no listed game running, CPU sleeping normally'
        $checkLabel.ForeColor = $plain
    }
}

function Refresh-List([string[]]$select = @()) {
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($g in Read-Games) {
        $item = New-Object System.Windows.Forms.ListViewItem($g.Label)
        [void]$item.SubItems.Add($g.Name)
        [void]$item.SubItems.Add((Get-ModeText $g.Mode))
        $item.Tag = $g
        [void]$list.Items.Add($item)
        if ($select -contains $g.Name) { $item.Selected = $true }
    }
    $list.EndUpdate()
    $list.Columns[2].Width = -2
    Update-Selection
}

# Enable the per-game controls and show the selected game's mode.
function Update-Selection {
    $any = $list.SelectedItems.Count -gt 0
    $removeButton.Enabled = $any
    $gameModeBox.Enabled = $any
    $script:SyncingMode = $true
    if ($any) {
        $modes = @($list.SelectedItems | ForEach-Object { $_.Tag.Mode } | Select-Object -Unique)
        $gameModeBox.SelectedItem = if ($modes.Count -eq 1) { $GameModes | Where-Object Key -eq $modes[0] } else { $null }
    } else {
        $gameModeBox.SelectedItem = $null
    }
    $script:SyncingMode = $false
}

function Add-Game([string]$name, [string]$label) {
    $name = Normalize-ProcessName $name
    if (-not $name) { return }
    $games = @(Read-Games)
    if ($games.Name -contains $name) {
        [System.Windows.Forms.MessageBox]::Show("$name is already in the list.", 'Game Idle Watcher') | Out-Null
        return
    }
    if (-not $label) { $label = $name }
    Save-Games ($games + [pscustomobject]@{ Name = $name; Mode = 'default'; Label = $label.Trim() })
    Refresh-List @($name)
    Update-Status
}

# ---------- watcher install / removal (automatic: on while the list has games) ----------

$WatcherScript = Join-Path $PSScriptRoot 'GameIdleWatcher.ps1'
$OldTaskNames  = @('League Idle Watcher')   # names used by earlier versions

function Stop-WatcherProcesses {
    # Stopping the task only ends the conhost wrapper, so also end the PowerShell process inside it.
    Get-CimInstance Win32_Process |
        Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and
                       ($_.CommandLine -like '*-File*GameIdleWatcher.ps1*' -or $_.CommandLine -like '*-File*LeagueIdleWatcher.ps1*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Remove-WatcherTasks {
    foreach ($name in @($TaskName) + $OldTaskNames) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
    Stop-WatcherProcesses
}

function Restore-NormalIdle {
    powercfg /setacvalueindex scheme_current sub_processor IDLEDISABLE 0
    if ((Get-PowerValue IDLEPROMOTE) -eq 100 -and (Get-PowerValue IDLEDEMOTE) -eq 100) {
        powercfg /setacvalueindex scheme_current sub_processor IDLEPROMOTE 60
        powercfg /setacvalueindex scheme_current sub_processor IDLEDEMOTE 40
    }
    powercfg /setactive scheme_current
}

function Install-Watcher {
    Remove-WatcherTasks
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument (
        '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $WatcherScript)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Keeps CPU cores out of deep sleep while a listed game runs (Game Idle Watcher).' | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}

function Remove-Watcher {
    Remove-WatcherTasks
    Restore-NormalIdle
}

# Make the installed state match the list: games -> watcher installed and running from this
# folder; no games -> watcher removed and normal idle restored. Also repairs a moved folder,
# a stopped watcher, or an old version's task.
$script:LastRepair = [datetime]::MinValue
function Sync-Watcher([switch]$Force) {
    $hasGames = @(Read-Games).Count -gt 0
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $old  = $OldTaskNames | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }

    if (-not $hasGames) {
        if ($task -or $old) { Remove-Watcher }
        return
    }
    $healthy = $task -and -not $old -and $task.State -eq 'Running' -and
               "$($task.Actions[0].Arguments)" -like "*$WatcherScript*"
    # Don't retry a failing install every tick.
    if (-not $healthy -and ($Force -or ((Get-Date) - $script:LastRepair).TotalSeconds -gt 30)) {
        $script:LastRepair = Get-Date
        $form.UseWaitCursor = $true
        try { Install-Watcher } finally { $form.UseWaitCursor = $false }
    }
}

# ---------- "add running program" picker ----------

function Show-ProcessPicker {
    $existing = @(Read-Games).Name

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Add a running program'
    $dlg.Size = New-Object System.Drawing.Size(560, 460)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.Font = $form.Font

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Start the game first, then pick it here. Double-click to add.'
    $hint.Dock = 'Top'
    $hint.Height = 28
    $hint.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)

    $procList = New-Object System.Windows.Forms.ListView
    $procList.View = 'Details'
    $procList.FullRowSelect = $true
    $procList.MultiSelect = $false
    $procList.HideSelection = $false
    $procList.Dock = 'Fill'
    [void]$procList.Columns.Add('Program', 200)
    [void]$procList.Columns.Add('Process name', 160)
    [void]$procList.Columns.Add('Window title', 160)

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 44
    $bottom.FlowDirection = 'RightToLeft'
    $bottom.Padding = New-Object System.Windows.Forms.Padding(6)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Add'
    $ok.AutoSize = $true
    $ok.Enabled = $false
    $ok.DialogResult = 'OK'

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.AutoSize = $true
    $cancel.DialogResult = 'Cancel'

    $showAll = New-Object System.Windows.Forms.CheckBox
    $showAll.Text = 'Show background processes'
    $showAll.AutoSize = $true
    $showAll.Margin = New-Object System.Windows.Forms.Padding(3, 7, 12, 3)

    $bottom.Controls.AddRange(@($cancel, $ok, $showAll))
    $dlg.Controls.AddRange(@($procList, $hint, $bottom))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $fill = {
        $procList.BeginUpdate()
        $procList.Items.Clear()
        $procs = Get-Process | Where-Object { $_.Id -ne $PID -and $existing -notcontains $_.Name }
        if (-not $showAll.Checked) { $procs = $procs | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } }
        $procs | Sort-Object Name -Unique | ForEach-Object {
            $desc = try { $_.MainModule.FileVersionInfo.FileDescription } catch { $null }
            $display = if ($desc) { $desc } elseif ($_.MainWindowTitle) { $_.MainWindowTitle } else { $_.Name }
            $item = New-Object System.Windows.Forms.ListViewItem($display)
            [void]$item.SubItems.Add($_.Name)
            [void]$item.SubItems.Add($_.MainWindowTitle)
            $item.Tag = [pscustomobject]@{ Name = $_.Name; Label = $display }
            [void]$procList.Items.Add($item)
        }
        $procList.EndUpdate()
        $ok.Enabled = $false
    }

    $showAll.Add_CheckedChanged($fill)
    $procList.Add_SelectedIndexChanged({ $ok.Enabled = $procList.SelectedItems.Count -gt 0 })
    $procList.Add_DoubleClick({ if ($procList.SelectedItems.Count) { $dlg.DialogResult = 'OK'; $dlg.Close() } })
    & $fill

    if ($dlg.ShowDialog($form) -eq 'OK' -and $procList.SelectedItems.Count) {
        $pick = $procList.SelectedItems[0].Tag
        Add-Game $pick.Name $pick.Label
    }
    $dlg.Dispose()
}

# ---------- main window ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Game Idle Watcher'
$form.Size = New-Object System.Drawing.Size(600, 500)
$form.MinimumSize = New-Object System.Drawing.Size(480, 340)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = 'Dpi'

# Status (top)
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = 'Top'
$statusPanel.Height = 56
$statusPanel.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)

$watcherLabel = New-Object System.Windows.Forms.Label
$watcherLabel.Dock = 'Top'
$watcherLabel.Height = 22
$watcherLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$idleLabel = New-Object System.Windows.Forms.Label
$idleLabel.Dock = 'Top'
$idleLabel.Height = 22

$modeRow = New-Object System.Windows.Forms.FlowLayoutPanel
$modeRow.Dock = 'Top'
$modeRow.Height = 32
$modeRow.WrapContents = $false

$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = 'Default mode while a game runs:'
$modeLabel.AutoSize = $true
$modeLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 6, 0)

$modeBox = New-Object System.Windows.Forms.ComboBox
$modeBox.DropDownStyle = 'DropDownList'
$modeBox.Width = 300
$modeBox.DisplayMember = 'Text'
foreach ($m in $Modes) { [void]$modeBox.Items.Add($m) }

$modeRow.Controls.AddRange(@($modeLabel, $modeBox))
$checkLabel = New-Object System.Windows.Forms.Label
$checkLabel.Dock = 'Top'
$checkLabel.Height = 22
$checkLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$checkLabel.Text = 'Live check: measuring...'

$numbersLabel = New-Object System.Windows.Forms.Label
$numbersLabel.Dock = 'Top'
$numbersLabel.Height = 22
$numbersLabel.ForeColor = [System.Drawing.SystemColors]::GrayText

$statusPanel.Height = 136
# Docked Top in reverse: watcher, idle setting, live check, numbers, then mode row.
$statusPanel.Controls.AddRange(@($modeRow, $numbersLabel, $checkLabel, $idleLabel, $watcherLabel))

# Game list (fill)
$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.HideSelection = $false
$list.Dock = 'Fill'
[void]$list.Columns.Add('Game', 190)
[void]$list.Columns.Add('Process name', 120)
[void]$list.Columns.Add('Mode', 90)
# Last column fills the remaining width (-2 = fill).
$list.Add_Resize({ if ($list.Columns.Count -eq 3) { $list.Columns[2].Width = -2 } })

# List buttons (right)
$side = New-Object System.Windows.Forms.FlowLayoutPanel
$side.Dock = 'Right'
$side.Width = 170
$side.FlowDirection = 'TopDown'
$side.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)

function New-SideButton([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = 150
    $b.Height = 30
    $b
}
$addRunningButton = New-SideButton 'Add running program...'
$addNameButton    = New-SideButton 'Add by process name...'
$removeButton     = New-SideButton 'Remove'
$removeButton.Enabled = $false

$gameModeLabel = New-Object System.Windows.Forms.Label
$gameModeLabel.Text = 'Mode for selected game:'
$gameModeLabel.AutoSize = $true
$gameModeLabel.Margin = New-Object System.Windows.Forms.Padding(3, 14, 3, 2)

$GameModes = @(
    [pscustomobject]@{ Key = 'default'; Text = 'Default' }
    [pscustomobject]@{ Key = 'full';    Text = 'Full' }
    [pscustomobject]@{ Key = 'light';   Text = 'Light' }
)
$gameModeBox = New-Object System.Windows.Forms.ComboBox
$gameModeBox.DropDownStyle = 'DropDownList'
$gameModeBox.Width = 150
$gameModeBox.DisplayMember = 'Text'
foreach ($m in $GameModes) { [void]$gameModeBox.Items.Add($m) }
$gameModeBox.Enabled = $false
$script:SyncingMode = $false

$viewLogButton    = New-SideButton 'View log'
$viewLogButton.Margin = New-Object System.Windows.Forms.Padding(3, 24, 3, 3)
$side.Controls.AddRange(@($addRunningButton, $addNameButton, $removeButton, $gameModeLabel, $gameModeBox, $viewLogButton))

# Install buttons (bottom)
$bottomPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$bottomPanel.Dock = 'Bottom'
$bottomPanel.Height = 48
$bottomPanel.FlowDirection = 'RightToLeft'
$bottomPanel.Padding = New-Object System.Windows.Forms.Padding(6, 8, 6, 6)

$note = New-Object System.Windows.Forms.Label
$note.Text = 'Changes apply within 5 seconds. Remove all games to turn the watcher off completely.'
$note.AutoSize = $true
$note.ForeColor = [System.Drawing.SystemColors]::GrayText
$note.Margin = New-Object System.Windows.Forms.Padding(3, 2, 6, 3)

$bottomPanel.Controls.AddRange(@($note))

# Fill control first so the docked panels are laid out around it.
$form.Controls.AddRange(@($list, $side, $bottomPanel, $statusPanel))

# ---------- events ----------

$list.Add_SelectedIndexChanged({ Update-Selection })

$gameModeBox.Add_SelectedIndexChanged({
    if ($script:SyncingMode -or -not $gameModeBox.SelectedItem -or $list.SelectedItems.Count -eq 0) { return }
    $names = @($list.SelectedItems | ForEach-Object { $_.Tag.Name })
    $newMode = $gameModeBox.SelectedItem.Key
    $games = @(Read-Games)
    foreach ($g in $games) { if ($names -contains $g.Name) { $g.Mode = $newMode } }
    Save-Games $games
    $script:ChangedAt = Get-Date
    Refresh-List $names
    Update-Status
})

$current = Read-Mode
$modeBox.SelectedItem = $Modes | Where-Object Key -eq $current
$modeBox.Add_SelectedIndexChanged({
    if (-not $modeBox.SelectedItem) { return }
    Save-Mode $modeBox.SelectedItem.Key
    $script:ChangedAt = Get-Date
    Refresh-List @($list.SelectedItems | ForEach-Object { $_.Tag.Name })   # "Default (...)" text
})

$addRunningButton.Add_Click({ Show-ProcessPicker })

$addNameButton.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Process name of the game (Task Manager > Details, e.g. Warframe.x64.exe):",
        'Add by process name')
    $name = Normalize-ProcessName $name
    if (-not $name) { return }
    $label = [Microsoft.VisualBasic.Interaction]::InputBox('Display name (optional):', 'Add by process name', $name)
    Add-Game $name $label
})

$removeButton.Add_Click({
    $remove = @($list.SelectedItems | ForEach-Object { $_.Tag.Name })
    Save-Games @(Read-Games | Where-Object { $remove -notcontains $_.Name })
    Refresh-List
    Update-Status
})

$viewLogButton.Add_Click({
    $log = Join-Path $PSScriptRoot 'log.txt'
    if (Test-Path -LiteralPath $log) { Start-Process notepad.exe -ArgumentList "`"$log`"" }
    else { [System.Windows.Forms.MessageBox]::Show('No log yet. The watcher creates log.txt when it starts.', 'Game Idle Watcher') | Out-Null }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })

$form.Add_Shown({ Refresh-List; Update-Status; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop() })

if (-not (Test-Path -LiteralPath $GamesFile)) { Save-Games @() }
[void]$form.ShowDialog()
