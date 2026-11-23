<#
.SYNOPSIS
  cockpit on|off|status - switch X4's config.xml between "cockpit across three monitors" and the previous setup.

.DESCRIPTION
  on   : (game must be CLOSED) backs up config.xml to backupDir with a timestamp, saves the current values of the
         cockpit keys to state\cockpit-state.json, writes the cockpit values from settings.json (window mode,
         res_width/res_height, fov, menuwidthscale, confinemouse) and nothing else, and creates the companion flag
         file so a companion watcher that honours it does not open its window on top of the game.
  off  : (game must be CLOSED) backs up config.xml again, puts the saved original values back (keys that did not
         exist before are removed again), deletes the state file and the companion flag.
  status: shows the current mode, values, game process and companion window. Changes nothing.

  -WhatIf prints the exact line diff and changes nothing (allowed while the game runs).
  The file is edited textually: only the touched elements change; line endings, BOM, comments and order stay.
  Backups are never deleted by this tool.

.EXAMPLE
  .\cockpit.ps1 on -WhatIf
  .\cockpit.ps1 on
  .\cockpit.ps1 off
  .\cockpit.ps1 status
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][ValidateSet('on', 'off', 'status')][string]$Mode = 'status',
  [switch]$WhatIf,
  [string]$SettingsFile = '',
  [switch]$Json
)
# -Json: after the normal text, one line "@@X4JSON " + compact JSON (for the x4switch manager):
#   { tool:"cockpit", action, result, exit, whatIf, configPath, mode:"on"|"off", since, gameRunning, gamePids[],
#     valuesMatch, mismatch[], values{key:{now,cockpit}}, flag, flagPresent, changed, backup, message }
#   result: status -> "on"|"off" ; on -> "on" ; off -> "off" | "already-off" (exit 2) ; -WhatIf -> "whatif" ;
#           "refused-game-running" | "refused-profile-mismatch" | "error".   Exit codes unchanged (0 / 2 / 1).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Config.ps1')

function Show-Companion($Settings) {
  if (-not $Settings.companionWindowTitle) { return }
  try {
    . (Join-Path $here 'lib\Native.ps1')
    $w = @(Find-WindowsByTitlePrefix $Settings.companionWindowTitle)
    if ($w.Count -gt 0) {
      Write-Host "companion: a window titled '$($w[0].Title)' is open (pid $($w[0].Pid)). It is left alone; close it yourself before starting the game, or it may cover part of the cockpit."
    } else { Write-Host 'companion: no companion window open.' }
  } catch { Write-Host "companion: window check failed: $($_.Exception.Message)" }
}

function Get-UniqueBackupPath([string]$Dir, [string]$Tag) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $p = Join-Path $Dir "config.xml.$stamp.$Tag"
  $i = 2
  while (Test-Path -LiteralPath $p) { $p = Join-Path $Dir "config.xml.$stamp-$i.$Tag"; $i++ }
  return $p
}

function Write-Diff([string]$OldText, $Rows) {
  foreach ($r in $Rows) {
    if (-not $r.Changed) { Write-Host (Fmt '  = line {0,4}: {1}  (already)' $r.Line $r.Same); continue }
    if ($r.From) { Write-Host (Fmt '  - line {0,4}: {1}' $r.Line $r.From) }
    if ($r.To) {
      $ln = $r.Line
      if ($r.From) { Write-Host (Fmt '  + line {0,4}: {1}' $ln $r.To) } else { Write-Host (Fmt '  + line {0,4}: {1}   (new element)' $ln $r.To) }
    } elseif ($r.From) { Write-Host '                (element removed with its line)' }
  }
}

$J = [ordered]@{ tool = 'cockpit'; action = $Mode; result = ''; exit = 0; whatIf = [bool]$WhatIf; configPath = ''; mode = ''; since = ''
  gameRunning = $false; gamePids = @(); valuesMatch = $false; mismatch = @(); values = [ordered]@{}; flag = ''; flagPresent = $false
  changed = 0; backup = ''; message = '' }
function Done([int]$Code, [string]$Result, [string]$Message = '') {
  $J.exit = $Code; $J.result = $Result; if ($Message) { $J.message = $Message }
  if ($J.flag) { $J.flagPresent = [bool](Test-Path -LiteralPath $J.flag) }
  if ($Json) { Write-X4Json $J }
  exit $Code
}

