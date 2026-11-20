# x4cockpit3 - monitor roles, preset rectangles, arrangement check and projection maths.
# Pure functions: they take a monitor list (live or synthetic) and never touch windows or settings files.
# A monitor object has: Device, Name, Code, X, Y, W, H, Primary, WidthMm, HeightMm, PitchMm, Hz.

$script:PresetInfo = [ordered]@{
  'triple'       = 'side | centre | side: one window over all three monitors (needs one side monitor on each side)'
  'uw-left-only' = 'test step without rearranging: same 7280-wide window centred on the centre monitor; the left side monitor shows its part, the right part is off-screen'
  'single'       = 'back to the centre monitor only (window = centre monitor rectangle)'
  'custom'       = 'any rectangle: -Area "x,y,w,h" (experiments)'
}

function Get-MonitorLabel($m) {
  $n = $m.Name
  if (-not $n) { $n = '(no name)' }
  $dev = ($m.Device -replace '^\\\\\.\\', '')
  return "$dev $n [$($m.Code)]"
}

function Test-MonitorMatch($m, [string]$Pattern) {
  if (-not $Pattern) { return $true }
  return (("$($m.Code)" -match $Pattern) -or ("$($m.Name)" -match $Pattern))
}

function Resolve-CentreMonitor($Mons, $Settings) {
  $mons = @($Mons)
  if ($Settings.centreMatch) {
    $c = @($mons | Where-Object { Test-MonitorMatch $_ $Settings.centreMatch })
    if ($c.Count -eq 0) { return $null }
    $p = @($c | Where-Object { $_.Primary })
    if ($p.Count -gt 0) { return $p[0] }
    return $c[0]
  }
  $p = @($mons | Where-Object { $_.Primary })
  if ($p.Count -gt 0) { return $p[0] }
  return ($mons | Sort-Object { $_.W / [double]$_.H } -Descending | Select-Object -First 1)
}

function Test-VOverlap($a, $b) { return (([Math]::Min($a.Y + $a.H, $b.Y + $b.H) - [Math]::Max($a.Y, $b.Y)) -gt 0) }
function Test-LeftOf($m, $c) { return ((($m.X + $m.W) -eq $c.X) -and (Test-VOverlap $m $c)) }
function Test-RightOf($m, $c) { return (($m.X -eq ($c.X + $c.W)) -and (Test-VOverlap $m $c)) }

function Get-SideTarget($Side, $Centre, [string]$Where) {
  $y = $Centre.Y + [int][Math]::Round(($Centre.H - $Side.H) / 2.0)
  if ($Where -eq 'left') { $x = $Centre.X - $Side.W } else { $x = $Centre.X + $Centre.W }
  return [pscustomobject]@{ X = $x; Y = $y }
}

function Test-SidePlacement($Plan, $Side, $Centre, [string]$Where, $Settings) {
  # Side monitor is already adjacent; check that its rows lie inside the window rows and report Y offset.
  $t = Get-SideTarget $Side $Centre $Where
  $label = Get-MonitorLabel $Side
  if ($Side.H -gt $Centre.H) {
    $Plan.Problems += "$Where side ${label}: taller ($($Side.H) px) than the centre monitor ($($Centre.H) px) - the window cannot cover it."
    return
  }
  $top = $Side.Y - $Centre.Y
  $bottom = ($Side.Y + $Side.H) - ($Centre.Y + $Centre.H)
  if ($top -lt 0 -or $bottom -gt 0) {
    $out = [Math]::Max(-$top, $bottom)
    $Plan.Problems += (Fmt '{0} side {1}: {2} of its rows lie outside the window (Windows has it at y={3}, the window covers y={4}..{5}). Move it to x={6}, y={7} in Windows display settings.' $Where $label $out $Side.Y $Centre.Y ($Centre.Y + $Centre.H - 1) $t.X $t.Y)
    return
  }
  $dy = $Side.Y - $t.Y
  if ([Math]::Abs($dy) -gt $Settings.yTolerancePx) {
    $mm = ''
    if ($Side.PitchMm -gt 0) { $mm = Fmt ' (= {0:0} mm on that monitor)' ([Math]::Abs($dy) * $Side.PitchMm) }
    if ($dy -lt 0) { $dir = 'higher'; $phys = 'raise' } else { $dir = 'lower'; $phys = 'lower' }
    $Plan.Notes += (Fmt '{0} side {1}: Windows has it {2} px {3} than vertically centred (y={4}, centred = {5}). The image stays complete; either set y={5} in Windows, or {6} that monitor physically by {2} px{7} so the horizon lines up.' $Where $label ([Math]::Abs($dy)) $dir $Side.Y $t.Y $phys $mm)
  } else {
    $Plan.Notes += (Fmt '{0} side {1}: position OK (y={2}, centred = {3}).' $Where $label $Side.Y $t.Y)
  }
}

