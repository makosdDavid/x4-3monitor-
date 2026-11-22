<#
x4cockpit3 native tests - the launcher, the hook DLL and cockpit-launch against testtarget.exe (an imitation of
X4's window behaviour). Never touches X4.exe, the user's game config/profile or display settings.
Windows created here are fully transparent (alpha 0), click-through, never activated and at the bottom of the
z-order (testtarget --hidden), live a few seconds, and every process this script starts is stopped by PID.

  N  build, import audit, the target without the hook (reproduces the clamp), with the hook (small rectangle and
     the real 7280x1440 rectangle), the watchdog alone, an X4.exe-named copy
  F  failure paths: missing DLL, wrong exe name, relative/missing exe, invalid rectangle (launcher and DLL),
     simulated hook-install failure (with IAT rollback check), simulated injection failure, wrong process,
     unknown option, already running
  L  log written and size-capped
  C  cockpit-launch: arrangement check, cockpit-mode check, -Rect, game running, detached start via WMI

Usage: powershell -ExecutionPolicy Bypass -File native\tests\run-native-tests.ps1 [-WorkDir <dir>] [-SkipBuild] [-Visible]
  -Visible  additionally shows ONE small (640x360) visible hooked window for a few seconds.
#>
[CmdletBinding()]
param([string]$WorkDir = '', [switch]$SkipBuild, [switch]$Visible)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$native = Split-Path -Parent $here
$root = Split-Path -Parent $native
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Layout.ps1')
. (Join-Path $root 'lib\Config.ps1')
. (Join-Path $root 'lib\Native.ps1')

if (-not ('X4C3Test.W' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace X4C3Test {
  public static class W {
    [StructLayout(LayoutKind.Sequential)] struct R { public int L, T, Rt, B; }
    [StructLayout(LayoutKind.Sequential)] struct MI { public int cb; public R mon, work; public uint flags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr m, ref MI mi);
    // work area of the monitor the window is on: x, y, w, h
    public static int[] Work(IntPtr h) { var mi = new MI(); mi.cb = Marshal.SizeOf(typeof(MI));
      GetMonitorInfoW(MonitorFromWindow(h, 2), ref mi);
      return new int[] { mi.work.L, mi.work.T, mi.work.Rt - mi.work.L, mi.work.B - mi.work.T, mi.mon.L, mi.mon.T, mi.mon.Rt, mi.mon.B }; }
  }
}
'@
}

$out = Join-Path $native 'out'
$launcher = Join-Path $out 'launcher.exe'; $dll = Join-Path $out 'x4c3hook.dll'; $target = Join-Path $out 'testtarget.exe'
if (-not $WorkDir) { $WorkDir = Join-Path $here '_work' }
$run = Join-Path $WorkDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$script:pass = 0; $script:fail = 0; $script:skip = 0; $script:failed = @(); $script:started = @()
$WS_CAPTION = [int64]0x00C00000; $WS_THICKFRAME = [int64]0x00040000; $WS_POPUP = [int64]2147483648
$SWP = 0x0004 -bor 0x0010   # NOZORDER | NOACTIVATE

function Assert([bool]$Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass++; Write-Host "  PASS $Name" }
  else { $script:fail++; $script:failed += $Name; Write-Host "  FAIL $Name"; if ($Detail) { Write-Host ('       ' + ($Detail -replace "`n", "`n       ")) } }
}
function Skip([string]$Name, [string]$Why) { $script:skip++; Write-Host "  SKIP $Name ($Why)" }
function Q([string]$s) { return '"' + $s + '"' }
function ReadText([string]$p) {
  # the writer (target / DLL / launcher) still has the file open for appending: share read+write
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

function Stop-Mine {
  foreach ($id in $script:started) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and @('testtarget', 'X4', 'launcher', 'notx4') -contains $p.ProcessName) { Stop-Process -Id $id -ErrorAction SilentlyContinue; $p.WaitForExit(5000) | Out-Null }
  }
  $script:started = @()
}

# Waits until a target log shows the window, returns pid/hwnd (and remembers the pid for cleanup).
function Wait-Target([string]$Log, [int]$Seconds = 10) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $t = ReadText $Log
    if ($t -match 'pid=(\d+)' -and $t -match 'created hwnd=0x([0-9a-f]+)' -and $t -match 'tick=0') {
      $tp = [int]([regex]::Match($t, 'pid=(\d+)').Groups[1].Value)
      $script:started += $tp
      return [pscustomobject]@{ Pid = $tp; Hwnd = [IntPtr]([Convert]::ToInt64([regex]::Match($t, 'created hwnd=0x([0-9a-f]+)').Groups[1].Value, 16)) }
    }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

