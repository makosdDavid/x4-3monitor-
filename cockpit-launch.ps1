<#
.SYNOPSIS
  cockpit-launch - start X4 with the native window hook so the game itself opens ONE borderless window over
  side | centre | side monitors (see README "Native window hook").

.DESCRIPTION
  1. Reads the live monitor topology with the kit's own layout code ('triple' preset) and refuses if the Windows
     arrangement does not match (the "!" lines say what to move). -Force uses the computed rectangle anyway;
     -Rect "x,y,w,h" skips the topology and uses exactly that rectangle.
  2. Checks that cockpit mode is ON (the same facts 'cockpit.ps1 status' shows: saved state present and every
     cockpit value in config.xml). If not: tells you to run cockpit-on.cmd with the game closed. It never edits
     config.xml itself.
  3. Refuses while the configured X4.exe already runs (the hook must be in place before the window exists).
  4. Starts native\out\launcher.exe DETACHED through WMI (Win32_Process.Create), so closing this shell does not
     take the game with it. The launcher starts X4.exe with the hook DLL and passes -GameArgs through.

  -WhatIf prints everything and the exact command, and starts nothing.
  Turning it off = start the game the normal way (and cockpit-off.cmd for the config values).

.EXAMPLE
  .\cockpit-launch.ps1 -GameArgs "-debug all -logfile debug.log"
  .\cockpit-launch.ps1 -WhatIf
  .\cockpit-launch.ps1 -Rect "-1920,0,7280,1440" -GameArgs "-debug all -logfile debug.log"
