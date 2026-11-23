# x4cockpit3 - Win32 interop: monitor enumeration (read-only, incl. EDID from the registry) and window style/position.
# Only documented user32 calls. Nothing here changes display settings.

if (-not ('X4Cockpit3.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace X4Cockpit3 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE { public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  // Children = the monitor devices EnumDisplayDevices lists under this display, one "flags<TAB>device path" per entry.
  // QdcPath / QdcName = monitorDevicePath / monitorFriendlyDeviceName of the ACTIVE QueryDisplayConfig path whose
  // source is this display (the authoritative display -> monitor mapping). Interface is chosen in PowerShell.
  public class Mon { public string Device; public int X, Y, W, H; public bool Primary; public string Interface; public int Hz;
    public List<string> Children = new List<string>(); public string QdcPath = ""; public string QdcName = ""; public int QdcTech = -1; }
  public static class Native {
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, byte[] paths, ref uint numModes, byte[] modes, IntPtr topologyId);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
    static string WStr(byte[] b, int off, int bytes) {
      var s = Encoding.Unicode.GetString(b, off, bytes); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s; }
    // GDI device name (\\.\DISPLAYn) -> { monitorDevicePath, friendly name, output technology } for every active path.
    // Read-only (QDC_ONLY_ACTIVE_PATHS). Layouts: DISPLAYCONFIG_PATH_INFO 72 bytes, MODE_INFO 64 bytes,
    // SOURCE_DEVICE_NAME 84 bytes (type 1), TARGET_DEVICE_NAME 420 bytes (type 2).
    public static Dictionary<string, string[]> DisplayConfigTargets() {
      var map = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
      uint np, nm;
      if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0 || np == 0) return map;
      var paths = new byte[np * 72]; var modes = new byte[nm * 64];
      if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return map;
      for (int i = 0; i < np; i++) {
        int o = i * 72;
        if ((BitConverter.ToUInt32(paths, o + 68) & 1) == 0) continue;            // DISPLAYCONFIG_PATH_ACTIVE
        var src = new byte[84];
        BitConverter.GetBytes(1).CopyTo(src, 0); BitConverter.GetBytes(84).CopyTo(src, 4);
        Array.Copy(paths, o + 0, src, 8, 12);                                       // adapterId (8) + source id (4)
        if (DisplayConfigGetDeviceInfo(src) != 0) continue;
        string gdi = WStr(src, 20, 64);
        var tgt = new byte[420];
        BitConverter.GetBytes(2).CopyTo(tgt, 0); BitConverter.GetBytes(420).CopyTo(tgt, 4);
        Array.Copy(paths, o + 20, tgt, 8, 12);                                      // target adapterId + target id
        if (DisplayConfigGetDeviceInfo(tgt) != 0) continue;
        if (!map.ContainsKey(gdi))                                                  // clone mode: the first target wins
          map[gdi] = new string[] { WStr(tgt, 164, 256), WStr(tgt, 36, 128), BitConverter.ToInt32(tgt, 24).ToString() };
      }
      return map;
    }
    delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr data);
    delegate bool WndEnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr hMon, ref MONITORINFOEX mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevicesW(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll")] static extern bool EnumWindows(WndEnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int idx);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowLongPtrW(IntPtr h, int idx, IntPtr v);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    public static List<Mon> Monitors() {
      var list = new List<Mon>();
      Dictionary<string, string[]> qdc;
      try { qdc = DisplayConfigTargets(); } catch { qdc = new Dictionary<string, string[]>(); }
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, dc, r, d) => {
        var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (GetMonitorInfoW(h, ref mi)) {
          var m = new Mon { Device = mi.szDevice, X = mi.rcMonitor.Left, Y = mi.rcMonitor.Top,
            W = mi.rcMonitor.Right - mi.rcMonitor.Left, H = mi.rcMonitor.Bottom - mi.rcMonitor.Top,
            Primary = (mi.dwFlags & 1) != 0 };
          // Every monitor device listed under this display (index 0 is NOT necessarily the one showing it: an
          // inactive panel can be listed first under every display - seen 2026-11-23 with the laptop panel off).
          for (uint i = 0; i < 16; i++) {
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevicesW(mi.szDevice, i, ref dd, 1)) break;              // EDD_GET_DEVICE_INTERFACE_NAME
            m.Children.Add(dd.StateFlags + "\t" + dd.DeviceID);
          }
          string[] t;
          if (qdc.TryGetValue(mi.szDevice, out t)) { m.QdcPath = t[0]; m.QdcName = t[1]; int tech; if (int.TryParse(t[2], out tech)) m.QdcTech = tech; }
          var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
          if (EnumDisplaySettingsW(mi.szDevice, -1, ref dm)) m.Hz = dm.dmDisplayFrequency; // ENUM_CURRENT_SETTINGS
          list.Add(m);
        }
        return true; }, IntPtr.Zero);
      return list;
    }
    // visible top-level windows as "hwnd<TAB>pid<TAB>title"
    public static List<string> VisibleWindows() {
      var r = new List<string>();
      EnumWindows((h, l) => {
        if (IsWindowVisible(h)) { var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512); uint p; GetWindowThreadProcessId(h, out p);
          r.Add(h.ToInt64() + "\t" + p + "\t" + sb); }
        return true; }, IntPtr.Zero);
      return r;
    }
  }
}
'@
}