function Get-CockpitPlan {
  # Returns: Preset, Ok, Problems[], Notes[], Centre, Left, Right, Rect {X,Y,W,H}
  param($Mons, [string]$Preset, $Settings, [string]$Area = '')
  $mons = @($Mons)
  $plan = [pscustomobject]@{ Preset = $Preset; Ok = $true; Problems = @(); Notes = @(); Centre = $null; Left = $null; Right = $null; Rect = $null }
  $c = Resolve-CentreMonitor $mons $Settings
  if (-not $c) {
    $plan.Problems += "No centre monitor found (centreMatch='$($Settings.centreMatch)'). Monitors: " + (($mons | ForEach-Object { Get-MonitorLabel $_ }) -join '; ')
    $plan.Ok = $false
    return $plan
  }
  $plan.Centre = $c
  $sides = @($mons | Where-Object { $_.Device -ne $c.Device -and (Test-MonitorMatch $_ $Settings.sideMatch) })
  $others = @($mons | Where-Object { $_.Device -ne $c.Device -and -not (Test-MonitorMatch $_ $Settings.sideMatch) })
  $cl = Get-MonitorLabel $c

  switch ($Preset) {
    'single' {
      $plan.Rect = [pscustomobject]@{ X = $c.X; Y = $c.Y; W = $c.W; H = $c.H }
    }
    'custom' {
      if (-not $Area) { throw 'custom: -Area "x,y,w,h" is required' }
      $v = @($Area -split ',' | ForEach-Object { [int]$_.Trim() })
      if ($v.Count -ne 4 -or $v[2] -le 0 -or $v[3] -le 0) { throw 'custom: -Area must be "x,y,w,h" with positive w and h' }
      $plan.Rect = [pscustomobject]@{ X = $v[0]; Y = $v[1]; W = $v[2]; H = $v[3] }
    }
    'uw-left-only' {
      $l = @($sides | Where-Object { Test-LeftOf $_ $c }) | Select-Object -First 1
      if (-not $l) {
        $plan.Problems += "No side monitor directly left of the centre monitor $cl. Needed: a side monitor whose right edge touches x=$($c.X)."
        $w = 1920
        $any = @($sides) | Select-Object -First 1
        if ($any) { $w = $any.W }
        $plan.Rect = [pscustomobject]@{ X = $c.X - $w; Y = $c.Y; W = $c.W + 2 * $w; H = $c.H }
      } else {
        $plan.Left = $l
        Test-SidePlacement $plan $l $c 'left' $Settings
        $plan.Rect = [pscustomobject]@{ X = $c.X - $l.W; Y = $c.Y; W = $c.W + 2 * $l.W; H = $c.H }
        $plan.Notes += (Fmt 'The right {0} px of the window are rendered but off-screen (test step only; markers there are invisible).' $l.W)
        $r = @($sides | Where-Object { Test-RightOf $_ $c }) | Select-Object -First 1
        if ($r) { $plan.Notes += "A side monitor is also right of the centre ($(Get-MonitorLabel $r)) - the 'triple' preset fits this arrangement." }
      }
    }
    'triple' {
      $l = @($sides | Where-Object { Test-LeftOf $_ $c }) | Select-Object -First 1
      $r = @($sides | Where-Object { (Test-RightOf $_ $c) -and (-not $l -or $_.Device -ne $l.Device) }) | Select-Object -First 1
      $plan.Left = $l; $plan.Right = $r
      $used = @(); if ($l) { $used += $l.Device }; if ($r) { $used += $r.Device }
      $rest = @($sides | Where-Object { $used -notcontains $_.Device } | Sort-Object X)
      if (-not $l) {
        if ($rest.Count -gt 0) {
          $m = $rest[0]; $rest = @($rest | Select-Object -Skip 1)
          $t = Get-SideTarget $m $c 'left'
          $plan.Problems += (Fmt 'LEFT: {0} is at x={1}, y={2}. Move it in Windows display settings so that it sits directly LEFT of {3}: x={4}, y={5} (its right edge touching the centre monitor, vertically centred).' (Get-MonitorLabel $m) $m.X $m.Y $cl $t.X $t.Y)
          $plan.Left = $m
        } else {
          $plan.Problems += "LEFT: no side monitor available for the left position."
        }
      }
      if (-not $r) {
        if ($rest.Count -gt 0) {
          $m = $rest[$rest.Count - 1]
          $t = Get-SideTarget $m $c 'right'
          $plan.Problems += (Fmt 'RIGHT: {0} is at x={1}, y={2}. Move it in Windows display settings so that it sits directly RIGHT of {3}: x={4}, y={5} (its left edge touching the centre monitor, vertically centred).' (Get-MonitorLabel $m) $m.X $m.Y $cl $t.X $t.Y)
          $plan.Right = $m
        } else {
          $plan.Problems += "RIGHT: no side monitor available for the right position."
        }
      }
      $nSides = @($sides).Count
      if ($nSides -lt 2) {
        $msg = "Only $nSides side monitor(s) found"
        if ($Settings.sideMatch) { $msg += " matching sideMatch '$($Settings.sideMatch)'" }
        $msg += '; triple needs 2.'
        if ($others.Count -gt 0) { $msg += ' Not used as a side monitor: ' + (($others | ForEach-Object { Get-MonitorLabel $_ }) -join '; ') + '.' }
        $plan.Problems += $msg
      }
      if ($l) { Test-SidePlacement $plan $l $c 'left' $Settings }
      if ($r) { Test-SidePlacement $plan $r $c 'right' $Settings }
      $lw = 1920; $rw = 1920
      if ($plan.Left) { $lw = $plan.Left.W } elseif ($plan.Right) { $lw = $plan.Right.W }
      if ($plan.Right) { $rw = $plan.Right.W } elseif ($plan.Left) { $rw = $plan.Left.W }
      $plan.Rect = [pscustomobject]@{ X = $c.X - $lw; Y = $c.Y; W = $c.W + $lw + $rw; H = $c.H }
      if ($lw -ne $rw) { $plan.Notes += (Fmt 'Side widths differ ({0} vs {1} px): the window centre (crosshair) is {2} px off the centre monitor''s centre.' $lw $rw (($rw - $lw) / 2)) }
    }
    default { throw "unknown preset '$Preset' (known: $($script:PresetInfo.Keys -join ', '))" }
  }
  # Monitors that would show part of the window although they are not part of the layout.
  $inPlan = @($c.Device); if ($plan.Left) { $inPlan += $plan.Left.Device }; if ($plan.Right) { $inPlan += $plan.Right.Device }
  if ($plan.Rect -and $Preset -ne 'custom' -and $Preset -ne 'single') {
    foreach ($m in $mons) {
      if ($inPlan -contains $m.Device) { continue }
      $ix = [Math]::Max($plan.Rect.X, $m.X); $ax = [Math]::Min($plan.Rect.X + $plan.Rect.W, $m.X + $m.W)
      $iy = [Math]::Max($plan.Rect.Y, $m.Y); $ay = [Math]::Min($plan.Rect.Y + $plan.Rect.H, $m.Y + $m.H)
      if ($ax -gt $ix -and $ay -gt $iy) { $plan.Notes += "$(Get-MonitorLabel $m) is not part of the layout but shows part of the window." }
    }
  }
  $plan.Ok = ($plan.Problems.Count -eq 0)
  return $plan
}

