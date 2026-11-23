<#
.SYNOPSIS
  x4cockpit3 - check the monitor arrangement and stretch the X4 window over side | centre | side monitors.

.DESCRIPTION
  Without arguments: prints the monitors Windows sees and whether the arrangement matches the 'triple' target
  (and the 'uw-left-only' test step), in plain words. Nothing is changed.

  With -Preset: computes the window rectangle from the LIVE monitor topology (centre/side monitors are found by
  primary flag / EDID code or name, never by hard-coded coordinates), refuses if the arrangement does not match
  (unless -Force), then makes the game window borderless and gives it exactly that client rectangle.
  -Restore puts the window back the way it was before the first -Preset.

  Reads (never writes) the game's config.xml to warn if res_width/res_height or the window mode do not fit.
  Changes no display, driver or game setting.

.EXAMPLE
  .\x4cockpit3.ps1                              # arrangement check (triple + uw-left-only)
  .\x4cockpit3.ps1 -Preset uw-left-only -WhatIf # what would happen
  .\x4cockpit3.ps1 -Preset uw-left-only         # stretch the running game window
  .\x4cockpit3.ps1 -Preset triple
  .\x4cockpit3.ps1 -Restore
  .\x4cockpit3.ps1 -Simulate target             # the target arrangement on paper
  .\x4cockpit3.ps1 -Check -SeatMm 600           # which fov fits a 60 cm eye distance
  .\x4cockpit3.ps1 -Json                        # arrangement check + one "@@X4JSON {...}" line (for the x4switch manager)

  -Json (check mode, i.e. without -Preset): after the normal text, one line "@@X4JSON " + compact JSON:
    { tool, action:"check", exit, monitors:[{device,name,code,x,y,w,h,primary,role,widthMm,heightMm,source}],
      triple:{ ok, problems[], notes[], rect{x,y,w,h}, left, centre, right }, summary:"Left | Centre | Right" }
  Exit codes: 0 = triple (and uw-left-only) match, 2 = an arrangement does not match, 1 = error.