# Physical pixel coordinates even when Windows scaling is not 100 % (PER_MONITOR_AWARE_V2 = -4).
try { [void][X4Cockpit3.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }

$script:GWL_STYLE = -16; $script:GWL_EXSTYLE = -20
$script:STYLE_STRIP = 0x00C00000 -bor 0x00040000 -bor 0x00080000 -bor 0x00020000 -bor 0x00010000   # CAPTION|THICKFRAME|SYSMENU|MINIMIZEBOX|MAXIMIZEBOX
$script:EXSTYLE_STRIP = 0x00000001 -bor 0x00000100 -bor 0x00000200 -bor 0x00020000                  # DLGMODALFRAME|WINDOWEDGE|CLIENTEDGE|STATICEDGE
$script:WS_POPUP = [int64]0x80000000
$script:SWP_NOZORDER = 0x0004; $script:SWP_NOACTIVATE = 0x0010; $script:SWP_FRAMECHANGED = 0x0020; $script:SWP_NOOWNERZORDER = 0x0200

function Get-EdidInfo([string]$Interface) {
  # \\?\DISPLAY#DELD05F#5&acf3954&2&UID4352#{guid} -> HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\DELD05F\5&...\Device Parameters\EDID (read-only)
  if (-not $Interface) { return $null }
  $parts = $Interface -split '#'
  if ($parts.Count -lt 3) { return $null }
  $info = [pscustomobject]@{ Code = $parts[1]; Name = ''; WidthMm = 0; HeightMm = 0 }
  $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$($parts[1])\$($parts[2])\Device Parameters"
  try { $e = [byte[]](Get-ItemProperty -LiteralPath $key -Name EDID -ErrorAction Stop).EDID } catch { return $info }
  if (-not $e -or $e.Length -lt 128) { return $info }
  $b = 54   # first detailed timing descriptor: image size in mm
  $info.WidthMm = [int]$e[$b + 12] + (([int]$e[$b + 14] -shr 4) * 256)
  $info.HeightMm = [int]$e[$b + 13] + (([int]$e[$b + 14] -band 15) * 256)
  foreach ($d in 54, 72, 90, 108) {
    if ($e[$d] -eq 0 -and $e[$d + 1] -eq 0 -and $e[$d + 3] -eq 0xFC) {   # monitor name descriptor
      $chars = @(); for ($i = $d + 5; $i -lt $d + 18; $i++) { if ($e[$i] -eq 0x0A) { break }; $chars += [char]$e[$i] }
      $info.Name = (-join $chars).Trim()
    }
  }
  return $info
}

function Select-MonitorInterface {
  # Which monitor device shows a display (\\.\DISPLAYn)? Pure function (tested with today's real data).
  #   1. the monitorDevicePath of the active QueryDisplayConfig path whose source is that display (authoritative);
  #   2. else the first EnumDisplayDevices child with DISPLAY_DEVICE_ACTIVE (0x1) - NOT simply child 0: an inactive
  #      monitor (flags 0x2, e.g. a disabled laptop panel) can be listed first under every display;
  #   3. else the first child at all (old behaviour, last resort).
  # $Children: objects with Flags (int) and Id (device interface path). Returns { Path; Source = qdc|active|first|none }.
  param([string]$QdcPath, $Children)
  if ($QdcPath -and $QdcPath -match '^\\\\\?\\DISPLAY#') { return [pscustomobject]@{ Path = $QdcPath; Source = 'qdc' } }
  $kids = @($Children | Where-Object { $_ -and $_.Id })
  $a = @($kids | Where-Object { ([int]$_.Flags -band 1) -ne 0 }) | Select-Object -First 1
  if ($a) { return [pscustomobject]@{ Path = $a.Id; Source = 'active' } }
  if ($kids.Count -gt 0) { return [pscustomobject]@{ Path = $kids[0].Id; Source = 'first' } }
  return [pscustomobject]@{ Path = ''; Source = 'none' }
}

function Get-LiveMonitors {
  $out = @()
  foreach ($m in [X4Cockpit3.Native]::Monitors()) {
    $kids = @($m.Children | ForEach-Object { $a = $_ -split "`t", 2; [pscustomobject]@{ Flags = [int]$a[0]; Id = $a[1] } })
    $sel = Select-MonitorInterface -QdcPath $m.QdcPath -Children $kids
    $edid = Get-EdidInfo $sel.Path
    $code = '?'; $name = ''; $wmm = 0; $hmm = 0
    if ($edid) { $code = $edid.Code; $name = $edid.Name; $wmm = $edid.WidthMm; $hmm = $edid.HeightMm }
    if (-not $name -and $m.QdcName) { $name = $m.QdcName }   # the driver's friendly name (also from the EDID)
    $pitch = 0.0
    if ($wmm -gt 0) { $pitch = [Math]::Round($wmm / [double]$m.W, 4) }
    $out += [pscustomobject]@{
      Device = $m.Device; Name = $name; Code = $code; Primary = $m.Primary
      X = $m.X; Y = $m.Y; W = $m.W; H = $m.H; Hz = $m.Hz
      WidthMm = $wmm; HeightMm = $hmm; PitchMm = $pitch
      MonitorPath = $sel.Path; PathSource = $sel.Source
    }
  }
  return $out
}

function Read-MonitorsJson([string]$Path) {
  # Synthetic topology for tests / what-if: a JSON array of monitor objects (Device, Name, Code, X, Y, W, H, Primary, WidthMm, HeightMm, Hz).
  $out = @()
  $arr = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json   # PS 5.1 emits a JSON array as ONE object: enumerate it here
  foreach ($j in $arr) {
    $pitch = 0.0
    if ($j.WidthMm -gt 0) { $pitch = [Math]::Round($j.WidthMm / [double]$j.W, 4) }
    $out += [pscustomobject]@{
      Device = [string]$j.Device; Name = [string]$j.Name; Code = [string]$j.Code; Primary = [bool]$j.Primary
      X = [int]$j.X; Y = [int]$j.Y; W = [int]$j.W; H = [int]$j.H; Hz = [int]$j.Hz
      WidthMm = [int]$j.WidthMm; HeightMm = [int]$j.HeightMm; PitchMm = $pitch
    }
  }
  return $out
}

function Find-WindowsByTitlePrefix([string]$Prefix) {
  $res = @()
  foreach ($line in [X4Cockpit3.Native]::VisibleWindows()) {
    $a = $line -split "`t", 3
    if ($a[2] -and $a[2].StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
      $res += [pscustomobject]@{ Hwnd = [int64]$a[0]; Pid = [int]$a[1]; Title = $a[2] }
    }
  }
  return $res
}

function ConvertTo-Hwnd([string]$Handle) {
  if ($Handle -match '^0x') { return [IntPtr]([Convert]::ToInt64($Handle.Substring(2), 16)) }
  return [IntPtr]([int64]$Handle)
}

function Get-WinInfo([IntPtr]$h) {
  $r = New-Object X4Cockpit3.RECT; $c = New-Object X4Cockpit3.RECT; $pt = New-Object X4Cockpit3.POINT
  [void][X4Cockpit3.Native]::GetWindowRect($h, [ref]$r); [void][X4Cockpit3.Native]::GetClientRect($h, [ref]$c)
  [void][X4Cockpit3.Native]::ClientToScreen($h, [ref]$pt)
  return [pscustomobject]@{
    Style = [int64][X4Cockpit3.Native]::GetWindowLongPtrW($h, $script:GWL_STYLE)
    ExStyle = [int64][X4Cockpit3.Native]::GetWindowLongPtrW($h, $script:GWL_EXSTYLE)
    X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top
    ClientX = $pt.X; ClientY = $pt.Y; ClientW = $c.Right; ClientH = $c.Bottom
    Iconic = [X4Cockpit3.Native]::IsIconic($h); Zoomed = [X4Cockpit3.Native]::IsZoomed($h)
  }
}

function Get-WindowStatePath([string]$StateDir, [IntPtr]$h) { return (Join-Path $StateDir ('window-{0}.json' -f [int64]$h)) }

function Set-SpanWindow {
  # Borderless + exact client rectangle. Saves the FIRST original style/rect per window (for -Restore).
  param([IntPtr]$Hwnd, $Rect, $Mons, [string]$StateDir, [switch]$Popup, [switch]$NoActivate, [switch]$ZBottom, [switch]$Force)
  if (-not [X4Cockpit3.Native]::IsWindow($Hwnd)) { throw "not a window: $Hwnd" }
  $before = Get-WinInfo $Hwnd
  if ($before.Iconic -and -not $Force) { throw 'the window is minimised (restore it first, or use -Force)' }
  if ($before.Iconic -or $before.Zoomed) { [void][X4Cockpit3.Native]::ShowWindow($Hwnd, 9); $before = Get-WinInfo $Hwnd }   # SW_RESTORE
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
  $sp = Get-WindowStatePath $StateDir $Hwnd
  if (-not (Test-Path -LiteralPath $sp)) { $before | ConvertTo-Json | Set-Content -LiteralPath $sp -Encoding UTF8 }
  $msgs = @()
  # Measured (2026-11-14): without WS_POPUP Windows caps a window at about virtual desktop + frame; with WS_POPUP
  # 16384x2160 went through. So a window larger than the virtual desktop needs WS_POPUP.
  $vx = ($Mons | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
  $vr = ($Mons | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
  $vy = ($Mons | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
  $vb = ($Mons | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
  $usePopup = [bool]$Popup
  if (-not $usePopup -and ($Rect.W -gt ($vr - $vx) -or $Rect.H -gt ($vb - $vy))) { $usePopup = $true; $msgs += 'window is larger than the virtual desktop -> WS_POPUP style added' }
  $newStyle = $before.Style -band (-bnot [int64]$script:STYLE_STRIP)
  if ($usePopup) { $newStyle = $newStyle -bor $script:WS_POPUP }
  $newEx = $before.ExStyle -band (-bnot [int64]$script:EXSTYLE_STRIP)
  [void][X4Cockpit3.Native]::SetWindowLongPtrW($Hwnd, $script:GWL_STYLE, [IntPtr]$newStyle)
  [void][X4Cockpit3.Native]::SetWindowLongPtrW($Hwnd, $script:GWL_EXSTYLE, [IntPtr]$newEx)
  $flags = $script:SWP_FRAMECHANGED -bor $script:SWP_NOOWNERZORDER
  $after = [IntPtr]::Zero
  if ($ZBottom) { $after = [IntPtr]1 } else { $flags = $flags -bor $script:SWP_NOZORDER }   # HWND_BOTTOM
  if ($NoActivate) { $flags = $flags -bor $script:SWP_NOACTIVATE }
  if (-not [X4Cockpit3.Native]::SetWindowPos($Hwnd, $after, [int]$Rect.X, [int]$Rect.Y, [int]$Rect.W, [int]$Rect.H, $flags)) {
    throw "SetWindowPos failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  $now = Get-WinInfo $Hwnd
  $exact = ($now.ClientW -eq $Rect.W -and $now.ClientH -eq $Rect.H -and $now.ClientX -eq $Rect.X -and $now.ClientY -eq $Rect.Y)
  return [pscustomobject]@{ Before = $before; After = $now; Exact = $exact; StatePath = $sp; Messages = $msgs }
}

function Restore-SpanWindow {
  param([IntPtr]$Hwnd, [string]$StateDir, [switch]$NoActivate, [switch]$WhatIf)
  $sp = Get-WindowStatePath $StateDir $Hwnd
  if (-not (Test-Path -LiteralPath $sp)) { throw "no saved state for this window: $sp" }
  $s = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
  if ($WhatIf) { return [pscustomobject]@{ Saved = $s; After = $null; StatePath = $sp } }
  [void][X4Cockpit3.Native]::SetWindowLongPtrW($Hwnd, $script:GWL_STYLE, [IntPtr][int64]$s.Style)
  [void][X4Cockpit3.Native]::SetWindowLongPtrW($Hwnd, $script:GWL_EXSTYLE, [IntPtr][int64]$s.ExStyle)
  $flags = $script:SWP_FRAMECHANGED -bor $script:SWP_NOOWNERZORDER -bor $script:SWP_NOZORDER
  if ($NoActivate) { $flags = $flags -bor $script:SWP_NOACTIVATE }
  if (-not [X4Cockpit3.Native]::SetWindowPos($Hwnd, [IntPtr]::Zero, [int]$s.X, [int]$s.Y, [int]$s.W, [int]$s.H, $flags)) {
    throw "SetWindowPos failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  Remove-Item -LiteralPath $sp
  return [pscustomobject]@{ Saved = $s; After = (Get-WinInfo $Hwnd); StatePath = $sp }
}
