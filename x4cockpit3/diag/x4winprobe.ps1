<#
.SYNOPSIS
  x4winprobe - find out how a window (the X4 game window) reacts to window-management calls from outside.

.DESCRIPTION
  -Experiments : runs a fixed list of documented user32 calls against the window (moves, resizes, placement,
                 style change, maximise/restore, an emulated move/size loop) and logs for each: return value,
                 GetLastError, rect/client/style before, right after, after 50 ms and after 1.5 s, and how many
                 location-change / move-size events Windows reported for the window meanwhile. 0 events = the
                 change never happened (rejected before it took effect); >=2 events with the old rect at the
                 end = it happened and the window was put back.
                 At the end the original style, placement and rectangle are put back.
  -Watch       : passive. Logs every location-change / move-size start/end event of the window for -Seconds
                 (e.g. while the user tries to drag the window by hand). Calls nothing on the window.
  Events come from SetWinEventHook with WINEVENT_OUTOFCONTEXT: nothing is loaded into the target process.
  Not done on purpose: WM_SYSCOMMAND SC_MOVE/SC_SIZE (they start a modal loop that waits for keyboard/mouse
  input), any input simulation, anything inside the target process.

.EXAMPLE
  .\x4winprobe.ps1 -Watch -Seconds 30          # the running game; drag it by hand meanwhile
  .\x4winprobe.ps1 -Experiments                # the running game
  .\x4winprobe.ps1 -Experiments -Handle 0x1234 # any other window (tests)
#>
[CmdletBinding()]
param(
  [switch]$Experiments,
  [switch]$Watch,
  [int]$Seconds = 30,
  [string]$Handle = '',
  [string]$Area = '',            # target rectangle "x,y,w,h"; default: the 'uw-left-only' rectangle of the live topology
  [string]$SettingsFile = '',
  [string]$LogDir = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Layout.ps1')
. (Join-Path $root 'lib\Native.ps1')

if (-not ('X4Cockpit3.Probe' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace X4Cockpit3 {
  public static class Probe {
    public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct PRECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct PPOINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT { public int length, flags, showCmd; public PPOINT ptMin, ptMax; public PRECT rcNormal; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out PRECT r);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] static extern bool PeekMessageW(out MSG m, IntPtr h, uint a, uint b, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    static WinEventProc keep;
    static List<IntPtr> hooks = new List<IntPtr>();
    static IntPtr target;
    static Stopwatch sw = Stopwatch.StartNew();
    public static List<string> Events = new List<string>();
    public static int LocationChanges, MoveSizeStarts, MoveSizeEnds;
    public static void Start(IntPtr hwnd) {
      target = hwnd; uint pid; GetWindowThreadProcessId(hwnd, out pid);
      keep = new WinEventProc(OnEvent);
      // EVENT_SYSTEM_MOVESIZESTART/END (0x0A/0x0B), EVENT_OBJECT_LOCATIONCHANGE (0x800B); WINEVENT_OUTOFCONTEXT (0)
      hooks.Add(SetWinEventHook(0x000A, 0x000B, IntPtr.Zero, keep, pid, 0, 0));
      hooks.Add(SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, keep, pid, 0, 0));
    }
    public static void Stop() { foreach (var h in hooks) if (h != IntPtr.Zero) UnhookWinEvent(h); hooks.Clear(); }
    public static void Reset() { LocationChanges = 0; MoveSizeStarts = 0; MoveSizeEnds = 0; Events.Clear(); }
    static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
      if (hwnd != target || idObject != 0) return;
      PRECT r; GetWindowRect(hwnd, out r);
      string name = ev == 0x800B ? "LOCATIONCHANGE" : (ev == 0x0A ? "MOVESIZESTART" : "MOVESIZEEND");
      if (ev == 0x800B) LocationChanges++; else if (ev == 0x0A) MoveSizeStarts++; else MoveSizeEnds++;
      Events.Add(string.Format("{0,8} ms {1,-15} rect now ({2},{3}) {4}x{5}", sw.ElapsedMilliseconds, name, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top));
    }
    public static void Pump(int ms) {
      var t = Stopwatch.StartNew(); MSG m;
      while (t.ElapsedMilliseconds < ms) {
        while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
        System.Threading.Thread.Sleep(5);
      }
    }
    public static long Now() { return sw.ElapsedMilliseconds; }
  }
}
'@
}

