<#
x4cockpit3 automated tests. They never touch the real game, its window, its config or the companion:
  A  layout logic against synthetic monitor topologies (in-process, pure functions + the CLI with -MonitorsJson)
  B  the config switcher against COPIES of a config.xml in a temp folder, with a fake "X4.exe" process
  C  the real window-move code against an invisible dummy window this script creates and stops by PID
Usage: powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 [-WorkDir <dir>] [-SourceConfig <config.xml>] [-SkipWindow]
#>
[CmdletBinding()]
param([string]$WorkDir = '', [string]$SourceConfig = '', [switch]$SkipWindow)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Layout.ps1')
. (Join-Path $root 'lib\Config.ps1')
. (Join-Path $root 'lib\Native.ps1')

if (-not $WorkDir) { $WorkDir = Join-Path $here '_work' }
$run = Join-Path $WorkDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$script:pass = 0; $script:fail = 0; $script:skip = 0; $script:failed = @()
$script:started = @()   # PIDs this script started (stopped at the end, by PID only)

function Assert([bool]$Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass++; Write-Host "  PASS $Name" }
  else { $script:fail++; $script:failed += $Name; Write-Host "  FAIL $Name $Detail" }
}
function Skip([string]$Name, [string]$Why) { $script:skip++; Write-Host "  SKIP $Name ($Why)" }
function Invoke-Tool([string]$Script, [string[]]$ToolArgs) {
  $p = Join-Path $root $Script
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p @ToolArgs 2>&1 | Out-String
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function Hash([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function M($dev, $code, $name, $x, $y, $w, $h, $prim, $wmm, $hmm, $hz) {
  return [pscustomobject]@{ Device = "\\.\$dev"; Name = $name; Code = $code; Primary = $prim; X = $x; Y = $y; W = $w; H = $h; Hz = $hz
    WidthMm = $wmm; HeightMm = $hmm; PitchMm = [Math]::Round($wmm / [double]$w, 4) }
}
function UW([int]$x = 0, [int]$y = 0) { return (M 'DISPLAY2' 'AUS3438' 'VG34VQL3A' $x $y 3440 1440 $true 797 334 100) }
function Dell([string]$dev, [int]$x, [int]$y) { return (M $dev 'DELD05F' 'DELL P2714H' $x $y 1920 1080 $false 598 336 60) }
function Laptop([int]$x, [int]$y) { return (M 'DISPLAY1' 'NCP004D' '' $x $y 1920 1080 $false 344 194 144) }
function RectIs($r, $x, $y, $w, $h) { return ($r -and $r.X -eq $x -and $r.Y -eq $y -and $r.W -eq $w -and $r.H -eq $h) }
function Has($list, [string]$pattern) { return [bool](@($list | Where-Object { $_ -match $pattern }).Count) }

$S = Get-DefaultSettings
$S.sideMatch = 'DELD05F|P2714H'
$Sany = Get-DefaultSettings

try {
  # ================================================================== A: layout
  Write-Host '== A: layout logic (synthetic topologies)'
  $bothLeft = @((Dell 'DISPLAY1' -3840 126), (Dell 'DISPLAY3' -1920 126), (UW))
  $p = Get-CockpitPlan -Mons $bothLeft -Preset 'triple' -Settings $S
  Assert (-not $p.Ok) 'A1 both Dells left: triple does not match'
  Assert ($p.Left.Device -eq '\\.\DISPLAY3') 'A1 left = the Dell already touching the centre'
  Assert (Has $p.Problems 'RIGHT: DISPLAY1 .* x=3440, y=180') 'A1 tells to move DISPLAY1 right to x=3440 y=180' ($p.Problems -join ' | ')
  Assert (RectIs $p.Rect -1920 0 7280 1440) 'A1 triple rect (-1920,0) 7280x1440'
  $p = Get-CockpitPlan -Mons $bothLeft -Preset 'uw-left-only' -Settings $S
  Assert ($p.Ok) 'A2 both Dells left: uw-left-only matches' ($p.Problems -join ' | ')
  Assert (RectIs $p.Rect -1920 0 7280 1440) 'A2 uw-left-only rect (-1920,0) 7280x1440'
  Assert (Has $p.Notes '54 px higher') 'A2 reports the 54 px Y offset'
  $p = Get-CockpitPlan -Mons $bothLeft -Preset 'single' -Settings $S
  Assert (RectIs $p.Rect 0 0 3440 1440) 'A3 single rect = centre monitor'

  $target = @((Dell 'DISPLAY3' -1920 180), (UW), (Dell 'DISPLAY1' 3440 180))
  $p = Get-CockpitPlan -Mons $target -Preset 'triple' -Settings $S
  Assert ($p.Ok) 'A4 target arrangement: triple matches' ($p.Problems -join ' | ')
  Assert (RectIs $p.Rect -1920 0 7280 1440) 'A4 triple rect (-1920,0) 7280x1440'
  Assert ($p.Left.Device -eq '\\.\DISPLAY3' -and $p.Right.Device -eq '\\.\DISPLAY1') 'A4 left/right assignment'
  Assert ((@($p.Notes | Where-Object { $_ -match 'position OK' })).Count -eq 2) 'A4 both sides position OK'
  $p = Get-CockpitPlan -Mons $target -Preset 'uw-left-only' -Settings $S
  Assert ($p.Ok -and (Has $p.Notes 'triple')) 'A5 target: uw-left-only matches and points to triple'

  $swapped = @((Dell 'DISPLAY1' -1920 180), (UW), (Dell 'DISPLAY3' 3440 180))
  $p = Get-CockpitPlan -Mons $swapped -Preset 'triple' -Settings $S
  Assert ($p.Ok -and $p.Left.Device -eq '\\.\DISPLAY1' -and $p.Right.Device -eq '\\.\DISPLAY3') 'A6 swapped Dells: matches, sides follow the arrangement'

  $yoff = @((Dell 'DISPLAY3' -1920 0), (UW), (Dell 'DISPLAY1' 3440 360))
  $p = Get-CockpitPlan -Mons $yoff -Preset 'triple' -Settings $S
  Assert ($p.Ok -and (Has $p.Notes '180 px higher') -and (Has $p.Notes '180 px lower')) 'A7 top/bottom aligned sides: complete image, offsets reported' (($p.Problems + $p.Notes) -join ' | ')
  $p = Get-CockpitPlan -Mons @((Dell 'DISPLAY3' -1920 180), (UW), (Dell 'DISPLAY1' 3440 400)) -Preset 'triple' -Settings $S
  Assert ((-not $p.Ok) -and (Has $p.Problems '40 of its rows lie outside')) 'A8 side below the window: mismatch' ($p.Problems -join ' | ')
  $p = Get-CockpitPlan -Mons @((Dell 'DISPLAY3' -1920 -20), (UW), (Dell 'DISPLAY1' 3440 180)) -Preset 'triple' -Settings $S
  Assert (-not $p.Ok) 'A9 side above the window: mismatch'
  $p = Get-CockpitPlan -Mons @((Dell 'DISPLAY3' -1920 185), (UW), (Dell 'DISPLAY1' 3440 180)) -Preset 'triple' -Settings $S
  Assert ($p.Ok -and (Has $p.Notes 'position OK')) 'A10 5 px offset is within tolerance'

  $missing = @((Dell 'DISPLAY3' -1920 180), (UW))
  $p = Get-CockpitPlan -Mons $missing -Preset 'triple' -Settings $S
  Assert ((-not $p.Ok) -and (Has $p.Problems 'Only 1 side monitor')) 'A11 missing monitor: triple mismatch'
  $p = Get-CockpitPlan -Mons $missing -Preset 'uw-left-only' -Settings $S
  Assert ($p.Ok) 'A11 missing monitor: uw-left-only still matches'
  $p = Get-CockpitPlan -Mons @((UW), (Dell 'DISPLAY3' 3440 180)) -Preset 'uw-left-only' -Settings $S
  Assert (-not $p.Ok) 'A12 only a right side monitor: uw-left-only mismatch'

  $real = @((Laptop -3840 126), (Dell 'DISPLAY3' -1920 126), (UW))
  $p = Get-CockpitPlan -Mons $real -Preset 'triple' -Settings $S
  Assert ((-not $p.Ok) -and (Has $p.Problems 'NCP004D')) 'A13 laptop panel instead of a Dell: named as not a side monitor' ($p.Problems -join ' | ')
  $p = Get-CockpitPlan -Mons $real -Preset 'triple' -Settings $Sany
  Assert ((-not $p.Ok) -and (Has $p.Problems 'RIGHT: DISPLAY1')) 'A14 sideMatch empty: laptop panel is a candidate for the right side'

  $p = Get-CockpitPlan -Mons @((Dell 'DISPLAY3' -1920 180), (UW), (Dell 'DISPLAY1' 3500 180)) -Preset 'triple' -Settings $S
  Assert ((-not $p.Ok) -and (Has $p.Problems 'RIGHT: .* x=3440')) 'A15 gap between monitors: mismatch'

  $sim = @(Get-SimulatedTarget $bothLeft $S)
  $p = Get-CockpitPlan -Mons $sim -Preset 'triple' -Settings $S
  Assert ($p.Ok -and (RectIs $p.Rect -1920 0 7280 1440)) 'A16 simulated target from "both left" matches'

  $noPrim = @((M 'DISPLAY5' 'XXX0001' 'wide' 0 0 3440 1440 $false 797 334 100), (Dell 'DISPLAY3' -1920 180))
  $c = Resolve-CentreMonitor $noPrim $S
  Assert ($c.Device -eq '\\.\DISPLAY5') 'A17 no primary flag: widest aspect is the centre'

  $p = Get-CockpitPlan -Mons $target -Preset 'triple' -Settings $S
  $an = (Get-CockpitAnalysis -Plan $p -Mons $target -FovSetting 0.6667 -BaseAspect 1.7778) -join "`n"
  Assert ($an -match 'horizontal 117\.3deg') 'A18 fov 0.6667: whole window 117.3 deg'
  Assert ($an -match '\(20\.9deg wide\)' -and $an -match '\(75\.6deg wide\)') 'A18 per monitor: Dell 20.9 deg, UW 75.6 deg'
  Assert ($an -match '514 mm in front') 'A18 eye point 514 mm'
  Assert ($an -match '1\.344x') 'A18 Dell image scale 1.344x'
  Assert ($an -match '13%') 'A18 13% rendered but not visible'
  $fs = Get-FovForSeat 514 720 0.2317 1.7778
  Assert ([Math]::Abs($fs - 0.6667) -lt 0.002) 'A19 seat 514 mm -> fov 0.6667' "got $fs"

  # CLI with synthetic topologies (implies WhatIf - never moves a window)
  $tj = Join-Path $run 'topo-bothleft.json'; $bothLeft | ConvertTo-Json | Set-Content -LiteralPath $tj -Encoding UTF8
  $gj = Join-Path $run 'topo-target.json'; $target | ConvertTo-Json | Set-Content -LiteralPath $gj -Encoding UTF8

  # ================================================================== B: config switcher
  Write-Host '== B: config switcher (copies in a temp folder, fake X4 process)'
  if (-not $SourceConfig) {
    $f = Find-X4ProfileDir
    if ($f) { $SourceConfig = Join-Path $f.Dir 'config.xml' }
  }
  $prof = Join-Path $run 'profile\4242'
  New-Item -ItemType Directory -Force -Path $prof | Out-Null
  $cfg = Join-Path $prof 'config.xml'
  if ($SourceConfig -and (Test-Path -LiteralPath $SourceConfig)) {
    [IO.File]::WriteAllBytes($cfg, [IO.File]::ReadAllBytes($SourceConfig))   # read-only use of the source
    Write-Host "  (copy of $SourceConfig)"
  } else {
    Write-Host '  (no source config found - using a synthetic one)'
    [IO.File]::WriteAllText($cfg, "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<root>`r`n  <!-- graphic options -->`r`n  <fullscreen>true</fullscreen>`r`n  <borderless>false</borderless>`r`n  <fov>1.3333</fov>`r`n  <confinemouse>false</confinemouse>`r`n  <res_width>3440</res_width>`r`n  <res_height>1440</res_height>`r`n</root>`r`n")
  }
  # The source may already be in cockpit mode: normalise the copy to a typical non-cockpit state first.
  $c0 = Read-ConfigFile $cfg
  $pre = Get-ConfigEdit -Text $c0.Text -Values ([ordered]@{ fullscreen = 'false'; borderless = 'true'; res_width = '3440'; res_height = '1440'; fov = '1.3333'; confinemouse = 'false' })
  $t0 = $pre.NewText
  if (@(Find-ConfigElement $t0 'menuwidthscale').Count -eq 1) { $t0 = Remove-ElementLine $t0 'menuwidthscale' }
  if ($t0 -cne $c0.Text) { Write-ConfigFile $cfg $t0 $c0.Bom; Write-Host '  (copy normalised to a non-cockpit state)' }
  $orig = Hash $cfg
  $origBytes = [IO.File]::ReadAllBytes($cfg)

  # fake game: a tiny console exe named X4.exe that just sleeps (compiled here, started hidden, stopped by PID)
  $fakeDir = Join-Path $run 'fakegame'; New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
  $fakeExe = Join-Path $fakeDir 'X4.exe'
  Add-Type -OutputType ConsoleApplication -OutputAssembly $fakeExe -TypeDefinition 'public static class P { public static void Main(string[] a) { int s = 60; if (a.Length > 0) int.TryParse(a[0], out s); System.Threading.Thread.Sleep(s * 1000); } }'

  $bk = Join-Path $run 'backups'; $st = Join-Path $run 'state'; $flag = Join-Path $st 'cockpit-active.flag'
  $sf = Join-Path $run 'settings-test.json'
  ([ordered]@{ profileDir = $prof; gameExe = $fakeExe; backupDir = $bk; stateDir = $st; companionSkipFlag = $flag
      companionWindowTitle = 'x4cockpit3-test-no-such-window'; sideMatch = 'DELD05F|P2714H' } | ConvertTo-Json) | Set-Content -LiteralPath $sf -Encoding UTF8
  $stateFile = Join-Path $st 'cockpit-state.json'
  function BackupCount { if (Test-Path -LiteralPath $bk) { return @(Get-ChildItem -LiteralPath $bk -File).Count } else { return 0 } }

  $r = Invoke-Tool 'x4cockpit3.ps1' @('-Preset', 'triple', '-MonitorsJson', $tj, '-SettingsFile', $sf)
  Assert ($r.Code -eq 2 -and $r.Out -match 'DOES NOT MATCH') 'A20 CLI synthetic both-left: triple exit 2' $r.Out
  $r = Invoke-Tool 'x4cockpit3.ps1' @('-Preset', 'triple', '-MonitorsJson', $gj, '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and $r.Out -match 'ARRANGEMENT: OK' -and $r.Out -match 'WhatIf: nothing changed') 'A21 CLI synthetic target: triple OK, WhatIf implied' $r.Out

  $r = Invoke-Tool 'cockpit.ps1' @('status', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and $r.Out -match 'mode   : OFF' -and $r.Out -match 'not running') 'B1 status: OFF, fake game not running' $r.Out

  $r = Invoke-Tool 'cockpit.ps1' @('on', '-WhatIf', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and $r.Out -match 'WhatIf: nothing written') 'B2 on -WhatIf exit 0' $r.Out
  Assert ((Hash $cfg) -eq $orig -and (BackupCount) -eq 0 -and -not (Test-Path -LiteralPath $stateFile) -and -not (Test-Path -LiteralPath $flag)) 'B2 on -WhatIf changed nothing (file, backups, state, flag)'

  $r = Invoke-Tool 'cockpit.ps1' @('on', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0) 'B3 on exit 0' $r.Out
  $after = Read-ConfigFile $cfg
  $want = (Read-CockpitSettings -ToolRoot $root -SettingsFile $sf).cockpit
  Assert ((@(Test-ConfigValues $after.Text $want)).Count -eq 0) 'B3 all cockpit values present in the written file'
  $oldLines = (New-Object Text.UTF8Encoding($false)).GetString($origBytes) -split "`r?`n"
  $newLines = $after.Text -split "`r?`n"
  $keyRx = '<(' + (($want.Keys) -join '|') + ')[ />]'
  $foreign = @(Compare-Object $oldLines $newLines | Where-Object { $_.InputObject -notmatch $keyRx })
  Assert ($foreign.Count -eq 0) 'B3 no line other than the cockpit keys changed' (($foreign | ForEach-Object { $_.InputObject }) -join ' | ')
  Assert ((BackupCount) -eq 1) 'B3 one backup written'
  $b1 = @(Get-ChildItem -LiteralPath $bk -File)[0]
  Assert ((Hash $b1.FullName) -eq $orig -and $b1.Name -match '^config\.xml\.\d{8}-\d{6}\.before-cockpit-on$') 'B3 backup = original bytes, timestamped name' $b1.Name
  Assert ((Test-Path -LiteralPath $stateFile) -and (Test-Path -LiteralPath $flag)) 'B3 state file and companion flag created'
  $stateBefore = Get-Content -LiteralPath $stateFile -Raw

  $r = Invoke-Tool 'cockpit.ps1' @('on', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and $r.Out -match 'already ON' -and (Get-Content -LiteralPath $stateFile -Raw) -eq $stateBefore -and (BackupCount) -eq 1) 'B4 on twice: idempotent, originals kept, no extra backup' $r.Out

  $h = Hash $cfg
  $r = Invoke-Tool 'cockpit.ps1' @('off', '-WhatIf', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and (Hash $cfg) -eq $h -and (Test-Path -LiteralPath $stateFile)) 'B5 off -WhatIf changed nothing' $r.Out

  $r = Invoke-Tool 'cockpit.ps1' @('off', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0) 'B6 off exit 0' $r.Out
  Assert ((Hash $cfg) -eq $orig) 'B6 round trip on/off: byte-identical to the original'
  Assert (-not (Test-Path -LiteralPath $stateFile) -and -not (Test-Path -LiteralPath $flag)) 'B6 state and flag removed'
  Assert ((BackupCount) -eq 2) 'B6 second backup written, first one kept'

  $r = Invoke-Tool 'cockpit.ps1' @('off', '-SettingsFile', $sf)
  Assert ($r.Code -eq 2 -and $r.Out -match 'Nothing to restore' -and (Hash $cfg) -eq $orig) 'B7 off without state: refused, unchanged' $r.Out

  $fake = Start-Process -FilePath $fakeExe -ArgumentList '120' -WindowStyle Hidden -PassThru
  $script:started += $fake.Id
  Start-Sleep -Milliseconds 500
  $r = Invoke-Tool 'cockpit.ps1' @('on', '-SettingsFile', $sf)
  Assert ($r.Code -eq 2 -and $r.Out -match 'REFUSED: the game is running' -and (Hash $cfg) -eq $orig -and -not (Test-Path -LiteralPath $stateFile)) 'B8 on refused while fake X4 runs, nothing changed' $r.Out
  $r = Invoke-Tool 'cockpit.ps1' @('on', '-WhatIf', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and $r.Out -match 'a real run would be refused' -and (Hash $cfg) -eq $orig) 'B8 on -WhatIf allowed while it runs'
  $r = Invoke-Tool 'cockpit.ps1' @('off', '-SettingsFile', $sf)
  Assert ($r.Code -eq 2 -and $r.Out -match 'REFUSED: the game is running') 'B8 off refused while fake X4 runs' $r.Out
  Stop-Process -Id $fake.Id -ErrorAction SilentlyContinue
  $fake.WaitForExit(5000) | Out-Null

  # the game rewrites values between on and off -> off still restores the originals
  $r = Invoke-Tool 'cockpit.ps1' @('on', '-SettingsFile', $sf)
  $t = (Read-ConfigFile $cfg).Text.Replace('<res_width>7280</res_width>', '<res_width>3440</res_width>').Replace('<fov>0.6667</fov>', '<fov>0.9000</fov>')
  Write-ConfigFile $cfg $t $false
  $r = Invoke-Tool 'cockpit.ps1' @('off', '-SettingsFile', $sf)
  Assert ($r.Code -eq 0 -and (Hash $cfg) -eq $orig) 'B9 values changed by the game in between: off restores the original file' $r.Out

  # synthetic variant: LF line endings, BOM, a self-closing element, keys missing entirely
  $prof2 = Join-Path $run 'profile2\77'; New-Item -ItemType Directory -Force -Path $prof2 | Out-Null
  $cfg2 = Join-Path $prof2 'config.xml'
  $txt2 = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<root>`n`t<!-- options -->`n`t<fullscreen>true</fullscreen>`n`t<sounddevice/>`n`t<confinemouse/>`n</root>"
  [IO.File]::WriteAllBytes($cfg2, (ConvertTo-ConfigBytes $txt2 $true))
  $orig2 = Hash $cfg2
  $sf2 = Join-Path $run 'settings-test2.json'
  ([ordered]@{ profileDir = $prof2; gameExe = $fakeExe; backupDir = (Join-Path $run 'backups2'); stateDir = (Join-Path $run 'state2'); companionSkipFlag = 'none'; companionWindowTitle = 'x4cockpit3-test-no-such-window' } | ConvertTo-Json) | Set-Content -LiteralPath $sf2 -Encoding UTF8
  $r = Invoke-Tool 'cockpit.ps1' @('on', '-SettingsFile', $sf2)
  $a2 = Read-ConfigFile $cfg2
  Assert ($r.Code -eq 0 -and $a2.Bom -and -not $a2.Text.Contains("`r`n") -and $a2.Text -match "`t<menuwidthscale>0\.47</menuwidthscale>`n</root>" -and $a2.Text -match '<confinemouse>true</confinemouse>') 'B10 BOM, LF, tab indent and self-closing element handled' $r.Out
  $r = Invoke-Tool 'cockpit.ps1' @('off', '-SettingsFile', $sf2)
  Assert ($r.Code -eq 0 -and (Hash $cfg2) -eq $orig2) 'B10 round trip byte-identical (no final newline, BOM kept)' $r.Out

  $dup = "<?xml version=`"1.0`"?>`r`n<root>`r`n  <fov>1.0</fov>`r`n  <fov>1.2</fov>`r`n</root>`r`n"
  [IO.File]::WriteAllText($cfg2, $dup)
  $hd = Hash $cfg2
  $r = Invoke-Tool 'cockpit.ps1' @('on', '-SettingsFile', $sf2)
  Assert ($r.Code -eq 1 -and $r.Out -match '2 times' -and (Hash $cfg2) -eq $hd) 'B11 duplicated key: refused, unchanged' $r.Out

  $docs = Join-Path $run 'docs'
  foreach ($n in '111', '222', 'save', '333') { New-Item -ItemType Directory -Force -Path (Join-Path $docs $n) | Out-Null }
  foreach ($n in '111', '222', 'save') { Set-Content -LiteralPath (Join-Path $docs "$n\config.xml") -Value '<root/>' }
  (Get-Item -LiteralPath (Join-Path $docs '111\config.xml')).LastWriteTime = (Get-Date).AddDays(-2)
  (Get-Item -LiteralPath (Join-Path $docs '222\config.xml')).LastWriteTime = (Get-Date).AddDays(-1)
  (Get-Item -LiteralPath (Join-Path $docs 'save\config.xml')).LastWriteTime = (Get-Date)
  $f = Find-X4ProfileDir -BaseDir $docs
  Assert ($f -and (Split-Path -Leaf $f.Dir) -eq '222' -and $f.Candidates.Count -eq 2) 'B12 profile auto-detect: newest numeric folder with a config.xml'

  $bad = Join-Path $run 'settings-bad.json'
  '{ "cockpit": { "dlssmode": "performance" } }' | Set-Content -LiteralPath $bad -Encoding UTF8
  $ok = $false; try { Read-CockpitSettings -ToolRoot $root -SettingsFile $bad | Out-Null } catch { $ok = $_.Exception.Message -match 'not allowed' }
  Assert $ok 'B13 settings: a key outside the allowed set is rejected'
  '{ "cockpit": { "fov": "2.5" } }' | Set-Content -LiteralPath $bad -Encoding UTF8
  $ok = $false; try { Read-CockpitSettings -ToolRoot $root -SettingsFile $bad | Out-Null } catch { $ok = $_.Exception.Message -match 'outside' }
  Assert $ok 'B13 settings: fov out of range is rejected'

  # ================================================================== C: real window code on a dummy window
  Write-Host '== C: window code on an invisible dummy window'
  if ($SkipWindow) { Skip 'C*' '-SkipWindow' }
  else {
    $hf = Join-Path $run 'dummy.hwnd'
    $dp = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $here 'dummywin.ps1')`"", '-HandleFile', "`"$hf`"", '-Seconds', '90') -WindowStyle Hidden -PassThru
    $script:started += $dp.Id
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $hf) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $hf)) { Assert $false 'C0 dummy window started' }
    else {
      $hs = (Get-Content -LiteralPath $hf -Raw).Trim()
      $hw = ConvertTo-Hwnd $hs
      $w0 = Get-WinInfo $hw
      Assert ($w0.W -gt 0) "C0 dummy window $hs started (pid $($dp.Id))"
      $live = @(Get-LiveMonitors)
      $common = @('-Handle', $hs, '-NoActivate', '-ZBottom', '-SettingsFile', $sf)

      foreach ($pre in 'uw-left-only', 'single') {
        $pl = Get-CockpitPlan -Mons $live -Preset $pre -Settings (Read-CockpitSettings -ToolRoot $root -SettingsFile $sf)
        $r = Invoke-Tool 'x4cockpit3.ps1' (@('-Preset', $pre) + $common)
        if ($pl.Ok) {
          $w = Get-WinInfo $hw
          Assert ($r.Code -eq 0 -and $w.ClientX -eq $pl.Rect.X -and $w.ClientY -eq $pl.Rect.Y -and $w.ClientW -eq $pl.Rect.W -and $w.ClientH -eq $pl.Rect.H) "C1 $pre on the live topology: client exactly ($($pl.Rect.X),$($pl.Rect.Y)) $($pl.Rect.W)x$($pl.Rect.H)" $r.Out
          $r = Invoke-Tool 'x4cockpit3.ps1' @('-Restore', '-Handle', $hs, '-NoActivate', '-SettingsFile', $sf)
          $w = Get-WinInfo $hw
          Assert ($r.Code -eq 0 -and $w.X -eq $w0.X -and $w.Y -eq $w0.Y -and $w.W -eq $w0.W -and $w.H -eq $w0.H -and $w.Style -eq $w0.Style) "C2 $pre -Restore: original rect and style back" $r.Out
        } else {
          Assert ($r.Code -eq 2) "C1 $pre live arrangement does not match: refused" $r.Out
        }
      }

      $vx = ($live | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum; $vy = ($live | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
      $vw = ($live | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum - $vx
      $vh = ($live | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum - $vy
      $area = "$vx,$vy,$($vw + 1322),$($vh + 10)"
      $r = Invoke-Tool 'x4cockpit3.ps1' (@('-Preset', 'custom', '-Area', $area) + $common)
      $w = Get-WinInfo $hw
      Assert ($r.Code -eq 0 -and $w.ClientW -eq ($vw + 1322) -and $w.ClientH -eq ($vh + 10) -and (($w.Style -band 0x80000000) -ne 0)) "C3 custom larger than the desktop ($area): exact, WS_POPUP added" $r.Out
      $r = Invoke-Tool 'x4cockpit3.ps1' @('-Restore', '-Handle', $hs, '-NoActivate', '-SettingsFile', $sf)
      $w = Get-WinInfo $hw
      Assert ($r.Code -eq 0 -and $w.Style -eq $w0.Style -and $w.W -eq $w0.W) 'C3 -Restore after custom'

      $pl = Get-CockpitPlan -Mons $live -Preset 'triple' -Settings (Read-CockpitSettings -ToolRoot $root -SettingsFile $sf)
      $r = Invoke-Tool 'x4cockpit3.ps1' (@('-Preset', 'triple') + $common)
      $w = Get-WinInfo $hw
      if ($pl.Ok) {
        Assert ($r.Code -eq 0 -and $w.ClientW -eq $pl.Rect.W) 'C4 triple on the live topology: applied' $r.Out
        Invoke-Tool 'x4cockpit3.ps1' @('-Restore', '-Handle', $hs, '-NoActivate', '-SettingsFile', $sf) | Out-Null
      } else {
        Assert ($r.Code -eq 2 -and $r.Out -match 'REFUSED' -and $w.X -eq $w0.X -and $w.W -eq $w0.W) 'C4 triple over the mismatching live arrangement: refused, window untouched' $r.Out
      }

      # without -Handle the tool may only pick the configured exe (the fake one, not running) - never the real game
      $pre = @(Get-GameProcesses $fakeExe -RequirePathMatch)
      if ($pre.Count -eq 0) {
        $r = Invoke-Tool 'x4cockpit3.ps1' @('-Preset', 'single', '-NoActivate', '-SettingsFile', $sf)
        Assert ($r.Code -eq 1 -and $r.Out -match 'no running game window found') 'C5 no -Handle: only the configured exe is eligible (real game ignored)' $r.Out
      } else { Skip 'C5' 'a process matches the fake exe path' }

      $r = Invoke-Tool 'diag\x4winprobe.ps1' @('-Experiments', '-Handle', $hs, '-SettingsFile', $sf, '-LogDir', (Join-Path $run 'probe'))
      $w = Get-WinInfo $hw
      Assert ($r.Code -eq 0 -and $r.Out -match 'E4 SetWindowPos target rect -> returned True, call took \d+ ms, CHANGED' -and $w.X -eq $w0.X -and $w.W -eq $w0.W -and $w.Style -eq $w0.Style) 'C6 probe on a cooperative window: E4 changes it, original state put back' $r.Out
    }

    # a window that enforces its own rectangle/style, like X4 9.00 did in the live test
    $hf2 = Join-Path $run 'dummy-enforce.hwnd'
    $dp2 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $here 'dummywin.ps1')`"", '-HandleFile', "`"$hf2`"", '-Seconds', '90', '-Enforce') -WindowStyle Hidden -PassThru
    $script:started += $dp2.Id
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $hf2) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $hf2)) { Assert $false 'C7 enforcing dummy window started' }
    else {
      $hs2 = (Get-Content -LiteralPath $hf2 -Raw).Trim(); $hw2 = ConvertTo-Hwnd $hs2; $e0 = Get-WinInfo $hw2
      $r = Invoke-Tool 'x4cockpit3.ps1' @('-Preset', 'single', '-Handle', $hs2, '-NoActivate', '-ZBottom', '-SettingsFile', $sf)
      $w = Get-WinInfo $hw2
      Assert ($r.Code -eq 3 -and $r.Out -match 'REFUSED BY THE APPLICATION' -and $r.Out -notmatch 'Applied' -and $w.X -eq $e0.X -and $w.W -eq $e0.W -and $w.Style -eq $e0.Style) 'C7 window that keeps its own rect: reported as REFUSED, exit 3' $r.Out
      Assert (-not (Test-Path -LiteralPath (Get-WindowStatePath $st $hw2))) 'C7 no stale restore state left behind'
      $r = Invoke-Tool 'diag\x4winprobe.ps1' @('-Experiments', '-Handle', $hs2, '-SettingsFile', $sf, '-LogDir', (Join-Path $run 'probe'))
      Assert ($r.Code -eq 0 -and $r.Out -match 'E4 SetWindowPos target rect -> returned True, call took \d+ ms, UNCHANGED' -and $r.Out -match 'E8 SetWindowLongPtr[^\n]*UNCHANGED') 'C8 probe on the enforcing window: moves and style change reported UNCHANGED' $r.Out
    }
  }
} catch {
  $script:fail++; $script:failed += "unexpected error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
  Write-Host "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
} finally {
  foreach ($id in $script:started) { Stop-Process -Id $id -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed, {2} skipped   (work dir: {3})" -f $script:pass, $script:fail, $script:skip, $run)
foreach ($f in $script:failed) { Write-Host "  failed: $f" }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