function Invoke-Launch([string]$Name, [string[]]$LArgs, [string[]]$TArgs, [string]$Exe = $target, [switch]$NoTestFlag, [switch]$Shown) {
  $d = Join-Path $run $Name; New-Item -ItemType Directory -Force -Path $d | Out-Null
  $tlog = Join-Path $d 'target.log'
  $a = @()
  if (-not $NoTestFlag) { $a += '--test-target' }
  if ($Exe) { $a += @('--exe', (Q $Exe)) }
  $a += $LArgs + @('--log-dir', (Q $d), '--watch-exit-ms', '0', '--')
  if (-not $Shown) { $a += '--hidden' }
  $a += $TArgs + @('--log', (Q $tlog))
  $p = Start-Process -FilePath $launcher -ArgumentList $a -PassThru -WindowStyle Hidden
  $script:started += $p.Id
  if (-not $p.WaitForExit(40000)) { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue }
  $code = $p.ExitCode
  $t = $null
  if ($code -eq 0 -or $code -eq 3) { $t = Wait-Target $tlog }
  return [pscustomobject]@{ Code = $code; Dir = $d; TLog = $tlog; Target = $t
    LLog = (Join-Path $d 'launcher.log'); HLog = (Join-Path $d 'x4c3hook.log') }
}

function Start-Plain([string]$Name, [string]$Exe = $target, [int]$Seconds = 8) {
  $d = Join-Path $run $Name; New-Item -ItemType Directory -Force -Path $d | Out-Null
  $tlog = Join-Path $d 'target.log'
  $p = Start-Process -FilePath $Exe -ArgumentList @('--hidden', '--seconds', "$Seconds", '--log', (Q $tlog)) -PassThru
  $script:started += $p.Id
  return [pscustomobject]@{ Proc = $p; TLog = $tlog; Target = (Wait-Target $tlog) }
}