function Get-SimulatedTarget($Mons, $Settings) {
  # The target arrangement on paper: centre unchanged, first two side monitors placed left/right, vertically centred.
  $mons = @($Mons)
  $c = Resolve-CentreMonitor $mons $Settings
  if (-not $c) { throw 'no centre monitor' }
  $sides = @($mons | Where-Object { $_.Device -ne $c.Device -and (Test-MonitorMatch $_ $Settings.sideMatch) } | Sort-Object X)
  $out = @($c.PSObject.Copy())
  $i = 0
  foreach ($s in $sides) {
    $copy = $s.PSObject.Copy()
    if ($i -eq 0) { $t = Get-SideTarget $s $c 'left' } elseif ($i -eq 1) { $t = Get-SideTarget $s $c 'right' } else { break }
    $copy.X = $t.X; $copy.Y = $t.Y
    $out += $copy
    $i++
  }
  return $out
}

# ------------------------------------------------------------------ projection maths
# Assumption (not verified in-game): fov setting x 90 = horizontal degrees at the base aspect (16:9), and the
# vertical angle is kept for wider windows (Hor+). Evidence: gameoptions.lua (fov x 90, slider 60..120) and the
# HUD code that compensates only below 4:3 (compass.lua, widget_fullscreen.lua).

function Get-TanHalfV([double]$FovSetting, [double]$BaseAspect) {
  $deg = $FovSetting * 90.0
  return [Math]::Tan($deg / 2.0 * [Math]::PI / 180.0) / $BaseAspect
}