#>
[CmdletBinding()]
param(
  [string]$Rect = '',
  [switch]$Force,
  [string]$GameArgs = '',
  [switch]$WhatIf,
  [string]$SettingsFile = '',
  [string]$MonitorsJson = '',
  [string]$LogDir = '',
  [int]$WaitSeconds = 30
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Layout.ps1')
. (Join-Path $here 'lib\Config.ps1')
. (Join-Path $here 'lib\Native.ps1')

function Quote([string]$s) { if ($s -match '[\s"]' -or $s -eq '') { return '"' + $s + '"' } return $s }

try {
  $settings = Read-CockpitSettings -ToolRoot $here -SettingsFile $SettingsFile
  $exe = $settings.gameExe
  if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { Write-Host "REFUSED: game exe not found (gameExe='$exe'). Set gameExe in settings.json."; exit 2 }
  $exe = [IO.Path]::GetFullPath($exe)
  if ([IO.Path]::GetFileName($exe) -ne 'X4.exe') { Write-Host "REFUSED: gameExe must point to X4.exe (got $exe)."; exit 2 }
  Write-Host "game   : $exe"

  # ---------------------------------------------------------------- rectangle
  if ($Rect) {
    $v = @($Rect -split ',' | ForEach-Object { $_.Trim() })
    if ($v.Count -ne 4 -or @($v | Where-Object { $_ -notmatch '^-?\d+$' }).Count -gt 0 -or [int]$v[2] -lt 16 -or [int]$v[3] -lt 16) {
      Write-Host "REFUSED: -Rect must be ""x,y,w,h"" with integers and w,h >= 16 (got '$Rect')."; exit 2
    }
    $R = [pscustomobject]@{ X = [int]$v[0]; Y = [int]$v[1]; W = [int]$v[2]; H = [int]$v[3] }
    Write-Host (Fmt 'rect   : ({0},{1}) {2}x{3} (from -Rect, monitor arrangement not checked)' $R.X $R.Y $R.W $R.H)
  } else {
    if ($MonitorsJson) { $mons = @(Read-MonitorsJson $MonitorsJson); Write-Host "(synthetic monitor topology from $MonitorsJson)" }
    else { $mons = @(Get-LiveMonitors) }
    foreach ($m in $mons | Sort-Object X) {
      $prim = ''; if ($m.Primary) { $prim = ' primary' }
      Write-Host (Fmt '  monitor {0,-40} {1,5}x{2,-5} at x={3,6} y={4,5}{5}' (Get-MonitorLabel $m) $m.W $m.H $m.X $m.Y $prim)
    }
    $plan = Get-CockpitPlan -Mons $mons -Preset 'triple' -Settings $settings
    foreach ($x in $plan.Problems) { Write-Host "   ! $x" }
    foreach ($x in $plan.Notes) { Write-Host "   - $x" }
    if (-not $plan.Ok -and -not $Force) {
      Write-Host "REFUSED: the Windows monitor arrangement does not match 'triple' (see the ! lines). Fix it in Windows display settings, or add -Force / -Rect ""x,y,w,h""."
      exit 2
    }
    $R = $plan.Rect
    $how = 'triple preset, arrangement OK'; if (-not $plan.Ok) { $how = 'triple preset, arrangement does NOT match - forced' }
    Write-Host (Fmt 'rect   : ({0},{1}) {2}x{3} ({4})' $R.X $R.Y $R.W $R.H $how)
  }

  # ---------------------------------------------------------------- cockpit mode (read-only check)
  $cfgPath = Resolve-ConfigPath $settings
  $statePath = Join-Path $settings.stateDir 'cockpit-state.json'
  $cfg = Read-ConfigFile $cfgPath
  $off = @()
  foreach ($k in $settings.cockpit.Keys) {
    $e = @(Find-ConfigElement $cfg.Text $k)
    $cur = '(absent)'; if ($e.Count -ge 1) { $cur = $e[0].Value }
    if ($cur -ne [string]$settings.cockpit[$k]) { $off += "$k is $cur, cockpit value $($settings.cockpit[$k])" }
  }
  Write-Host "config : $cfgPath"
  if (-not (Test-Path -LiteralPath $statePath) -or $off.Count -gt 0) {
    foreach ($x in $off) { Write-Host "   ! $x" }
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Host "   ! no saved cockpit state ($statePath)" }
    Write-Host 'REFUSED: cockpit mode is not ON. Close the game and run  cockpit-on.cmd  first (this tool does not change config.xml).'
    exit 2
  }
  Write-Host 'mode   : cockpit ON (all cockpit values in config.xml)'
  $rw = [string]$settings.cockpit['res_width']; $rh = [string]$settings.cockpit['res_height']
  if ($rw -and $rh -and ($rw -ne "$($R.W)" -or $rh -ne "$($R.H)")) {
    Write-Host "   ! warning: config res ${rw}x${rh} differs from the window $($R.W)x$($R.H) - the game may render at the config size and scale."
  }

  # ---------------------------------------------------------------- game must not run yet
  $game = @(Get-GameProcesses $exe)
  if ($game.Count -gt 0) { Write-Host "REFUSED: the game is already running (pid $(($game | ForEach-Object { $_.Id }) -join ', ')). Close it first."; exit 2 }

  # ---------------------------------------------------------------- launcher
  $out = Join-Path $here 'native\out'
  $launcher = Join-Path $out 'launcher.exe'
  $dll = Join-Path $out 'x4c3hook.dll'
  foreach ($f in $launcher, $dll) { if (-not (Test-Path -LiteralPath $f)) { Write-Host "REFUSED: $f is missing. Build it first: native\build.cmd"; exit 2 } }
  $logDirEff = $out
  $parts = @((Quote $launcher), '--exe', (Quote $exe), '--rect', ('{0},{1},{2},{3}' -f $R.X, $R.Y, $R.W, $R.H))
  if ($LogDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; $logDirEff = [IO.Path]::GetFullPath($LogDir); $parts += @('--log-dir', (Quote $logDirEff)) }
  $cmd = $parts -join ' '
  if ($GameArgs) { $cmd += ' -- ' + $GameArgs }
  Write-Host "command: $cmd"
  Write-Host "logs   : $(Join-Path $logDirEff 'launcher.log') and $(Join-Path $logDirEff 'x4c3hook.log')"
  if ($WhatIf) { Write-Host 'WhatIf: nothing started.'; exit 0 }

  # Detached: created by the WMI service, not as a child of this shell (a child was seen to die with the shell).
  $launchLog = Join-Path $logDirEff 'launcher.log'
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $out }
  if ($r.ReturnValue -ne 0) { Write-Host "ERROR: Win32_Process.Create failed (code $($r.ReturnValue))"; exit 1 }
  $lp = [int]$r.ProcessId
  Write-Host "launcher started detached (pid $lp); waiting for its result..."
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $line = $null; $refused = $null
  while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds) {
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path -LiteralPath $launchLog)) { continue }
    $mine = @(Get-Content -LiteralPath $launchLog -Encoding UTF8 | Where-Object { $_ -match "\[$lp\] " })
    $line = $mine | Where-Object { $_ -match 'pid=\d+ hook=' } | Select-Object -Last 1
    $refused = $mine | Where-Object { $_ -match 'REFUSED|ERROR' } | Select-Object -Last 1
    if ($line -or $refused) { break }
  }
  if ($refused -and -not $line) { Write-Host "launcher: $refused"; exit 1 }
  if (-not $line) { Write-Host "no result from the launcher within $WaitSeconds s - see $launchLog"; exit 1 }
  Write-Host "launcher: $($line -replace '^.*\] ', '')"
  if ($line -match 'hook=ACTIVE') {
    Write-Host 'OK: the game was started with the window hook. Back to normal: close the game, then cockpit-off.cmd.'
    exit 0
  }
  Write-Host "The game was started WITHOUT the hook (fail-safe). Reason: see $launchLog and $(Join-Path $logDirEff 'x4c3hook.log')."
  exit 3
} catch {
  Write-Host "ERROR: $($_.Exception.Message)"
  exit 1
}