function LastTick([string]$Log) {
  $l = @((ReadText $Log) -split "`r?`n" | Where-Object { $_ -match 'tick=\d+' }) | Select-Object -Last 1
  $h = @{}
  foreach ($m in [regex]::Matches("$l", '(\w+)=([^ ]+)')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
  return $h
}
function IsExact($i, [int]$x, [int]$y, [int]$w, [int]$h) {
  return ($i.X -eq $x -and $i.Y -eq $y -and $i.W -eq $w -and $i.H -eq $h -and $i.ClientX -eq $x -and $i.ClientY -eq $y -and $i.ClientW -eq $w -and $i.ClientH -eq $h)
}
function IsBorderless($i) { return ((($i.Style -band $WS_CAPTION) -eq 0) -and (($i.Style -band $WS_THICKFRAME) -eq 0) -and (($i.Style -band $WS_POPUP) -ne 0)) }
function IsFramedAtWork($t) {
  # the X4 behaviour without hook: caption + frame, window rectangle = work area of its monitor
  if (-not $t) { return $false }
  $i = Get-WinInfo $t.Hwnd; $wa = [X4C3Test.W]::Work($t.Hwnd)
  return ((($i.Style -band $WS_CAPTION) -eq $WS_CAPTION) -and $i.X -eq $wa[0] -and $i.Y -eq $wa[1] -and $i.W -eq $wa[2] -and $i.H -eq $wa[3])
}
function Fmt-Info($i) { return (Fmt 'window ({0},{1}) {2}x{3} client ({4},{5}) {6}x{7} style 0x{8:X}' $i.X $i.Y $i.W $i.H $i.ClientX $i.ClientY $i.ClientW $i.ClientH $i.Style) }

try {
  # ================================================================== N1 build
  Write-Host '== N1: build'
  if ($SkipBuild) { Skip 'N1 build' '-SkipBuild' }
  else {
    $b = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $native 'build.ps1') 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $b -match 'BUILD OK') 'N1 build.ps1 exit 0' $b
  }
  Assert ((Test-Path $launcher) -and (Test-Path $dll) -and (Test-Path $target)) 'N1 launcher.exe, x4c3hook.dll, testtarget.exe exist'

  # ================================================================== N2 import audit
  Write-Host '== N2: import audit (peimports.py)'
  $py = Get-Command python.exe -ErrorAction SilentlyContinue
  if (-not $py) { Skip 'N2' 'python not found' }
  else {
    $imp = @{}
    foreach ($f in $launcher, $dll, $target) { $imp[$f] = (& $py.Source -I (Join-Path $native 'peimports.py') $f 2>&1 | Out-String) }
    $badRx = '(?im)^(WS2_32|WSOCK32|WININET|WINHTTP|URLMON|ADVAPI32|SHELL32|OLE32)\.dll'
    foreach ($f in $launcher, $dll, $target) { Assert ($imp[$f] -notmatch $badRx) "N2 $([IO.Path]::GetFileName($f)): no network/registry/shell DLL imported" }
    Assert ($imp[$dll] -notmatch '(?m)^\s+(Reg\w+|CreateService\w*|InternetOpen\w*|WSAStartup)\s*$') 'N2 DLL: no registry/service/network function'
    $need = 'RegisterClassExW', 'CreateWindowExW', 'SetWindowPos', 'SetWindowLongPtrW', 'ShowWindow', 'AdjustWindowRect', 'GetMonitorInfoW', 'MonitorFromWindow', 'MonitorFromRect', 'GetSystemMetrics', 'SystemParametersInfoW', 'EnumDisplaySettingsW', 'ChangeDisplaySettingsExW'
    $miss = @($need | Where-Object { $imp[$target] -notmatch "(?m)^\s+$_\s*$" })
    Assert ($miss.Count -eq 0) 'N2 testtarget imports the X4 window/monitor functions it imitates' "missing: $($miss -join ', ')"
    Assert ($imp[$target] -match 'dpiAware = True/PM') 'N2 testtarget declares the same DPI awareness as X4.exe (True/PM)'
  }

  # ================================================================== N3 plain target
  Write-Host '== N3: target WITHOUT the hook (must reproduce the X4 clamp)'
  $pl = Start-Plain 'n3-plain'
  if (-not $pl.Target) { Assert $false 'N3 target started' (ReadText $pl.TLog) }
  else {
    $i = Get-WinInfo $pl.Target.Hwnd; $wa = [X4C3Test.W]::Work($pl.Target.Hwnd)
    Assert ((($i.Style -band $WS_CAPTION) -eq $WS_CAPTION) -and (($i.Style -band $WS_THICKFRAME) -ne 0)) 'N3 framed window (caption + sizing frame)' (Fmt-Info $i)
    Assert ($i.X -eq $wa[0] -and $i.Y -eq $wa[1] -and $i.W -eq $wa[2] -and $i.H -eq $wa[3]) "N3 window = work area of its monitor ($($wa[0]),$($wa[1]) $($wa[2])x$($wa[3]))" (Fmt-Info $i)
    Assert ($i.ClientW -lt $i.W -and $i.ClientH -lt $i.H) "N3 client $($i.ClientW)x$($i.ClientH) smaller than the window (frame)"
    $tk = LastTick $pl.TLog
    Assert ($tk['work'] -eq ('{0},{1},{2},{3}' -f $wa[0], $wa[1], ($wa[0] + $wa[2]), ($wa[1] + $wa[3])) -and $tk['mon'] -eq ('{0},{1},{2},{3}' -f $wa[4], $wa[5], $wa[6], $wa[7])) 'N3 target sees the real monitor and work area' "$($tk['mon']) / $($tk['work'])"
    [void][X4Cockpit3.Native]::SetWindowPos($pl.Target.Hwnd, [IntPtr]::Zero, $wa[0] + 50, $wa[1] + 50, 400, 300, $SWP)
    Start-Sleep -Milliseconds 1500
    $i2 = Get-WinInfo $pl.Target.Hwnd
    Assert ($i2.X -eq $wa[0] -and $i2.W -eq $wa[2] -and $i2.H -eq $wa[3]) 'N3 external SetWindowPos is refused (target puts its rectangle back)' (Fmt-Info $i2)
  }
  Stop-Mine

  # ================================================================== N4 hooked, small rectangle
  Write-Host '== N4: through the launcher, small rectangle 64,64 640x360'
  $r = Invoke-Launch 'n4-small' @('--rect', '64,64,640,360') @('--seconds', '12', '--try-cds')
  Assert ($r.Code -eq 0 -and (ReadText $r.LLog) -match 'hook=ACTIVE') 'N4 launcher exit 0, hook ACTIVE' (ReadText $r.LLog)
  if ($r.Target) {
    $hl = ReadText $r.HLog
    Assert ($hl -match 'window created as borderless popup at the rectangle: hwnd=\S+ window=\(64,64\) 640x360 client=640x360') 'N4 hook log: window created at the rectangle' $hl
    $i = Get-WinInfo $r.Target.Hwnd
    Assert (IsBorderless $i) 'N4 borderless popup style' (Fmt-Info $i)
    Assert (IsExact $i 64 64 640 360) 'N4 window = client = (64,64) 640x360' (Fmt-Info $i)
    $tk = LastTick $r.TLog
    Assert ($tk['mon'] -eq '64,64,704,424' -and $tk['work'] -eq '64,64,704,424' -and $tk['spiwork'] -eq '64,64,704,424') 'N4 target: GetMonitorInfoW rcMonitor/rcWork and SPI_GETWORKAREA = the rectangle' "$($tk['mon']) $($tk['work']) $($tk['spiwork'])"
    Assert ($tk['cx'] -eq '640' -and $tk['cy'] -eq '360' -and $tk['adj'] -eq '100,100,500,400' -and $tk['mode'] -eq '640x360@64,64' -and $tk['mfr_eq_mfw'] -eq '1') 'N4 target: GetSystemMetrics, AdjustWindowRect, EnumDisplaySettings, MonitorFromRect consistent' (($tk.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    Assert ((ReadText $r.TLog) -match 'cds: hooked ChangeDisplaySettingsExW\(CDS_TEST\) returned 0' -and $hl -match 'ChangeDisplaySettingsExW\(.*\) blocked') 'N4 ChangeDisplaySettingsExW is blocked (never forwarded)'
    [void][X4Cockpit3.Native]::SetWindowPos($r.Target.Hwnd, [IntPtr]::Zero, 100, 100, 300, 200, $SWP)
    Start-Sleep -Milliseconds 1500
    $i = Get-WinInfo $r.Target.Hwnd
    Assert (IsExact $i 64 64 640 360) 'N4 external SetWindowPos: rectangle kept' (Fmt-Info $i)
    $st = [int64](Get-WinInfo $r.Target.Hwnd).Style
    [void][X4Cockpit3.Native]::SetWindowLongPtrW($r.Target.Hwnd, -16, [IntPtr](($st -bor $WS_CAPTION -bor $WS_THICKFRAME) -band (-bnot $WS_POPUP)))
    [void][X4Cockpit3.Native]::SetWindowPos($r.Target.Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor $SWP -bor 0x0020)
    Start-Sleep -Milliseconds 1500
    $i = Get-WinInfo $r.Target.Hwnd
    Assert ((IsBorderless $i) -and (IsExact $i 64 64 640 360)) 'N4 external frame style added: borderless rectangle restored' (Fmt-Info $i)
    Start-Sleep -Milliseconds 1200
    $tk = LastTick $r.TLog
    Assert ($tk['client'] -eq '640x360' -and [int]$tk['reapplies'] -ge 3 -and [int]$tk['stylefix'] -ge 1) "N4 target's own re-apply timer: still 640x360 after $($tk['reapplies']) re-applies / $($tk['stylefix']) frame re-asserts" (($tk.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    $hl = ReadText $r.HLog
    Assert ($hl -match 'SetWindowPos by the game: .* rewritten' -and $hl -match 'kept borderless') "N4 hook log: the target's own SetWindowPos/SetWindowLongPtrW were rewritten"
  } else { Assert $false 'N4 target window appeared' (ReadText $r.TLog) }
  Stop-Mine

  # ================================================================== N5 hooked, the real rectangle (invisible)
  Write-Host '== N5: through the launcher, the real rectangle -1920,0 7280x1440 (invisible window)'
  $r = Invoke-Launch 'n5-real' @('--rect', '-1920,0,7280,1440') @('--seconds', '8')
  Assert ($r.Code -eq 0) 'N5 launcher exit 0' (ReadText $r.LLog)
  if ($r.Target) {
    $i = Get-WinInfo $r.Target.Hwnd
    Assert ((IsBorderless $i) -and (IsExact $i -1920 0 7280 1440)) 'N5 borderless, window = client = (-1920,0) 7280x1440' (Fmt-Info $i)
    $tk = LastTick $r.TLog
    Assert ($tk['client'] -eq '7280x1440' -and $tk['mon'] -eq '-1920,0,5360,1440' -and $tk['work'] -eq '-1920,0,5360,1440' -and $tk['cx'] -eq '7280' -and $tk['cy'] -eq '1440') 'N5 target reports client 7280x1440 and a 7280x1440 monitor/work area' (($tk.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    Assert ([int]$tk['vx'] -le -1920 -and ([int]$tk['vx'] + [int]$tk['vcx']) -ge 5360) 'N5 virtual-screen metrics contain the rectangle'
    [void][X4Cockpit3.Native]::SetWindowPos($r.Target.Hwnd, [IntPtr]::Zero, 0, 0, 3440, 1392, $SWP)
    Start-Sleep -Milliseconds 1500
    $i = Get-WinInfo $r.Target.Hwnd
    Assert (IsExact $i -1920 0 7280 1440) 'N5 external SetWindowPos to the work-area size: rectangle kept' (Fmt-Info $i)
  } else { Assert $false 'N5 target window appeared' (ReadText $r.TLog) }
  Stop-Mine

  # ================================================================== N6 watchdog alone
  Write-Host '== N6: the watchdog alone (no wndproc wrapper, target does not defend itself)'
  $r = Invoke-Launch 'n6-watchdog' @('--rect', '96,96,512,288', '--opts', 'nowndproc') @('--seconds', '8', '--no-reapply')
  if ($r.Target) {
    $i = Get-WinInfo $r.Target.Hwnd
    Assert (IsExact $i 96 96 512 288) 'N6 created at the rectangle' (Fmt-Info $i)
    [void][X4Cockpit3.Native]::SetWindowPos($r.Target.Hwnd, [IntPtr]::Zero, 200, 200, 300, 200, $SWP)
    $now = Get-WinInfo $r.Target.Hwnd
    Assert ($now.X -eq 200 -and $now.W -eq 300) 'N6 external SetWindowPos takes effect at first (no other layer active)' (Fmt-Info $now)
    Start-Sleep -Milliseconds 1500
    $i = Get-WinInfo $r.Target.Hwnd
    Assert ((IsExact $i 96 96 512 288) -and (ReadText $r.HLog) -match 'watchdog #1:') 'N6 watchdog put the rectangle back within 1.5 s' (Fmt-Info $i)
  } else { Assert $false 'N6 target window appeared' (ReadText $r.TLog) }
  Stop-Mine

  # ================================================================== N7 an exe named X4.exe (no test flag)
  Write-Host '== N7: a copy of the target named X4.exe, launcher without --test-target'
  $x4dir = Join-Path $run 'x4copy'; New-Item -ItemType Directory -Force -Path $x4dir | Out-Null
  $x4copy = Join-Path $x4dir 'X4.exe'; Copy-Item -LiteralPath $target -Destination $x4copy
  $r = Invoke-Launch 'n7-x4name' @('--rect', '64,64,640,360') @('--seconds', '6', '-debug', 'all', '-logfile', 'debug.log') -Exe $x4copy -NoTestFlag
  Assert ($r.Code -eq 0 -and (ReadText $r.HLog) -match 'loaded into .*\\X4\.exe') 'N7 accepted, DLL active in X4.exe' (ReadText $r.LLog)
  if ($r.Target) {
    Assert (IsExact (Get-WinInfo $r.Target.Hwnd) 64 64 640 360) 'N7 window at the rectangle'
    Assert ((ReadText $r.TLog) -match 'cmdline=.*X4\.exe" --hidden --seconds 6 -debug all -logfile debug\.log --log') 'N7 game arguments passed through verbatim' (ReadText $r.TLog)
  } else { Assert $false 'N7 target window appeared' }
  Stop-Mine

  # ================================================================== F failure paths
  Write-Host '== F: failure paths'
  $r = Invoke-Launch 'f1-nodll' @('--rect', '64,64,640,360', '--dll', (Q (Join-Path $run 'no-such.dll'))) @('--seconds', '6')
  Assert ($r.Code -eq 3 -and (ReadText $r.LLog) -match 'hook DLL not found' -and (IsFramedAtWork $r.Target)) 'F1 missing DLL: game started normally (framed, work area), exit 3' (ReadText $r.LLog)
  Stop-Mine

  $nx = Join-Path $run 'notx4.exe'; Copy-Item -LiteralPath $target -Destination $nx
  $r = Invoke-Launch 'f2-wrongname' @('--rect', '64,64,640,360') @('--seconds', '4') -Exe $nx -NoTestFlag
  Start-Sleep -Milliseconds 800
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'REFUSED: the exe must be named X4\.exe' -and -not (Get-Process -Name 'notx4' -ErrorAction SilentlyContinue)) 'F2 wrong exe name: refused, nothing started' (ReadText $r.LLog)
  $r = Invoke-Launch 'f2b-wrongname-testflag' @('--rect', '64,64,640,360') @('--seconds', '4') -Exe $nx
  Assert ($r.Code -eq 2 -and -not (Get-Process -Name 'notx4' -ErrorAction SilentlyContinue)) 'F2 wrong exe name with --test-target: refused'
  $r = Invoke-Launch 'f3-relative' @('--rect', '64,64,640,360') @('--seconds', '4') -Exe 'testtarget.exe'
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'absolute path') 'F3 relative exe path: refused' (ReadText $r.LLog)
  $r = Invoke-Launch 'f4-missing' @('--rect', '64,64,640,360') @('--seconds', '4') -Exe (Join-Path $run 'nothere\X4.exe')
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'exe not found') 'F4 missing exe: refused'
  $r = Invoke-Launch 'f5-noflag' @('--rect', '64,64,640,360') @('--seconds', '4') -NoTestFlag
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'must be named X4\.exe') 'F5 testtarget.exe without --test-target: refused'
  Stop-Mine

  foreach ($bad in @('0,0,0,0', 'abc', '1,2,3', '0,0,99999,100')) {
    $r = Invoke-Launch ('f6-rect-' + ($bad -replace '[^0-9a-z]', '_')) @('--rect', $bad) @('--seconds', '5')
    Assert ($r.Code -eq 3 -and (ReadText $r.LLog) -match 'WITHOUT the hook: invalid' -and (IsFramedAtWork $r.Target)) "F6 invalid rectangle '$bad': game started normally, exit 3" (ReadText $r.LLog)
    Stop-Mine
  }
  $r = Invoke-Launch 'f7-dllrect' @('--rect', '1,2,3', '--test-raw-rect') @('--seconds', '5')
  Assert ($r.Code -eq 3 -and (ReadText $r.HLog) -match 'invalid or missing rectangle' -and (IsFramedAtWork $r.Target)) 'F7 invalid rectangle reaching the DLL: DLL declines, game normal' (ReadText $r.HLog)
  Stop-Mine
  $r = Invoke-Launch 'f8-hookfail' @('--rect', '64,64,640,360', '--test-fail-hooks') @('--seconds', '5', '--try-cds')
  $hl = ReadText $r.HLog
  Assert ($r.Code -eq 3 -and $hl -match 'simulated hook installation failure .* rolled back (\d+) slot' -and (IsFramedAtWork $r.Target)) 'F8 simulated hook failure: rolled back, game normal' $hl
  Assert ((ReadText $r.TLog) -match 'cds: import slot points into user32 \(not hooked\)') 'F8 rollback verified from inside the target: its IAT points into user32 again' (ReadText $r.TLog)
  Stop-Mine
  $r = Invoke-Launch 'f9-injectfail' @('--rect', '64,64,640,360', '--test-fail-inject') @('--seconds', '5')
  Assert ($r.Code -eq 3 -and (ReadText $r.LLog) -match 'simulated injection failure' -and (IsFramedAtWork $r.Target) -and -not (Test-Path $r.HLog)) 'F9 simulated injection failure: game normal, DLL never loaded' (ReadText $r.LLog)
  Stop-Mine
  $r = Invoke-Launch 'f10-wrongproc' @('--rect', '64,64,640,360', '--test-wrong-exe-env') @('--seconds', '5')
  Assert ($r.Code -eq 3 -and (ReadText $r.HLog) -match 'not the intended process' -and (IsFramedAtWork $r.Target)) 'F10 DLL in a process other than the one named: declines, game normal' (ReadText $r.HLog)
  Stop-Mine
  $r = Invoke-Launch 'f11-unknown' @('--rect', '64,64,640,360', '--frobnicate') @('--seconds', '4')
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'REFUSED: unknown option') 'F11 unknown option: refused'
  $r = Invoke-Launch 'f11b-testopt' @('--rect', '64,64,640,360', '--test-fail-hooks') @('--seconds', '4') -Exe $x4copy -NoTestFlag
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'need --test-target') 'F11 test options without --test-target: refused'
  $pl = Start-Plain 'f12-running' -Seconds 8
  $r = Invoke-Launch 'f12-already' @('--rect', '64,64,640,360') @('--seconds', '4')
  Assert ($r.Code -eq 2 -and (ReadText $r.LLog) -match 'already running') 'F12 exe already running: refused' (ReadText $r.LLog)
  Stop-Mine

  # ================================================================== L log cap
  Write-Host '== L: log size cap'
  $r = Invoke-Launch 'l1-cap' @('--rect', '64,64,640,360', '--log-cap', '2048') @('--seconds', '4')
  Start-Sleep -Milliseconds 300
  $hs = (Get-Item -LiteralPath $r.HLog).Length; $ls = (Get-Item -LiteralPath $r.LLog).Length
  Assert ($r.Code -eq 0 -and $hs -le 2048 -and $ls -le 2048 -and (ReadText $r.HLog) -match 'log size cap reached') "L1 logs capped at 2048 bytes (hook $hs, launcher $ls)"
  Stop-Mine
  $before = (Get-Item -LiteralPath $r.HLog).Length
  $d2 = Invoke-Launch 'l1-cap' @('--rect', '64,64,640,360', '--log-cap', '2048') @('--seconds', '4')
  Assert ((ReadText $d2.HLog).StartsWith('---- log started over') -and (Get-Item -LiteralPath $d2.HLog).Length -le 2048) "L2 next session: a log over half the cap ($before bytes) starts over, still capped"
  Stop-Mine
  $r = Invoke-Launch 'l3-badcap' @('--rect', '64,64,640,360', '--log-cap', '12') @('--seconds', '4')
  Assert ($r.Code -eq 2) 'L3 log cap outside 1024..64 MiB: refused'

  # ================================================================== C cockpit-launch
  Write-Host '== C: cockpit-launch'
  function M($dev, $code, $name, $x, $y, $w, $h, $prim) { return [pscustomobject]@{ Device = "\\.\$dev"; Name = $name; Code = $code; Primary = $prim; X = $x; Y = $y; W = $w; H = $h; Hz = 60; WidthMm = 598; HeightMm = 336 } }
  $topoOk = Join-Path $run 'topo-target.json'
  @((M 'DISPLAY3' 'DELD05F' 'DELL P2714H' -1920 180 1920 1080 $false), (M 'DISPLAY2' 'AUS3438' 'VG34VQL3A' 0 0 3440 1440 $true), (M 'DISPLAY1' 'DELD05F' 'DELL P2714H' 3440 180 1920 1080 $false)) | ConvertTo-Json | Set-Content -LiteralPath $topoOk -Encoding UTF8
  $topoBad = Join-Path $run 'topo-bothleft.json'
  @((M 'DISPLAY1' 'DELD05F' 'DELL P2714H' -3840 126 1920 1080 $false), (M 'DISPLAY3' 'DELD05F' 'DELL P2714H' -1920 126 1920 1080 $false), (M 'DISPLAY2' 'AUS3438' 'VG34VQL3A' 0 0 3440 1440 $true)) | ConvertTo-Json | Set-Content -LiteralPath $topoBad -Encoding UTF8
  $prof = Join-Path $run 'profile\4242'; New-Item -ItemType Directory -Force -Path $prof | Out-Null
  [IO.File]::WriteAllText((Join-Path $prof 'config.xml'), "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<root>`r`n  <fullscreen>true</fullscreen>`r`n  <borderless>false</borderless>`r`n  <fov>1.3333</fov>`r`n  <confinemouse>false</confinemouse>`r`n  <res_width>3440</res_width>`r`n  <res_height>1440</res_height>`r`n</root>`r`n")
  $sf = Join-Path $run 'settings-test.json'
  ([ordered]@{ profileDir = $prof; gameExe = $x4copy; backupDir = (Join-Path $run 'backups'); stateDir = (Join-Path $run 'state'); companionSkipFlag = 'none'
      companionWindowTitle = 'x4cockpit3-test-no-such-window'; sideMatch = 'DELD05F|P2714H' } | ConvertTo-Json) | Set-Content -LiteralPath $sf -Encoding UTF8
  function CL([string[]]$A) {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'cockpit-launch.ps1') @A 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
  }
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-MonitorsJson', $topoOk)
  Assert ($c.Code -eq 2 -and $c.Out -match 'cockpit mode is not ON' -and $c.Out -match 'cockpit-on\.cmd') 'C1 cockpit mode off: refused, tells to run cockpit-on' $c.Out
  $on = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'cockpit.ps1') on -SettingsFile $sf 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'C2 (setup) cockpit.ps1 on for the test profile' $on
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-MonitorsJson', $topoOk, '-GameArgs', '-debug all -logfile debug.log')
  Assert ($c.Code -eq 0 -and $c.Out -match '--rect -1920,0,7280,1440' -and $c.Out -match ' -- -debug all -logfile debug\.log' -and $c.Out -match 'WhatIf: nothing started') 'C2 target arrangement: rectangle -1920,0 7280x1440, game args passed, WhatIf' $c.Out
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-MonitorsJson', $topoBad)
  Assert ($c.Code -eq 2 -and $c.Out -match 'REFUSED: the Windows monitor arrangement does not match') 'C3 mismatching arrangement: refused' $c.Out
  $c = CL @('-WhatIf', '-Force', '-SettingsFile', $sf, '-MonitorsJson', $topoBad)
  Assert ($c.Code -eq 0 -and $c.Out -match 'forced') 'C3 -Force: accepted (WhatIf)' $c.Out
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-Rect', '-1920,0,7280,1440')
  Assert ($c.Code -eq 0 -and $c.Out -match 'from -Rect') 'C4 -Rect override' $c.Out
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-Rect', '1,2,3')
  Assert ($c.Code -eq 2) 'C4 invalid -Rect: refused' $c.Out
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-Rect', '64,64,640,360')
  Assert ($c.Code -eq 0 -and $c.Out -match 'warning: config res 7280x1440 differs') 'C4 config resolution vs window size mismatch is reported'
  $pl = Start-Plain 'c5-running' -Exe $x4copy -Seconds 8
  $c = CL @('-WhatIf', '-SettingsFile', $sf, '-Rect', '64,64,640,360')
  Assert ($c.Code -eq 2 -and $c.Out -match 'already running') 'C5 game already running: refused' $c.Out
  Stop-Mine
  # end to end: detached start through WMI, exactly as the user would start the game.
  # (\" : Windows PowerShell 5.1 does not escape quotes inside an argument for a native program, so do it here)
  $cdir = Join-Path $run 'c6-detached'; New-Item -ItemType Directory -Force -Path $cdir | Out-Null
  $ctl = Join-Path $cdir 'target.log'
  $c = CL @('-SettingsFile', $sf, '-Rect', '64,64,640,360', '-LogDir', $cdir, '-GameArgs', "--hidden --seconds 10 --log \`"$ctl\`"")
  $t = Wait-Target $ctl
  Assert ($c.Code -eq 0 -and $c.Out -match 'hook=ACTIVE') 'C6 cockpit-launch: launcher started detached, hook ACTIVE' $c.Out
  if ($t) {
    Assert (IsExact (Get-WinInfo $t.Hwnd) 64 64 640 360) 'C6 window at the rectangle'
    $lp = [int]([regex]::Match($c.Out, 'detached \(pid (\d+)\)').Groups[1].Value)
    $tp = Get-CimInstance Win32_Process -Filter "ProcessId=$($t.Pid)"
    $lpProc = Get-CimInstance Win32_Process -Filter "ProcessId=$lp"
    $par = $null; if ($lpProc) { $par = Get-CimInstance Win32_Process -Filter "ProcessId=$($lpProc.ParentProcessId)" }
    Assert ($tp.ParentProcessId -eq $lp -and $lpProc -and $par.Name -match '^WmiPrvSE') "C6 game is the launcher's child, the launcher is WMI's (parent: $($par.Name)), not this shell's" "target parent $($tp.ParentProcessId), launcher $lp, launcher parent $($lpProc.ParentProcessId)"
    if ($lp) { $script:started += $lp }
  } else { Assert $false 'C6 target window appeared' (ReadText $ctl) }
  Stop-Mine

  # ================================================================== optional visible check
  if ($Visible) {
    Write-Host '== V: one small VISIBLE hooked window (640x360 at 64,64) for 6 s'
    $r = Invoke-Launch 'v-visible' @('--rect', '64,64,640,360') @('--seconds', '6') -Shown
    if ($r.Target) { Assert ((IsBorderless (Get-WinInfo $r.Target.Hwnd)) -and (IsExact (Get-WinInfo $r.Target.Hwnd) 64 64 640 360)) 'V visible window borderless at the rectangle' }
    Start-Sleep -Seconds 5
    Stop-Mine
  }
} catch {
  $script:fail++; $script:failed += "unexpected error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
  Write-Host "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
} finally {
  Stop-Mine
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed, {2} skipped   (work dir: {3})" -f $script:pass, $script:fail, $script:skip, $run)
foreach ($f in $script:failed) { Write-Host "  failed: $f" }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