function Get-AngleDeg([double]$OffsetPx, [double]$HalfHeightPx, [double]$TanHalfV) {
  return [Math]::Atan($OffsetPx / $HalfHeightPx * $TanHalfV) * 180.0 / [Math]::PI
}

function Get-FovForSeat([double]$SeatMm, [double]$HalfHeightPx, [double]$PitchMm, [double]$BaseAspect) {
  # fov setting that makes the flat projection geometrically correct for an eye SeatMm in front of the centre monitor.
  $tv = ($HalfHeightPx * $PitchMm) / $SeatMm
  $deg = 2.0 * [Math]::Atan($tv * $BaseAspect) * 180.0 / [Math]::PI
  return $deg / 90.0
}

function Get-CockpitAnalysis {
  # Returns text lines: per-monitor coverage, angles, pixel scale, eye point, pixel cost, DLSS render sizes.
  param($Plan, $Mons, [double]$FovSetting, [double]$BaseAspect)
  $r = $Plan.Rect; $c = $Plan.Centre
  $lines = @()
  if (-not $r -or -not $c) { return $lines }
  $tv = Get-TanHalfV $FovSetting $BaseAspect
  $cx = $r.X + $r.W / 2.0; $hh = $r.H / 2.0
  $mp = [double]$r.W * $r.H
  $base = [double]$c.W * $c.H
  $lines += (Fmt 'window: x={0} y={1} {2}x{3} (aspect {4:0.000}:1), {5:0.00} MP = {6:0.00}x the centre monitor alone' $r.X $r.Y $r.W $r.H ($r.W / [double]$r.H) ($mp / 1e6) ($mp / $base))
  $lines += (Fmt 'crosshair (window centre) vs centre-monitor centre: dx={0} px, dy={1} px' ($cx - ($c.X + $c.W / 2.0)) (($r.Y + $hh) - ($c.Y + $c.H / 2.0)))
  $vdeg = 2 * [Math]::Atan($tv) * 180 / [Math]::PI
  $hdeg = 2 * (Get-AngleDeg ($r.W / 2.0) $hh $tv)
  $lines += (Fmt 'fov setting {0} ({1:0}deg slider value): vertical {2:0.0}deg, whole window horizontal {3:0.0}deg (assumes Hor+ with a {4:0.000}:1 base)' (ConvertTo-InvString $FovSetting) ($FovSetting * 90) $vdeg $hdeg $BaseAspect)
  $visible = 0.0
  foreach ($m in @($Mons) | Sort-Object X) {
    $ix = [Math]::Max($r.X, $m.X); $iy = [Math]::Max($r.Y, $m.Y)
    $ax = [Math]::Min($r.X + $r.W, $m.X + $m.W); $ay = [Math]::Min($r.Y + $r.H, $m.Y + $m.H)
    if ($ax -le $ix -or $ay -le $iy) { continue }
    $visible += [double]($ax - $ix) * ($ay - $iy)
    $a1 = Get-AngleDeg ($ix - $cx) $hh $tv; $a2 = Get-AngleDeg ($ax - $cx) $hh $tv
    $scale = 'n/a'
    if ($c.PitchMm -gt 0 -and $m.PitchMm -gt 0) { $scale = Fmt '{0:0.000}x' ($m.PitchMm / $c.PitchMm) }
    $lines += (Fmt '  {0}: window cols {1}..{2}, rows {3}..{4}; horizontal {5:0.0}deg..{6:0.0}deg ({7:0.0}deg wide); image scale vs centre {8}' (Get-MonitorLabel $m) ($ix - $r.X) ($ax - $r.X - 1) ($iy - $r.Y) ($ay - $r.Y - 1) $a1 $a2 ($a2 - $a1) $scale)
  }
  $lines += (Fmt 'rendered but not visible: {0:0.00} MP ({1:0}%)' (($mp - $visible) / 1e6) (100 * ($mp - $visible) / $mp))
  $edge = Get-AngleDeg ($r.W / 2.0) $hh $tv
  $cos = [Math]::Cos($edge * [Math]::PI / 180)
  $lines += (Fmt 'edge stretch of the flat projection: {0:0.0}x at {1:0.0}deg (correct only from the eye point below)' (1 / ($cos * $cos)) $edge)
  if ($c.PitchMm -gt 0) {
    $d = $hh * $c.PitchMm / $tv
    $lines += (Fmt 'eye point for an undistorted image: {0:0} mm in front of the centre monitor, level with its centre' $d)
    foreach ($s in @($Plan.Left, $Plan.Right)) {
      if (-not $s -or -not ($s.PitchMm -gt 0)) { continue }
      $k = $s.PitchMm / $c.PitchMm
      $where = 'left'; if ($s -eq $Plan.Right) { $where = 'right' }
      $t = Get-SideTarget $s $c $where
      $scx = $t.X + $s.W / 2.0 - $cx
      $lines += (Fmt '  {0} side: face forward (parallel to the centre monitor), screen {1:0} mm from the eye (= {2:0.000} x {3:0}), its centre {4:0} mm {5} of the eye axis, centre at eye height' $where ($d * $k) $k $d ([Math]::Abs($scx) * $c.PitchMm * $k) $where)
    }
  }
  $lines += 'DLSS internal render size (standard NVIDIA per-axis ratios; output is always the full window):'
  foreach ($q in @(@('quality', 0.6667), @('balanced', 0.58), @('performance', 0.5), @('ultra_performance', 0.3333))) {
    $f = [double]$q[1]
    $lines += (Fmt '  {0,-18} {1:0.00} MP  (centre monitor alone at quality: {2:0.00} MP)' $q[0] ($mp * $f * $f / 1e6) ($base * 0.6667 * 0.6667 / 1e6))
  }
  return $lines
}
