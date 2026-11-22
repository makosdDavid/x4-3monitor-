<#
fix-displays.ps1 - puts the monitors into their proper modes and arrangement in one go.

What it does (in this order):
  1. Switches on every connected monitor that is not part of the desktop yet (with -NoLaptop: every one except
     the laptop panel). Monitors that are already on keep their output; nothing is dropped.
  2. Identifies every active monitor by its EDID code (not by number or resolution).
  3. Picks the best mode Windows currently offers for each one:
        ultrawide (AUS3438)      3440x1440 at the highest refresh offered; if the output it is on cannot
                                 carry that, the best fallback (2560x1080@60, then 1920x1080@60)
        Dell P2714H (DELD05E/F)  1920x1080@60
        laptop panel             keeps its current mode
  4. Arrangement: ultrawide = main display at 0,0; one Dell directly left, one directly right, both
     vertically centred; laptop panel left of the left Dell.
  5. Applies everything in one step, then asks "keep?" on every active screen; no answer in 20 s = back to the
     previous settings (same safety net as the Windows "Keep these display settings?" box).

Usage:
  fix-displays.ps1            apply
  fix-displays.ps1 -WhatIf    only show what it would set (changes nothing)
  fix-displays.ps1 -Revert    go back to the settings saved before the last apply
  fix-displays.ps1 -Swap      the two Dells are the other way round (left <-> right)