#>
[CmdletBinding()]
param(
  [string]$Preset = '',
  [switch]$Check,
  [switch]$WhatIf,
  [switch]$Restore,
  [switch]$Force,
  [string]$Handle = '',
  [switch]$NoActivate,
  [switch]$ZBottom,
  [switch]$Popup,
  [string]$Area = '',
  [string]$SettingsFile = '',
  [string]$MonitorsJson = '',
  [ValidateSet('none', 'target')][string]$Simulate = 'none',
  [double]$Fov = 0,
  [int]$SeatMm = 0,
  [switch]$Json
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 + "powershell -File": $PSScriptRoot is empty in param defaults, so compute it here.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Layout.ps1')
. (Join-Path $here 'lib\Native.ps1')

$aliases = @{ 'k1' = 'uw-left-only'; 'left' = 'uw-left-only'; 'k2' = 'triple'; 'uw' = 'single'; 'single-uw' = 'single' }
if ($Preset -and $aliases.ContainsKey($Preset.ToLower())) { $Preset = $aliases[$Preset.ToLower()] }
if ($Preset -and -not $script:PresetInfo.Contains($Preset)) { Write-Host "Unknown preset '$Preset'. Known: $($script:PresetInfo.Keys -join ', ')"; exit 1 }

try {
  $settings = Read-CockpitSettings -ToolRoot $here -SettingsFile $SettingsFile

  # ---------------------------------------------------------------- monitors
  $synthetic = $false
  if ($MonitorsJson) { $mons = @(Read-MonitorsJson $MonitorsJson); $synthetic = $true; Write-Host "(synthetic monitor topology from $MonitorsJson)" }
  else { $mons = @(Get-LiveMonitors) }
  if ($Simulate -eq 'target') {
    $mons = @(Get-SimulatedTarget $mons $settings)
    $synthetic = $true
    Write-Host '(SIMULATION: the target arrangement on paper - Windows settings are not changed, no window is moved)'
  }
  if ($synthetic -and $Preset -and -not $Check) { $WhatIf = $true }

  $centre = Resolve-CentreMonitor $mons $settings
  Write-Host 'Monitors as Windows sees them now (physical pixels):'
  foreach ($m in $mons | Sort-Object X) {
    $role = 'not used'
    if ($centre -and $m.Device -eq $centre.Device) { $role = 'CENTRE' }
    elseif (Test-MonitorMatch $m $settings.sideMatch) { $role = 'side' }
    $hz = ''; if ($m.Hz -gt 0) { $hz = "@$($m.Hz)Hz" }
    $prim = ''; if ($m.Primary) { $prim = ' primary' }
    Write-Host (Fmt '  {0,-40} {1,5}x{2,-5}{3,-7} at x={4,6} y={5,5}  {6}x{7} mm  {8:0.0000} mm/px{9}  -> {10}' (Get-MonitorLabel $m) $m.W $m.H $hz $m.X $m.Y $m.WidthMm $m.HeightMm $m.PitchMm $prim $role)
  }
  if ($settings.sideMatch) { Write-Host "  (side monitors = EDID code/name matching '$($settings.sideMatch)'; settings: $($settings._file))" }
  Write-Host ''

  $fovSetting = $Fov
  if ($fovSetting -le 0) { $fovSetting = [double]$settings.cockpit.fov }
  if ($fovSetting -le 0) { $fovSetting = 0.6667 }

  # ---------------------------------------------------------------- restore
  if ($Restore) {
    if ($Handle) { $h = ConvertTo-Hwnd $Handle } else {
      $gp = @(Get-GameProcesses $settings.gameExe -RequirePathMatch | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
      if ($gp.Count -eq 0) { throw 'no running game window found' }
      $h = $gp[0].MainWindowHandle
    }
    $res = Restore-SpanWindow -Hwnd $h -StateDir $settings.stateDir -NoActivate:$NoActivate -WhatIf:$WhatIf
    if ($WhatIf) { Write-Host (Fmt 'WhatIf: would restore style=0x{0:X} ex=0x{1:X} rect=({2},{3}) {4}x{5}' ([int64]$res.Saved.Style) ([int64]$res.Saved.ExStyle) $res.Saved.X $res.Saved.Y $res.Saved.W $res.Saved.H); exit 0 }
    Write-Host (Fmt 'Restored: rect=({0},{1}) {2}x{3}, client {4}x{5}, style=0x{6:X}' $res.After.X $res.After.Y $res.After.W $res.After.H $res.After.ClientW $res.After.ClientH $res.After.Style)
    exit 0
  }

  # ---------------------------------------------------------------- check / plan
  $toShow = @($Preset)
  if (-not $Preset) { $toShow = @('triple', 'uw-left-only'); $Check = $true }
  $exit = 0
  $plan = $null
  foreach ($p in $toShow) {
    $pl = Get-CockpitPlan -Mons $mons -Preset $p -Settings $settings -Area $Area
    if ($p -eq $Preset) { $plan = $pl }
    if ($p -eq 'triple') { $triplePlan = $pl }
    Write-Host "== $p : $($script:PresetInfo[$p])"
    if ($pl.Ok) { Write-Host '   ARRANGEMENT: OK' } else { Write-Host "   ARRANGEMENT: DOES NOT MATCH ($($pl.Problems.Count) problem(s))" }
    foreach ($x in $pl.Problems) { Write-Host "   ! $x" }
    foreach ($x in $pl.Notes) { Write-Host "   - $x" }
    foreach ($x in (Get-CockpitAnalysis -Plan $pl -Mons $mons -FovSetting $fovSetting -BaseAspect $settings.fovBaseAspect)) { Write-Host "   $x" }
    if ($SeatMm -gt 0 -and $pl.Rect -and $pl.Centre.PitchMm -gt 0) {
      $fs = Get-FovForSeat $SeatMm ($pl.Rect.H / 2.0) $pl.Centre.PitchMm $settings.fovBaseAspect
      $note = ''
      if ($fs -lt 0.6667) { $note = ' - below the in-game slider minimum (60deg); whether the game keeps such a value from config.xml is NOT verified' }
      Write-Host (Fmt '   eye {0} mm from the centre monitor -> fov {1:0.0000} ({2:0.0}deg){3}' $SeatMm $fs ($fs * 90) $note)
    }
    Write-Host ''
    if (-not $pl.Ok) { $exit = 2 }
  }

  # Game config (read-only): does it fit the window?
  $cfgPath = $null
  try { $cfgPath = Resolve-ConfigPath $settings } catch { Write-Host "config.xml: $($_.Exception.Message)" }
  if ($cfgPath) {
    try {
      $x = New-Object Xml.XmlDocument; $x.Load($cfgPath)
      $cw = $x.DocumentElement.SelectSingleNode('res_width'); $ch = $x.DocumentElement.SelectSingleNode('res_height')
      $fs = $x.DocumentElement.SelectSingleNode('fullscreen'); $bl = $x.DocumentElement.SelectSingleNode('borderless')
      $mode = 'windowed'
      if ($fs -and $fs.InnerText -eq 'true') { $mode = 'fullscreen' } elseif ($bl -and $bl.InnerText -eq 'true') { $mode = 'borderless' }
      Write-Host "game config ($cfgPath, read-only): mode=$mode res=$($cw.InnerText)x$($ch.InnerText)"
      $ref = $plan
      if (-not $ref) { $ref = Get-CockpitPlan -Mons $mons -Preset 'triple' -Settings $settings }
      if ($mode -ne 'windowed') { Write-Host '   ! the game is not in Windowed mode - run cockpit-on (with the game closed) first; Borderless ignores res_width.' }
      if ($ref.Rect -and $Preset -ne 'single' -and ($cw.InnerText -ne "$($ref.Rect.W)" -or $ch.InnerText -ne "$($ref.Rect.H)")) {
        Write-Host "   ! game resolution $($cw.InnerText)x$($ch.InnerText) differs from the window $($ref.Rect.W)x$($ref.Rect.H) - the image would be rescaled (or the game rebuilds its swapchain; not verified)."
      }
    } catch { Write-Host "config.xml unreadable: $($_.Exception.Message)" }
  }

  if ($Check -or -not $Preset) {
    if ($Json) {
      $tp = $triplePlan
      if (-not $tp) { $tp = Get-CockpitPlan -Mons $mons -Preset 'triple' -Settings $settings }
      function ShortName($m) { if (-not $m) { return '?' }; if ($m.Name) { return $m.Name }; if ($m.Code -and $m.Code -ne '?') { return $m.Code }; return ($m.Device -replace '^\\\\\.\\', '') }
      $role = @{}
      if ($tp.Centre) { $role[$tp.Centre.Device] = 'centre' }
      if ($tp.Left) { $role[$tp.Left.Device] = 'left' }
      if ($tp.Right) { $role[$tp.Right.Device] = 'right' }
      $r = $null; if ($tp.Rect) { $r = [ordered]@{ x = $tp.Rect.X; y = $tp.Rect.Y; w = $tp.Rect.W; h = $tp.Rect.H } }
      Write-X4Json ([ordered]@{
          tool = 'x4cockpit3'; action = 'check'; exit = $exit; synthetic = $synthetic
          monitors = @($mons | Sort-Object X | ForEach-Object {
              $ro = 'unused'; if ($role.ContainsKey($_.Device)) { $ro = $role[$_.Device] }
              [ordered]@{ device = $_.Device; name = $_.Name; code = $_.Code; x = $_.X; y = $_.Y; w = $_.W; h = $_.H; primary = [bool]$_.Primary
                role = $ro; widthMm = $_.WidthMm; heightMm = $_.HeightMm; source = [string]$_.PathSource } })
          triple = [ordered]@{ ok = [bool]$tp.Ok; problems = @($tp.Problems); notes = @($tp.Notes); rect = $r
            left = (ShortName $tp.Left); centre = (ShortName $tp.Centre); right = (ShortName $tp.Right) }
          summary = ('{0} | {1} | {2}' -f (ShortName $tp.Left), (ShortName $tp.Centre), (ShortName $tp.Right))
        })
    }
    exit $exit
  }
  if ($WhatIf) { Write-Host 'WhatIf: nothing changed.'; exit $exit }
  if (-not $plan.Ok -and -not $Force) {
    Write-Host "REFUSED: the Windows arrangement does not match '$Preset' (see the ! lines). Fix the arrangement, or add -Force to stretch anyway."
    exit 2
  }

  # ---------------------------------------------------------------- move the window
  if ($Handle) { $h = ConvertTo-Hwnd $Handle } else {
    $gp = @(Get-GameProcesses $settings.gameExe -RequirePathMatch | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    if ($gp.Count -eq 0) { throw "no running game window found (gameExe='$($settings.gameExe)')" }
    $h = $gp[0].MainWindowHandle
  }
  $res = Set-SpanWindow -Hwnd $h -Rect $plan.Rect -Mons $mons -StateDir $settings.stateDir -Popup:$Popup -NoActivate:$NoActivate -ZBottom:$ZBottom -Force:$Force
  foreach ($m in $res.Messages) { Write-Host "($m)" }
  Start-Sleep -Milliseconds 1000   # an application that enforces its own rectangle may put the window back shortly after
  $b = $res.Before; $a = Get-WinInfo $h; $r = $plan.Rect
  Write-Host (Fmt 'requested client ({0},{1}) {2}x{3}' $r.X $r.Y $r.W $r.H)
  Write-Host (Fmt 'before  : window ({0},{1}) {2}x{3}, client ({4},{5}) {6}x{7}, style 0x{8:X}' $b.X $b.Y $b.W $b.H $b.ClientX $b.ClientY $b.ClientW $b.ClientH $b.Style)
  Write-Host (Fmt 'at once : window ({0},{1}) {2}x{3}, client ({4},{5}) {6}x{7}, style 0x{8:X}' $res.After.X $res.After.Y $res.After.W $res.After.H $res.After.ClientX $res.After.ClientY $res.After.ClientW $res.After.ClientH $res.After.Style)
  Write-Host (Fmt 'after 1s: window ({0},{1}) {2}x{3}, client ({4},{5}) {6}x{7}, style 0x{8:X}' $a.X $a.Y $a.W $a.H $a.ClientX $a.ClientY $a.ClientW $a.ClientH $a.Style)
  $exactNow = ($a.ClientX -eq $r.X -and $a.ClientY -eq $r.Y -and $a.ClientW -eq $r.W -and $a.ClientH -eq $r.H)
  $same = ($a.X -eq $b.X -and $a.Y -eq $b.Y -and $a.W -eq $b.W -and $a.H -eq $b.H -and $a.Style -eq $b.Style)
  if ($exactNow) { Write-Host 'OK: the client area is exactly the requested rectangle.' }
  elseif ($same -and -not $res.Exact -and ($res.After.X -eq $b.X -and $res.After.W -eq $b.W -and $res.After.Style -eq $b.Style)) {
    Write-Host 'REFUSED BY THE APPLICATION: the window did not move, resize or change style at all (the calls returned success, the application kept its own rectangle).'
    Write-Host '  X4 9.00 keeps its window inside the screen selected in its own settings - see README "Live test result". Nothing was changed.'
    Remove-Item -LiteralPath $res.StatePath -ErrorAction SilentlyContinue
    exit 3
  } elseif ($same) {
    Write-Host 'REFUSED BY THE APPLICATION: the window changed and was put back within 1 s.'
    Remove-Item -LiteralPath $res.StatePath -ErrorAction SilentlyContinue
    exit 3
  } else { Write-Host '! PARTLY: the client area is NOT the requested rectangle (Windows or the application limited it).'; exit 3 }
  $hint = ''; if ($Handle) { $hint = " -Handle $Handle" }
  Write-Host "Undo: .\x4cockpit3.ps1 -Restore$hint   (saved: $($res.StatePath))"
  exit 0
} catch {
  Write-Host "ERROR: $($_.Exception.Message)"
  if ($Json) { Write-X4Json ([ordered]@{ tool = 'x4cockpit3'; action = 'check'; exit = 1; error = $_.Exception.Message }) }
  exit 1
}