$settings = Read-CockpitSettings -ToolRoot $root -SettingsFile $SettingsFile
if (-not $LogDir) { $LogDir = Join-Path $settings.stateDir 'probe' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$logFile = Join-Path $LogDir ('x4winprobe-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Log([string]$s) { Write-Host $s; Add-Content -LiteralPath $logFile -Value $s -Encoding UTF8 }

if ($Handle) { $h = ConvertTo-Hwnd $Handle; $who = "handle $Handle" } else {
  $gp = @(Get-GameProcesses $settings.gameExe -RequirePathMatch | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
  if ($gp.Count -eq 0) { Write-Host "no running game window found (gameExe='$($settings.gameExe)'). Start the game, or pass -Handle."; exit 1 }
  $h = $gp[0].MainWindowHandle; $who = "game pid $($gp[0].Id) ($($gp[0].Path))"
}
if (-not [X4Cockpit3.Native]::IsWindow($h)) { Write-Host "not a window: $h"; exit 1 }

function Info { $i = Get-WinInfo $h; return (Fmt 'rect ({0},{1}) {2}x{3} client ({4},{5}) {6}x{7} style 0x{8:X} ex 0x{9:X}{10}{11}' $i.X $i.Y $i.W $i.H $i.ClientX $i.ClientY $i.ClientW $i.ClientH $i.Style $i.ExStyle $(if ($i.Zoomed) { ' ZOOMED' } else { '' }) $(if ($i.Iconic) { ' ICONIC' } else { '' })) }

$mons = @(Get-LiveMonitors)
Log "x4winprobe $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') target: $who hwnd 0x$('{0:X}' -f [int64]$h)"
foreach ($m in $mons | Sort-Object X) { Log (Fmt '  monitor {0} {1}x{2} at ({3},{4}){5}' (Get-MonitorLabel $m) $m.W $m.H $m.X $m.Y $(if ($m.Primary) { ' primary' } else { '' })) }
Log "  start: $(Info)"

[X4Cockpit3.Probe]::Start($h)
try {
  if ($Watch) {
    Log "WATCH for $Seconds s (passive). Try moving/resizing the window by hand now."
    $end = [X4Cockpit3.Probe]::Now() + $Seconds * 1000
    $shown = 0
    while ([X4Cockpit3.Probe]::Now() -lt $end) {
      [X4Cockpit3.Probe]::Pump(200)
      $ev = [X4Cockpit3.Probe]::Events
      while ($shown -lt $ev.Count) { Log "  $($ev[$shown])"; $shown++ }
    }
    Log ("WATCH end: {0} location changes, {1} move/size starts, {2} ends. now: {3}" -f [X4Cockpit3.Probe]::LocationChanges, [X4Cockpit3.Probe]::MoveSizeStarts, [X4Cockpit3.Probe]::MoveSizeEnds, (Info))
    exit 0
  }
  if (-not $Experiments) { Write-Host 'Nothing to do: use -Watch or -Experiments.'; exit 1 }

  # target rectangle
  if ($Area) { $v = @($Area -split ',' | ForEach-Object { [int]$_.Trim() }); $R = [pscustomobject]@{ X = $v[0]; Y = $v[1]; W = $v[2]; H = $v[3] } }
  else {
    $plan = Get-CockpitPlan -Mons $mons -Preset 'uw-left-only' -Settings $settings
    if (-not $plan.Ok) { $plan = Get-CockpitPlan -Mons $mons -Preset 'triple' -Settings $settings }
    $R = $plan.Rect
  }
  Log (Fmt 'target rectangle: ({0},{1}) {2}x{3}' $R.X $R.Y $R.W $R.H)

  $orig = Get-WinInfo $h
  $wp0 = New-Object X4Cockpit3.Probe+WINDOWPLACEMENT; $wp0.length = [Runtime.InteropServices.Marshal]::SizeOf($wp0)
  [void][X4Cockpit3.Probe]::GetWindowPlacement($h, [ref]$wp0)
  $NOZ = 0x0004; $NOACT = 0x0010; $NOSIZE = 0x0001; $NOMOVE = 0x0002; $FRAME = 0x0020; $NOSENDCHANGING = 0x0400; $NOOWNER = 0x0200

  function Reset-Window {
    # every experiment starts from the original state, so each result stands on its own
    $cur = Get-WinInfo $h
    if ($cur.Style -ne $orig.Style -or $cur.X -ne $orig.X -or $cur.Y -ne $orig.Y -or $cur.W -ne $orig.W -or $cur.H -ne $orig.H) {
      if ($cur.Zoomed) { [void][X4Cockpit3.Native]::ShowWindow($h, 9) }
      [void][X4Cockpit3.Native]::SetWindowLongPtrW($h, -16, [IntPtr]$orig.Style)
      [void][X4Cockpit3.Native]::SetWindowPos($h, [IntPtr]::Zero, $orig.X, $orig.Y, $orig.W, $orig.H, 0x0004 -bor 0x0010 -bor 0x0020)
      [X4Cockpit3.Probe]::Pump(300)
    }
  }
  function Run([string]$name, [scriptblock]$call) {
    Reset-Window
    [X4Cockpit3.Probe]::Pump(100); [X4Cockpit3.Probe]::Reset()
    $before = Info
    $t0 = [X4Cockpit3.Probe]::Now()
    $ret = & $call
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $ms = [X4Cockpit3.Probe]::Now() - $t0
    $imm = Info
    [X4Cockpit3.Probe]::Pump(50); $a50 = Info
    [X4Cockpit3.Probe]::Pump(1450); $a1500 = Info
    $changed = 'UNCHANGED'; if ($a1500 -ne $before) { $changed = 'CHANGED' }
    $errTxt = ''; if ("$ret" -eq 'False') { $errTxt = ", GetLastError $err" }
    Log "== $name -> returned $ret$errTxt, call took $ms ms, $changed"
    Log "   before : $before"
    Log "   at once: $imm"
    Log "   +50 ms : $a50"
    Log "   +1.5 s : $a1500"
    Log ("   events : {0} location changes, {1} move/size starts, {2} ends" -f [X4Cockpit3.Probe]::LocationChanges, [X4Cockpit3.Probe]::MoveSizeStarts, [X4Cockpit3.Probe]::MoveSizeEnds)
    foreach ($e in [X4Cockpit3.Probe]::Events) { Log "     $e" }
  }
  $N = [X4Cockpit3.Native]
  $P = [X4Cockpit3.Probe]
  $o = $orig
  $mr = [IntPtr]::Zero

  Run 'E1 SetWindowPos small move (+60,+40) NOSIZE' { $N::SetWindowPos($h, [IntPtr]::Zero, $o.X + 60, $o.Y + 40, 0, 0, $NOSIZE -bor $NOZ -bor $NOACT) }
  Run 'E2 SetWindowPos small resize (-200,-150) NOMOVE' { $N::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $o.W - 200, $o.H - 150, $NOMOVE -bor $NOZ -bor $NOACT) }
  Run 'E3 SetWindowPos move onto the left monitor NOSIZE' { $N::SetWindowPos($h, [IntPtr]::Zero, $R.X, $R.Y, 0, 0, $NOSIZE -bor $NOZ -bor $NOACT) }
  Run 'E4 SetWindowPos target rect' { $N::SetWindowPos($h, [IntPtr]::Zero, $R.X, $R.Y, $R.W, $R.H, $NOZ -bor $NOACT) }
  Run 'E5 SetWindowPos target rect + NOSENDCHANGING' { $N::SetWindowPos($h, [IntPtr]::Zero, $R.X, $R.Y, $R.W, $R.H, $NOZ -bor $NOACT -bor $NOSENDCHANGING) }
  Run 'E6 MoveWindow target rect' { $P::MoveWindow($h, $R.X, $R.Y, $R.W, $R.H, $true) }
  Run 'E7 SetWindowPlacement normal rect = target' {
    $rc = New-Object X4Cockpit3.Probe+PRECT; $rc.Left = $R.X; $rc.Top = $R.Y; $rc.Right = $R.X + $R.W; $rc.Bottom = $R.Y + $R.H
    $wp = New-Object X4Cockpit3.Probe+WINDOWPLACEMENT; $wp.length = $wp0.length; $wp.flags = 0; $wp.showCmd = 1
    $wp.ptMin = $wp0.ptMin; $wp.ptMax = $wp0.ptMax; $wp.rcNormal = $rc
    $P::SetWindowPlacement($h, [ref]$wp) }
  Run 'E8 SetWindowLongPtr strip caption/frame + FRAMECHANGED' {
    $ns = $o.Style -band (-bnot [int64](0x00C00000 -bor 0x00040000 -bor 0x00080000 -bor 0x00020000 -bor 0x00010000))
    [void]$N::SetWindowLongPtrW($h, -16, [IntPtr]$ns)
    $N::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, $NOMOVE -bor $NOSIZE -bor $NOZ -bor $NOACT -bor $FRAME) }
  Run 'E9 WM_ENTERSIZEMOVE + SetWindowPos target + WM_EXITSIZEMOVE' {
    [void]$P::SendMessageTimeoutW($h, 0x0231, [IntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$mr)
    $r9 = $N::SetWindowPos($h, [IntPtr]::Zero, $R.X, $R.Y, $R.W, $R.H, $NOZ -bor $NOACT)
    [void]$P::SendMessageTimeoutW($h, 0x0232, [IntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$mr)
    $r9 }
  Run 'E10 ShowWindow SW_MAXIMIZE' { $N::ShowWindow($h, 3) }
  Run 'E11 ShowWindow SW_RESTORE' { $N::ShowWindow($h, 9) }
  Run 'E12 WM_SYSCOMMAND SC_MAXIMIZE (SendMessageTimeout)' { $P::SendMessageTimeoutW($h, 0x0112, [IntPtr]0xF030, [IntPtr]::Zero, 2, 3000, [ref]$mr) -ne [IntPtr]::Zero }
  Run 'E13 WM_SYSCOMMAND SC_RESTORE (SendMessageTimeout)' { $P::SendMessageTimeoutW($h, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero, 2, 3000, [ref]$mr) -ne [IntPtr]::Zero }

  # put everything back
  [void]$N::SetWindowLongPtrW($h, -16, [IntPtr]$orig.Style)
  [void]$N::SetWindowLongPtrW($h, -20, [IntPtr]$orig.ExStyle)
  [void]$P::SetWindowPlacement($h, [ref]$wp0)
  [void]$N::SetWindowPos($h, [IntPtr]::Zero, $orig.X, $orig.Y, $orig.W, $orig.H, $NOZ -bor $NOACT -bor $FRAME)
  [X4Cockpit3.Probe]::Pump(500)
  Log "end (original style/placement/rect put back): $(Info)"
  Log "log: $logFile"
} finally { [X4Cockpit3.Probe]::Stop() }