#>
param(
    [switch]$WhatIf,
    [switch]$Revert,
    [switch]$Swap,
    [switch]$UwSafe,                 # ultrawide on the dock: skip 3440x1440 and use the lighter 2560x1080@60 signal
    [switch]$NoLaptop,               # switch the laptop's own panel off: frees one of the graphics card's four outputs
    [string]$LeftDell = 'DELD05F',   # only used when both Dells hang on the dock: the one fed over DVI is the left one (the owner said so)
    [string]$SideMode = '',          # e.g. 1280x720: upper limit for BOTH side monitors, when the dock link is too slow for 2x 1920x1080
    [int]$KeepSeconds = 20
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $here 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
$stateFile = Join-Path $stateDir 'displays-previous.json'
$logFile = Join-Path $stateDir 'fix-displays.log'
function Say($t) { $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $t; Write-Host $line; Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 }

# One run at a time: the shortcut starts hidden, and a second click while the first run is still working made
# two runs fight over the settings. A second start now simply leaves.
$script:busy = $null
if (-not $WhatIf) {
    $script:mutex = New-Object System.Threading.Mutex($false, 'Local\x4cockpit3-fix-displays')
    $got = $false; try { $got = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { Say 'another run is still working - leaving'; exit 0 }
    # immediate feedback, so it is visible that the click was taken
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    $ps = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $script:busy = New-Object System.Windows.Forms.Form
    $script:busy.Text = 'Monitor settings'; $script:busy.TopMost = $true; $script:busy.StartPosition = 'Manual'; $script:busy.ShowInTaskbar = $false; $script:busy.ControlBox = $false
    $script:busy.Size = New-Object System.Drawing.Size(420, 110)
    $script:busy.Location = New-Object System.Drawing.Point(($ps.X + [int](($ps.Width - 420) / 2)), ($ps.Y + 60))
    $bl = New-Object System.Windows.Forms.Label; $bl.SetBounds(20, 20, 370, 40); $bl.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $bl.Text = $(if ($Revert) { 'Elozo beallitas visszaallitasa...' } elseif ($NoLaptop) { 'Laptop kijelzo KI, monitorok beallitasa...' } else { 'Laptop kijelzo BE, monitorok beallitasa...' })
    $script:busy.Controls.Add($bl); $script:busy.Show(); [System.Windows.Forms.Application]::DoEvents()
}
function Close-Busy { if ($script:busy) { $script:busy.Close(); $script:busy.Dispose(); $script:busy = $null } }

Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class DispFix {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString; public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE { [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName; public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields; public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput; public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName; public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency, r1, r2, r3, r4, r5, r6, r7, r8; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE d, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE m, IntPtr hwnd, uint flags, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="ChangeDisplaySettingsEx")] static extern int ChangeDisplaySettingsExNull(string dev, IntPtr m, IntPtr hwnd, uint flags, IntPtr lParam);

  static DEVMODE NewMode() { DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return m; }

  // one line per output that is part of the desktop: DeviceName|monitorCode|adapter
  public static string[] ActiveOutputs() {
    var res = new List<string>();
    for (uint i = 0; i < 32; i++) {
      DISPLAY_DEVICE d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
      if (!EnumDisplayDevices(null, i, ref d, 0)) break;
      if ((d.StateFlags & 1) == 0) continue;                      // not attached to the desktop
      // One output can list several monitors (e.g. the switched-off laptop panel first). Take the ACTIVE one;
      // taking simply the first one mislabelled every output as the laptop panel when that panel was off.
      string code = ""; string path = "";
      for (uint j = 0; j < 8; j++) {
        DISPLAY_DEVICE mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        if (!EnumDisplayDevices(d.DeviceName, j, ref mon, 0)) break;
        bool active = (mon.StateFlags & 1) != 0;
        if (code == "" || active) {
          if (mon.DeviceID != null) { string[] p = mon.DeviceID.Split('\\'); if (p.Length > 1) code = p[1]; }
          // the device interface path (\\?\DISPLAY#DELD05F#5&..&UID4352#{guid}) identifies the physical connection
          DISPLAY_DEVICE ifc = new DISPLAY_DEVICE(); ifc.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
          if (EnumDisplayDevices(d.DeviceName, j, ref ifc, 1) && ifc.DeviceID != null) path = ifc.DeviceID;
        }
        if (active) break;
      }
      res.Add(d.DeviceName + "|" + code + "|" + path);
    }
    return res.ToArray();
  }
  public static string[] Modes(string dev) {
    var seen = new HashSet<string>(); var res = new List<string>();
    for (int k = 0; ; k++) { DEVMODE m = NewMode(); if (!EnumDisplaySettings(dev, k, ref m)) break; string s = m.dmPelsWidth + "|" + m.dmPelsHeight + "|" + m.dmDisplayFrequency; if (seen.Add(s)) res.Add(s); }
    return res.ToArray();
  }
  public static string Current(string dev) {
    DEVMODE m = NewMode(); if (!EnumDisplaySettings(dev, -1, ref m)) return "";
    return m.dmPelsWidth + "|" + m.dmPelsHeight + "|" + m.dmDisplayFrequency + "|" + m.dmPositionX + "|" + m.dmPositionY;
  }
  // test=true: only asks the driver whether this mode would be accepted for this output (changes nothing)
  public static int Stage(string dev, int w, int h, int hz, int x, int y, bool primary, bool test) {
    DEVMODE m = NewMode(); if (!EnumDisplaySettings(dev, -1, ref m)) { m = NewMode(); EnumDisplaySettings(dev, -2, ref m); }
    m.dmPelsWidth = w; m.dmPelsHeight = h; m.dmDisplayFrequency = hz; m.dmPositionX = x; m.dmPositionY = y; m.dmBitsPerPel = 32;
    m.dmFields = 0x20 | 0x40000 | 0x80000 | 0x100000 | 0x400000;  // position, bpp, width, height, frequency
    uint flags = test ? 0x2u : (0x1u | 0x10000000u);               // CDS_TEST  or  CDS_UPDATEREGISTRY|CDS_NORESET
    if (primary && !test) flags |= 0x10u;                           // CDS_SET_PRIMARY
    return ChangeDisplaySettingsEx(dev, ref m, IntPtr.Zero, flags, IntPtr.Zero);
  }
  // takes one output off the desktop (documented way: zero size + position), applied at the next Commit
  public static int Detach(string dev) {
    DEVMODE m = NewMode(); m.dmPelsWidth = 0; m.dmPelsHeight = 0; m.dmPositionX = 0; m.dmPositionY = 0;
    m.dmFields = 0x20 | 0x80000 | 0x100000;
    return ChangeDisplaySettingsEx(dev, ref m, IntPtr.Zero, 0x1u | 0x10000000u, IntPtr.Zero);
  }
  public static int Commit() { return ChangeDisplaySettingsExNull(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@

# Switching a connected-but-dark monitor ON. DisplaySwitch.exe /extend proved unreliable here (did nothing, or
# brought the laptop panel up and dropped both dock monitors), so the path is added explicitly: every active
# path is kept exactly as it is, and one new path per wanted monitor is added on a free output of the card.
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class DispTopo {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Num; public uint Den; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH_TARGET { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO { public PATH_SOURCE source; public PATH_TARGET target; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct MODE_INFO { public uint infoType; public uint id; public LUID adapterId; public ulong d0, d1, d2, d3, d4, d5; }
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPath, [In, Out] PATH_INFO[] paths, ref uint numMode, [In, Out] MODE_INFO[] modes, IntPtr topo);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPath, [In] PATH_INFO[] paths, uint numMode, [In] MODE_INFO[] modes, uint flags);
  static bool IsInternal(uint tech) { return tech == 0x80000000u || tech == 11 || tech == 13 || tech == 6; }
  static string K(LUID a, uint id) { return a.High + ":" + a.Low + ":" + id; }
  // returns "code|text"; code 0 = accepted, -1 = nothing to switch on. validateOnly asks the driver and changes nothing.
  public static string Enable(bool internalPanel, bool externals, bool validateOnly) {
    uint np, nm; int rc = GetDisplayConfigBufferSizes(1, out np, out nm); if (rc != 0) return rc + "|reading the display paths failed";
    PATH_INFO[] paths = new PATH_INFO[np]; MODE_INFO[] modes = new MODE_INFO[nm];
    rc = QueryDisplayConfig(1, ref np, paths, ref nm, modes, IntPtr.Zero); if (rc != 0) return rc + "|reading the display paths failed";
    var keep = new List<PATH_INFO>(); var usedSrc = new HashSet<string>(); var activeTgt = new HashSet<string>();
    for (int i = 0; i < np; i++) if ((paths[i].flags & 1) != 0) { keep.Add(paths[i]); usedSrc.Add(K(paths[i].source.adapterId, paths[i].source.id)); activeTgt.Add(K(paths[i].target.adapterId, paths[i].target.id)); }
    int added = 0; string what = "";
    for (int i = 0; i < np; i++) {
      PATH_INFO p = paths[i];
      if ((p.flags & 1) != 0 || p.target.targetAvailable == 0) continue;
      string tk = K(p.target.adapterId, p.target.id); if (activeTgt.Contains(tk)) continue;
      bool inner = IsInternal(p.target.outputTechnology);
      if (inner ? !internalPanel : !externals) continue;
      string sk = K(p.source.adapterId, p.source.id); if (usedSrc.Contains(sk)) continue;
      p.flags = 1; p.source.modeInfoIdx = 0xFFFFFFFFu; p.target.modeInfoIdx = 0xFFFFFFFFu;
      keep.Add(p); usedSrc.Add(sk); activeTgt.Add(tk); added++;
      what += (inner ? " laptop panel" : " external monitor") + " (target 0x" + p.target.id.ToString("X") + ")";
    }
    if (added == 0) return "-1|nothing to switch on";
    uint flags = 0x20u | 0x400u | (validateOnly ? 0x40u : (0x80u | 0x200u));   // supplied config + allow changes; validate | apply + save
    rc = SetDisplayConfig((uint)keep.Count, keep.ToArray(), nm, modes, flags);
    return rc + "|" + (validateOnly ? "driver test for switching on" : "switching on") + what;
  }
}
'@

function Get-Outputs {
    $list = @()
    # how each connected monitor is attached: 5 = the laptop's own HDMI, 10 = DisplayPort external (the dock), 11 = internal
    $conn = @{}
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue | ForEach-Object {
        $key = (($_.InstanceName -replace '_\d+$', '') -replace '\\', '#').ToUpper(); $conn[$key] = [int]$_.VideoOutputTechnology }
    foreach ($line in [DispFix]::ActiveOutputs()) {
        $p = $line -split '\|', 3
        $via = 'unknown'; $pathUp = ([string]$p[2]).ToUpper()
        foreach ($k in $conn.Keys) { if ($pathUp.Contains($k)) { if ($conn[$k] -eq 5) { $via = 'laptop-hdmi' } elseif ($conn[$k] -eq 10) { $via = 'dock' } elseif ($conn[$k] -eq 11 -or $conn[$k] -lt 0) { $via = 'internal' } else { $via = "code$($conn[$k])" } } }
        $cur = [DispFix]::Current($p[0]) -split '\|'
        if ($cur.Count -lt 5) { continue }
        $modes = @([DispFix]::Modes($p[0]) | ForEach-Object { $q = $_ -split '\|'; [pscustomobject]@{ W = [int]$q[0]; H = [int]$q[1]; Hz = [int]$q[2] } })
        $role = 'other'
        # ultrawide and laptop panel are known by their EDID code; every other external monitor is a side monitor
        # (the two Dell P2714H, or any spare monitor that takes the place of one)
        if ($p[1] -eq 'AUS3438') { $role = 'ultrawide' } elseif ($p[1] -eq 'NCP004D' -or $via -eq 'internal') { $role = 'laptop' } else { $role = 'dell' }
        $list += [pscustomobject]@{ Dev = $p[0]; Code = $p[1]; Role = $role; Via = $via; W = [int]$cur[0]; H = [int]$cur[1]; Hz = [int]$cur[2]; X = [int]$cur[3]; Y = [int]$cur[4]; Modes = $modes }
    }
    $list
}
function Describe($o) { '{0,-13} {1,-9} {2,-12} {3}x{4}@{5} at {6},{7}' -f ($o.Dev -replace '\\\\\.\\', ''), $o.Code, $o.Via, $o.W, $o.H, $o.Hz, $o.X, $o.Y }
function Best-Hz($o, $w, $h, $prefer) {
    $hz = @($o.Modes | Where-Object { $_.W -eq $w -and $_.H -eq $h } | ForEach-Object { $_.Hz } | Sort-Object -Unique)
    if (-not $hz.Count) { return 0 }
    foreach ($p in $prefer) { if ($hz -contains $p) { return $p } }
    ($hz | Sort-Object -Descending)[0]
}
function Apply-Set($set, [string]$label, [string]$detachDev = '') {
    # stage every output, then commit once so the driver judges the whole combination
    $codes = @()
    foreach ($s in ($set | Sort-Object { -[int]$_.Primary })) { $codes += [DispFix]::Stage($s.Dev, $s.W, $s.H, $s.Hz, $s.X, $s.Y, [bool]$s.Primary, $false) }
    if ($detachDev) { $d = [DispFix]::Detach($detachDev); Say ("   laptop panel off: stage code $d") }
    $c = [DispFix]::Commit()
    Say ("$label : stage codes [" + ($codes -join ',') + "], commit $c  (0 = accepted)")
    (($codes | Where-Object { $_ -ne 0 }).Count -eq 0) -and ($c -eq 0)
}

# ---------- revert ----------
if ($Revert) {
    if (-not (Test-Path $stateFile)) { Say 'No saved previous settings.'; exit 1 }
    $prev = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    [void](Apply-Set $prev 'revert to saved settings'); exit 0
}

# ---------- 1. extend if the desktop is on the laptop panel only ----------
$connected = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue).Count
$outs = @(Get-Outputs)
Say ("connected monitors: $connected, part of the desktop: " + $outs.Count)
$needExtend = $connected -gt $outs.Count
$wanted = $connected
if ($NoLaptop) {
    # the laptop panel is meant to stay off: only switch on when an EXTERNAL monitor is missing from the desktop
    $externalsOn = @($outs | Where-Object { $_.Role -ne 'laptop' }).Count
    $needExtend = ($connected - 1) -gt $externalsOn
    $wanted = $externalsOn + $(if (@($outs | Where-Object { $_.Role -eq 'laptop' }).Count) { 1 } else { 0 })
    if ($needExtend) { $wanted = $connected - 1 + $(if (@($outs | Where-Object { $_.Role -eq 'laptop' }).Count) { 1 } else { 0 }) }
}
# the state to go back to, taken BEFORE anything is switched on
$lapWasOn = [bool](@($outs | Where-Object { $_.Role -eq 'laptop' }).Count)
$prevBefore = @($outs | ForEach-Object { [pscustomobject]@{ Dev = $_.Dev; Code = $_.Code; W = $_.W; H = $_.H; Hz = $_.Hz; X = $_.X; Y = $_.Y; Primary = ($_.X -eq 0 -and $_.Y -eq 0) } })
if ($needExtend) {
    if ($WhatIf) { $r = [DispTopo]::Enable((-not $NoLaptop), $true, $true) -split '\|', 2; Say ("WhatIf: $($r[1]) -> " + $(if ($r[0] -eq '0') { 'accepted' } else { "refused (code $($r[0]))" }) + ' (nothing is changed)') }
    else {
        $r = [DispTopo]::Enable((-not $NoLaptop), $true, $false) -split '\|', 2
        Say ("$($r[1]) : code $($r[0])  (0 = accepted)")
        if ($r[0] -ne '0' -and $r[0] -ne '-1') {
            Say 'falling back to the Windows projection switch (Extend)'
            Start-Process DisplaySwitch.exe -ArgumentList '/extend'
        }
        # Windows needs a while to bring a monitor up; wait until the wanted ones are on the desktop (max 25 s)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        do { Start-Sleep -Seconds 2; $outs = @(Get-Outputs) } while ($outs.Count -lt $wanted -and $sw.Elapsed.TotalSeconds -lt 25)
        Start-Sleep -Seconds 2; $outs = @(Get-Outputs)
        Say ("part of the desktop now: " + $outs.Count + " of $connected")
    }
}
Say 'now:'; foreach ($o in $outs) { Say ('   ' + (Describe $o)) }

# ---------- 2-3. pick the modes ----------
$uw = $outs | Where-Object { $_.Role -eq 'ultrawide' } | Select-Object -First 1
$dells = @($outs | Where-Object { $_.Role -eq 'dell' })
$lap = $outs | Where-Object { $_.Role -eq 'laptop' } | Select-Object -First 1
# Which Dell is left and which is right: the two can report the same EDID code (it depends on the input used),
# so go by the connection first - the Dell on the laptop's own HDMI is the left one, the Dell on the dock the
# right one - and only then by the EDID code. -Swap turns the result round.
$left = $null; $right = $null
if ($dells.Count -eq 2) {
    $onLaptop = @($dells | Where-Object { $_.Via -eq 'laptop-hdmi' }); $onDock = @($dells | Where-Object { $_.Via -eq 'dock' })
    $dpDell = @($dells | Where-Object { $_.Code -eq 'DELD05E' })
    if ($onLaptop.Count -eq 1 -and $onDock.Count -eq 1) { $left = $onLaptop[0]; $right = $onDock[0] }
    elseif ($dpDell.Count -eq 1) { $right = $dpDell[0]; $left = $dells | Where-Object { $_.Dev -ne $right.Dev } | Select-Object -First 1 }   # the Dell on DisplayPort stands on the right
    elseif ($dells[0].Code -ne $dells[1].Code) { $left = $dells | Where-Object { $_.Code -eq $LeftDell } | Select-Object -First 1; $right = $dells | Where-Object { $_.Code -ne $LeftDell } | Select-Object -First 1 }
    else { $s = @($dells | Sort-Object X); $left = $s[0]; $right = $s[1] }
} elseif ($dells.Count -eq 1) {
    if ($dells[0].Via -eq 'dock') { $right = $dells[0] } else { $left = $dells[0] }
}
if ($Swap) { $t = $left; $left = $right; $right = $t }
if ($left)  { Say ('left Dell : ' + ($left.Dev -replace '\\\\\.\\', '') + ' (' + $left.Via + ')') }
if ($right) { Say ('right Dell: ' + ($right.Dev -replace '\\\\\.\\', '') + ' (' + $right.Via + ')') }

function Get-UwCandidates($u) {
    $c = @()
    if (-not $u) { return $c }
    # 100 Hz is only offered on the laptop's own HDMI. Through the dock the ultrawide shares the link with a
    # Dell: 75 Hz then leaves too little for the Dell (measured), so go straight to 60 Hz there.
    $skipNative = $UwSafe -and $u.Via -eq 'dock'
    if ($skipNative) { Say 'UwSafe: the ultrawide is on the dock - using the lighter 2560x1080@60 signal instead of 3440x1440.' }
    $hz = 0
    if (-not $skipNative) { $hz = Best-Hz $u 3440 1440 @(100, 60, 75); if ($hz) { $c += [pscustomobject]@{ W = 3440; H = 1440; Hz = $hz } } }
    if ($hz -gt 60 -and ($u.Modes | Where-Object { $_.W -eq 3440 -and $_.H -eq 1440 -and $_.Hz -eq 60 })) { $c += [pscustomobject]@{ W = 3440; H = 1440; Hz = 60 } }
    $hz = Best-Hz $u 2560 1080 @(60); if ($hz) { $c += [pscustomobject]@{ W = 2560; H = 1080; Hz = $hz } }
    $hz = Best-Hz $u 1920 1080 @(60); if ($hz) { $c += [pscustomobject]@{ W = 1920; H = 1080; Hz = $hz } }
    if (-not ($u.Modes | Where-Object { $_.W -eq 3440 -and $_.H -eq 1440 })) {
        Say '!  The ultrawide is NOT offered 3440x1440 on the output it is plugged into right now. It gets a fallback mode and will not be sharp.'
    }
    $c
}
$prev0 = $prevBefore
function Restore-Previous {
    # Output numbers can change when a monitor is switched on or off, so find each monitor again by its code.
    $now = @(Get-Outputs)
    if ($lapWasOn -and -not @($now | Where-Object { $_.Role -eq 'laptop' }).Count) {
        $r = [DispTopo]::Enable($true, $false, $false) -split '\|', 2; Say ("restore: $($r[1]) : code $($r[0])"); Start-Sleep -Seconds 4; $now = @(Get-Outputs)
    }
    $set = @()
    foreach ($s in $prev) {
        $m = @($now | Where-Object { $_.Code -eq $s.Code })
        if ($m.Count -eq 1) { $set += [pscustomobject]@{ Dev = $m[0].Dev; Code = $s.Code; W = $s.W; H = $s.H; Hz = $s.Hz; X = $s.X; Y = $s.Y; Primary = $s.Primary } } else { $set += $s }
    }
    $det = ''
    if (-not $lapWasOn) { $l = $now | Where-Object { $_.Role -eq 'laptop' } | Select-Object -First 1; if ($l) { $det = $l.Dev } }
    [void](Apply-Set $set 'restore' $det)
}
$cap = $null
if ($SideMode -match '^(\d+)x(\d+)$') { $cap = @([int]$Matches[1], [int]$Matches[2]) }
if ($cap -and -not $WhatIf) {
    # The side monitors on the dock share one link. First bring every side monitor that is above the limit DOWN
    # to it, so the link has room; only then can the other one be raised from its emergency mode.
    $changed = $false
    foreach ($o in @($left, $right)) {
        if (-not $o) { continue }
        if ($o.W -gt $cap[0] -or $o.H -gt $cap[1]) {
            $hz = Best-Hz $o $cap[0] $cap[1] @(60)
            if ($hz) { $r = [DispFix]::Stage($o.Dev, $cap[0], $cap[1], $hz, $o.X, $o.Y, $false, $false); Say ("SideMode: lowering " + ($o.Dev -replace '\\\\\.\\', '') + " to $($cap[0])x$($cap[1])@$hz first (stage code $r)"); $changed = $true }
        }
    }
    if ($changed) {
        $c = [DispFix]::Commit(); Say ("SideMode: commit $c"); Start-Sleep -Seconds 4
        $outs = @(Get-Outputs)
        if ($left)  { $d = $left.Dev;  $left  = $outs | Where-Object { $_.Dev -eq $d } | Select-Object -First 1 }
        if ($right) { $d = $right.Dev; $right = $outs | Where-Object { $_.Dev -eq $d } | Select-Object -First 1 }
        $uw = $outs | Where-Object { $_.Role -eq 'ultrawide' } | Select-Object -First 1
        $lap = $outs | Where-Object { $_.Role -eq 'laptop' } | Select-Object -First 1
    }
}
$script:sidePick = @{}
function Pick-Side($o) {
    # best mode the driver accepts for a side monitor right now: 1920x1080 if the link has room for it,
    # otherwise the next smaller one that passes the driver's own test (the dock link is shared)
    if ($script:sidePick.ContainsKey($o.Dev)) { return $script:sidePick[$o.Dev] }
    $pick = [pscustomobject]@{ W = $o.W; H = $o.H; Hz = $o.Hz }
    foreach ($c in @(@(1920,1080), @(1680,1050), @(1600,900), @(1440,900), @(1280,1024), @(1280,720), @(1024,768), @(800,600))) {
        if ($cap -and ($c[0] -gt $cap[0] -or $c[1] -gt $cap[1])) { continue }
        $hz = Best-Hz $o $c[0] $c[1] @(60); if (-not $hz) { continue }
        if ([DispFix]::Stage($o.Dev, $c[0], $c[1], $hz, $o.X, $o.Y, $false, $true) -eq 0) { $pick = [pscustomobject]@{ W = $c[0]; H = $c[1]; Hz = $hz }; break }
    }
    if ($pick.W -ne 1920 -and -not ($cap -and $pick.W -eq $cap[0])) { Say ("!  " + ($o.Dev -replace '\\\\\.\\', '') + " ($($o.Code), $($o.Via)): the driver refuses 1920x1080 for it right now; best accepted is $($pick.W)x$($pick.H)@$($pick.Hz).") }
    $script:sidePick[$o.Dev] = $pick
    $pick
}
$uwCandidates = @(Get-UwCandidates $uw)
function Build-Set($uwMode) {
    $set = @()
    if ($uw) {
        $y = [int](($uwMode.H - 1080) / 2)
        $set += [pscustomobject]@{ Dev = $uw.Dev; Code = $uw.Code; W = $uwMode.W; H = $uwMode.H; Hz = $uwMode.Hz; X = 0; Y = 0; Primary = $true }
        $lx = 0
        if ($left)  { $m = Pick-Side $left;  $set += [pscustomobject]@{ Dev = $left.Dev;  Code = $left.Code;  W = $m.W; H = $m.H; Hz = $m.Hz; X = -$m.W; Y = [int](($uwMode.H - $m.H) / 2); Primary = $false }; $lx = -$m.W }
        if ($right) { $m = Pick-Side $right; $set += [pscustomobject]@{ Dev = $right.Dev; Code = $right.Code; W = $m.W; H = $m.H; Hz = $m.Hz; X = $uwMode.W; Y = [int](($uwMode.H - $m.H) / 2); Primary = $false } }
        if ($lap -and -not $NoLaptop) { $set += [pscustomobject]@{ Dev = $lap.Dev; Code = $lap.Code; W = $lap.W; H = $lap.H; Hz = $lap.Hz; X = $lx - $lap.W; Y = $y; Primary = $false } }
    } else {
        # no ultrawide: leave the arrangement alone, only give the Dells their own resolution
        foreach ($o in $outs) {
            if ($o.Role -eq 'dell') { $h = Best-Hz $o 1920 1080 @(60); if ($h) { $set += [pscustomobject]@{ Dev = $o.Dev; Code = $o.Code; W = 1920; H = 1080; Hz = $h; X = $o.X; Y = $o.Y; Primary = ($o.X -eq 0 -and $o.Y -eq 0) }; continue } }
            $set += [pscustomobject]@{ Dev = $o.Dev; Code = $o.Code; W = $o.W; H = $o.H; Hz = $o.Hz; X = $o.X; Y = $o.Y; Primary = ($o.X -eq 0 -and $o.Y -eq 0) }
        }
    }
    $set
}
if ($uw -and -not $uwCandidates.Count) { Say 'The ultrawide offers none of the expected modes - nothing changed.'; exit 2 }
if (-not $uw) { $uwCandidates = @($null) }

if ($WhatIf) {
    $set = Build-Set $uwCandidates[0]
    Say 'WhatIf - would set (nothing is changed):'
    foreach ($s in $set) { $t = [DispFix]::Stage($s.Dev, $s.W, $s.H, $s.Hz, $s.X, $s.Y, $false, $true); Say ('   {0,-13} {1,-9} {2}x{3}@{4} at {5},{6}{7}   driver test: {8}' -f ($s.Dev -replace '\\\\\.\\', ''), $s.Code, $s.W, $s.H, $s.Hz, $s.X, $s.Y, $(if ($s.Primary) { '  MAIN' } else { '' }), $(if ($t -eq 0) { 'accepted' } else { "refused ($t)" })) }
    if ($uwCandidates.Count -gt 1) { Say ('   ultrawide fallbacks if the combination is refused: ' + (($uwCandidates | Select-Object -Skip 1 | ForEach-Object { "$($_.W)x$($_.H)@$($_.Hz)" }) -join ', ')) }
    exit 0
}

# ---------- 4. apply, with fallbacks for the ultrawide ----------
$prev = $prev0
$prev | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
$ok = $false; $applied = $null
$detach = ''; if ($NoLaptop -and $lap -and $uw) { $detach = $lap.Dev }
foreach ($cand in $uwCandidates) {
    $set = Build-Set $cand
    $label = if ($cand) { "apply with ultrawide $($cand.W)x$($cand.H)@$($cand.Hz)" } else { 'apply' }
    if (Apply-Set $set $label $detach) { $ok = $true; $applied = $cand; break }
}
if ($ok -and $detach) {
    # With the laptop panel off the graphics card has a free output again and may now offer the ultrawide
    # more than before - look again and take the better mode if there is one.
    Start-Sleep -Seconds 5
    $outs = @(Get-Outputs)
    $uw2 = $outs | Where-Object { $_.Role -eq 'ultrawide' } | Select-Object -First 1
    if ($uw2) {
        $uw = $uw2
        $c2 = @(Get-UwCandidates $uw)
        Say ('ultrawide offered now: ' + (($c2 | ForEach-Object { "$($_.W)x$($_.H)@$($_.Hz)" }) -join ', '))
        if ($c2.Count -and ($c2[0].W * $c2[0].H) -gt ($applied.W * $applied.H)) {
            foreach ($cand in $c2) { if (Apply-Set (Build-Set $cand) "second pass with ultrawide $($cand.W)x$($cand.H)@$($cand.Hz)") { break } }
        }
    }
}
Start-Sleep -Seconds 3
Say 'after applying:'; foreach ($o in @(Get-Outputs)) { Say ('   ' + (Describe $o)) }
if (-not $ok) { Say 'The driver refused every combination; restoring the previous settings.'; Restore-Previous; exit 3 }

# ---------- 5. keep or go back ----------
Close-Busy
Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
# The question is shown on EVERY screen that is part of the desktop right now (a switched-off laptop panel is
# not among them, so no window can land there); a click on any copy answers for all.
$script:answer = ''
$forms = @(); $labels = @()
foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
    $w = [Math]::Min(560, $scr.Bounds.Width - 20); $h = 220
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Monitor settings'; $form.TopMost = $true; $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.ControlBox = $false
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.Location = New-Object System.Drawing.Point(($scr.Bounds.X + [int](($scr.Bounds.Width - $w) / 2)), ($scr.Bounds.Y + [int](($scr.Bounds.Height - $h) / 2)))
    $lbl = New-Object System.Windows.Forms.Label; $lbl.SetBounds(20, 20, ($w - 50), 70); $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 12); $form.Controls.Add($lbl); $labels += $lbl
    $bw = [int](($w - 90) / 2)
    $keep = New-Object System.Windows.Forms.Button; $keep.Text = 'Megtartom'; $keep.SetBounds(30, 110, $bw, 50); $keep.Add_Click({ $script:answer = 'keep' }); $form.Controls.Add($keep)
    $back = New-Object System.Windows.Forms.Button; $back.Text = 'Vissza az elozore'; $back.SetBounds((45 + $bw), 110, $bw, 50); $back.Add_Click({ $script:answer = 'back' }); $form.Controls.Add($back)
    $form.Show(); $forms += $form
}
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not $script:answer -and $sw.Elapsed.TotalSeconds -lt $KeepSeconds) {
    $secLeft = [int]($KeepSeconds - $sw.Elapsed.TotalSeconds)
    foreach ($l in $labels) { $l.Text = "Jo a kep mindegyik monitoron?`nHa nem valaszolsz, $secLeft mp mulva visszaall az elozo beallitas." }
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
}
foreach ($f in $forms) { $f.Close(); $f.Dispose() }
if ($script:answer -eq 'keep') { Say 'kept.' } else { Say 'not confirmed - going back to the previous settings'; Restore-Previous }