try {
  $settings = Read-CockpitSettings -ToolRoot $here -SettingsFile $SettingsFile
  $cfgPath = Resolve-ConfigPath $settings
  $statePath = Join-Path $settings.stateDir 'cockpit-state.json'
  $flag = $settings.companionSkipFlag
  if ($flag -eq 'none') { $flag = '' }
  $game = @(Get-GameProcesses $settings.gameExe)
  $exeTxt = $settings.gameExe
  if (-not $exeTxt) { $exeTxt = '(unknown path: any process named X4 counts)' }

  Write-Host "config : $cfgPath"
  Write-Host "game   : $exeTxt - $(if ($game.Count) { 'RUNNING (pid ' + (($game | ForEach-Object { $_.Id }) -join ', ') + ')' } else { 'not running' })"
  $state = $null
  if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
  $modeTxt = 'OFF (no saved state)'
  if ($state) { $modeTxt = "ON since $($state.createdLocal) (state: $statePath)" }
  Write-Host "mode   : $modeTxt"
  $J.configPath = $cfgPath; $J.flag = [string]$flag
  $J.gameRunning = ($game.Count -gt 0); $J.gamePids = @($game | ForEach-Object { [int]$_.Id })
  $J.mode = $(if ($state) { 'on' } else { 'off' }); if ($state) { $J.since = [string]$state.createdLocal }

  $cfg = Read-ConfigFile $cfgPath
  $mis = @()
  foreach ($k in $settings.cockpit.Keys) {
    $e = @(Find-ConfigElement $cfg.Text $k)
    $cur = '(absent)'; if ($e.Count -ge 1) { $cur = $e[0].Value }
    $J.values[$k] = [ordered]@{ now = $cur; cockpit = [string]$settings.cockpit[$k] }
    if ($cur -ne [string]$settings.cockpit[$k]) { $mis += $k }
  }
  $J.mismatch = $mis; $J.valuesMatch = ($mis.Count -eq 0)

  if ($Mode -eq 'status') {
    foreach ($k in $settings.cockpit.Keys) {
      Write-Host (Fmt '  {0,-15} now {1,-8} cockpit {2}' $k $J.values[$k].now $settings.cockpit[$k])
    }
    if ($flag) { Write-Host "companion flag: $flag - $(if (Test-Path -LiteralPath $flag) { 'present' } else { 'absent' })" }
    Show-Companion $settings
    Done 0 $J.mode
  }

  if ($game.Count -gt 0) {
    if ($WhatIf) { Write-Host '(the game is running: a real run would be refused - the game rewrites config.xml when it exits)' }
    else {
      Write-Host "REFUSED: the game is running (pid $(($game | ForEach-Object { $_.Id }) -join ', ')). Close X4 first - it rewrites config.xml when it exits."
      Done 2 'refused-game-running' 'the game is running'
    }
  }

  if ($Mode -eq 'on') {
    $values = $settings.cockpit
    $edit = Get-ConfigEdit -Text $cfg.Text -Values $values
    $rows = @($edit.Changes | ForEach-Object {
        $from = $null; if ($_.Existed) { $from = $_.OldRaw }
        [pscustomobject]@{ Line = $_.Line; From = $from; To = $_.NewRaw; Changed = $_.Changed; Same = $_.NewRaw } })
    $n = @($edit.Changes | Where-Object { $_.Changed }).Count
    Write-Host "cockpit-on: $n of $($values.Count) value(s) to change:"
    Write-Diff $cfg.Text $rows
    if ($state) { Write-Host "(already ON: the originals saved on $($state.createdLocal) are kept; this run only re-applies the cockpit values)" }
    if ($WhatIf) { Write-Host 'WhatIf: nothing written.'; $J.changed = $n; Done 0 'whatif' }
    $problems = @(Test-ConfigValues $edit.NewText $values)
    if ($problems.Count) { throw "the edited text does not verify: $($problems -join '; ')" }
    if ($n -gt 0) {
      New-Item -ItemType Directory -Force -Path $settings.backupDir | Out-Null
      $bk = Get-UniqueBackupPath $settings.backupDir 'before-cockpit-on'
      [IO.File]::WriteAllBytes($bk, $cfg.Bytes)
      Write-Host "backup : $bk"; $J.backup = $bk
      Write-ConfigFile $cfgPath $edit.NewText $cfg.Bom
      $check = Read-ConfigFile $cfgPath
      $problems = @(Test-ConfigValues $check.Text $values)
      if ($problems.Count) {
        [IO.File]::WriteAllBytes($cfgPath, $cfg.Bytes)
        throw "written file does not verify ($($problems -join '; ')) - original bytes put back"
      }
    } else { $bk = $null }
    if (-not $state) {
      New-Item -ItemType Directory -Force -Path $settings.stateDir | Out-Null
      $st = [ordered]@{
        tool = 'x4cockpit3'; version = 1; configPath = $cfgPath
        createdLocal = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); backup = $bk
        changes = @($edit.Changes | ForEach-Object { [ordered]@{ key = $_.Key; existed = $_.Existed; oldRaw = $_.OldRaw; newRaw = $_.NewRaw } })
      }
      ($st | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $statePath -Encoding UTF8
      Write-Host "state  : $statePath"
    } else {
      # Keys added to settings.json after cockpit-on: remember their pre-cockpit form too, so off can undo them.
      $known = @($state.changes | ForEach-Object { $_.key })
      $extra = @($edit.Changes | Where-Object { $known -notcontains $_.Key -and $_.Changed })
      if ($extra.Count) {
        $all = @($state.changes | ForEach-Object { [ordered]@{ key = $_.key; existed = [bool]$_.existed; oldRaw = $_.oldRaw; newRaw = $_.newRaw } })
        $all += @($extra | ForEach-Object { [ordered]@{ key = $_.Key; existed = $_.Existed; oldRaw = $_.OldRaw; newRaw = $_.NewRaw } })
        $state.changes = $all
        ($state | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $statePath -Encoding UTF8
        Write-Host "state  : added $($extra.Count) key(s) to $statePath"
      }
    }
    if ($flag) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $flag) | Out-Null
      Set-Content -LiteralPath $flag -Value ("cockpit mode on since {0} - x4cockpit3" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
      Write-Host "flag   : $flag (companion watcher: skip opening its window)"
    }
    Show-Companion $settings
    Write-Host ''
    Write-Host 'Cockpit mode is ON. Next: start the game with  cockpit-launch.cmd -GameArgs "<your usual X4 arguments>"  (native window hook; see README).'
    $J.changed = $n; $J.mode = 'on'; $J.valuesMatch = $true; $J.mismatch = @(); Done 0 'on'
  }

  # ---- off
  if (-not $state) {
    Write-Host "Nothing to restore: cockpit mode is not on (no $statePath). Backups, if any: $($settings.backupDir)"
    if ($flag -and (Test-Path -LiteralPath $flag)) {
      if ($WhatIf) { Write-Host "WhatIf: would remove the stale companion flag $flag" } else { Remove-Item -LiteralPath $flag; Write-Host "removed stale companion flag $flag" }
    }
    Done 2 'already-off' 'cockpit mode is not on'
  }
  if (-not [string]::Equals([IO.Path]::GetFullPath($state.configPath), [IO.Path]::GetFullPath($cfgPath), [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "REFUSED: the saved state belongs to $($state.configPath), but the current profile config is $cfgPath. Set profileDir in settings.json."
    Done 2 'refused-profile-mismatch' 'the saved state belongs to another profile'
  }
  $saved = @($state.changes | ForEach-Object { [pscustomobject]@{ Key = $_.key; Existed = [bool]$_.existed; OldRaw = $_.oldRaw } })
  $res = Get-ConfigRestore -Text $cfg.Text -Saved $saved
  $rows = @($res.Changes | ForEach-Object { [pscustomobject]@{ Line = $_.Line; From = $_.From; To = $_.To; Changed = $_.Changed; Same = $_.To } })
  $n = @($res.Changes | Where-Object { $_.Changed }).Count
  Write-Host "cockpit-off: $n element(s) to restore:"
  Write-Diff $cfg.Text $rows
  if ($WhatIf) { Write-Host 'WhatIf: nothing written.'; $J.changed = $n; Done 0 'whatif' }
  try { $x = New-Object Xml.XmlDocument; $x.LoadXml($res.NewText) } catch { throw "restored text is not well-formed XML: $($_.Exception.Message)" }
  if ($n -gt 0) {
    New-Item -ItemType Directory -Force -Path $settings.backupDir | Out-Null
    $bk = Get-UniqueBackupPath $settings.backupDir 'before-cockpit-off'
    [IO.File]::WriteAllBytes($bk, $cfg.Bytes)
    Write-Host "backup : $bk"; $J.backup = $bk
    Write-ConfigFile $cfgPath $res.NewText $cfg.Bom
  }
  Remove-Item -LiteralPath $statePath
  if ($flag -and (Test-Path -LiteralPath $flag)) { Remove-Item -LiteralPath $flag; Write-Host "flag   : removed $flag" }
  Write-Host 'Cockpit mode is OFF: the previous values are back. The companion window will open normally on the next game start.'
  $J.changed = $n; $J.mode = 'off'; $J.mismatch = @($settings.cockpit.Keys | Where-Object { $e = @(Find-ConfigElement $res.NewText $_); -not ($e.Count -ge 1 -and $e[0].Value -eq [string]$settings.cockpit[$_]) }); $J.valuesMatch = ($J.mismatch.Count -eq 0); Done 0 'off'
} catch {
  Write-Host "ERROR: $($_.Exception.Message)"
  if (-not $J.message) { $J.message = $_.Exception.Message }; Done 1 'error'
}
