<#
probe-dell.ps1 - tries to force a picture onto the Dell that Windows sees but that stays dark.

Target: the Dell P2714H that is fed over DVI from the dock (EDID code DELD05F, connection "dock").
What it does, about 50 seconds in total, nothing is saved permanently:
  1. Asks the monitor over its control channel (DDC/CI) which input it shows; if it is not DVI, switches the
     monitor to its DVI input from the PC.
  2. Steps that one display through smaller and smaller signals (1920x1080 -> ... -> 800x600), 6 s each, with a
     white full-screen window on it that names the step. After each step it asks the monitor which refresh rate
     it measures on its input - that tells whether the signal really arrives.
  3. Puts the display back to the mode it had.
Watch the dark Dell: if a white screen with text appears at some step, that step's signal gets through.
#>
param([string]$Code = 'DELD05F', [int]$StepSeconds = 6)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $here 'state\probe-dell.log'
if (-not (Test-Path (Split-Path $logFile))) { New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null }
function Say($t) { $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $t; Write-Host $line; Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 }

Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class Probe {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string desc; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct MONITORINFOEX { public int cb; public RECT rc; public RECT work; public int flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dev; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString; public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE { [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName; public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields; public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput; public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName; public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency, r1, r2, r3, r4, r5, r6, r7, r8; }
  delegate bool EnumProc(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumProc cb, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX mi);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE d, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE m, IntPtr hwnd, uint flags, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="ChangeDisplaySettingsEx")] static extern int ChangeDisplaySettingsExNull(string dev, IntPtr m, IntPtr hwnd, uint flags, IntPtr lParam);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll", CharSet=CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] arr);
  [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
  [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] arr);

  // DeviceName|monitorCode for every output on the desktop
  public static string[] Outputs() {
    var res = new List<string>();
    for (uint i = 0; i < 32; i++) { DISPLAY_DEVICE d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE)); if (!EnumDisplayDevices(null, i, ref d, 0)) break; if ((d.StateFlags & 1) == 0) continue;
      DISPLAY_DEVICE m = new DISPLAY_DEVICE(); m.cb = d.cb; string code = ""; if (EnumDisplayDevices(d.DeviceName, 0, ref m, 0) && m.DeviceID != null) { string[] p = m.DeviceID.Split('\\'); if (p.Length > 1) code = p[1]; }
      DISPLAY_DEVICE f = new DISPLAY_DEVICE(); f.cb = d.cb; string path = ""; if (EnumDisplayDevices(d.DeviceName, 0, ref f, 1) && f.DeviceID != null) path = f.DeviceID;
      res.Add(d.DeviceName + "|" + code + "|" + path); }
    return res.ToArray(); }
  // -1 when the monitor does not answer
  public static long Vcp(string dev, byte code, bool set, uint value) {
    long result = -1;
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr data) {
      MONITORINFOEX mi = new MONITORINFOEX(); mi.cb = Marshal.SizeOf(typeof(MONITORINFOEX)); GetMonitorInfo(hMon, ref mi);
      if (mi.dev != dev) return true;
      uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return false;
      var arr = new PHYSICAL_MONITOR[n]; if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return false;
      if (set) { result = SetVCPFeature(arr[0].h, code, value) ? 1 : -1; }
      else { uint t, cur, max; if (GetVCPFeatureAndVCPFeatureReply(arr[0].h, code, out t, out cur, out max)) result = cur; }
      DestroyPhysicalMonitors(n, arr); return false; }, IntPtr.Zero);
    return result; }
  public static string[] Modes(string dev) { var seen = new HashSet<string>(); var res = new List<string>(); for (int k = 0; ; k++) { DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); if (!EnumDisplaySettings(dev, k, ref m)) break; string s = m.dmPelsWidth + "|" + m.dmPelsHeight + "|" + m.dmDisplayFrequency; if (seen.Add(s)) res.Add(s); } return res.ToArray(); }
  public static string Current(string dev) { DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); if (!EnumDisplaySettings(dev, -1, ref m)) return ""; return m.dmPelsWidth + "|" + m.dmPelsHeight + "|" + m.dmDisplayFrequency; }
  // temporary change of one display (not written to the registry)
  public static int SetTemp(string dev, int w, int h, int hz) { DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); if (!EnumDisplaySettings(dev, -1, ref m)) return -99; m.dmPelsWidth = w; m.dmPelsHeight = h; m.dmDisplayFrequency = hz; m.dmFields = 0x80000 | 0x100000 | 0x400000; return ChangeDisplaySettingsEx(dev, ref m, IntPtr.Zero, 0, IntPtr.Zero); }
  // back to what is stored for this display
  public static int Restore(string dev) { return ChangeDisplaySettingsExNull(dev, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing

# ---- find the target: code DELD05F on the dock ----
$conn = @{}
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue | ForEach-Object { $conn[((($_.InstanceName -replace '_\d+$', '') -replace '\\', '#').ToUpper())] = [int]$_.VideoOutputTechnology }
$target = $null
foreach ($line in [Probe]::Outputs()) {
    $p = $line -split '\|', 3; if ($p[1] -ne $Code) { continue }
    $via = 0; foreach ($k in $conn.Keys) { if (([string]$p[2]).ToUpper().Contains($k)) { $via = $conn[$k] } }
    if ($via -eq 10 -or -not $target) { $target = $p[0] }
}
if (-not $target) { Say "No display with code $Code is part of the desktop - nothing to probe."; exit 1 }
$orig = [Probe]::Current($target)
function Ddc-State { 'input=' + [Probe]::Vcp($target, 0x60, $false, 0) + ' power=' + [Probe]::Vcp($target, 0xD6, $false, 0) + ' measuredV=' + [Probe]::Vcp($target, 0xAE, $false, 0) + ' measuredH=' + [Probe]::Vcp($target, 0xAC, $false, 0) }
Say ("target: " + ($target -replace '\\\\\.\\', '') + "  current mode " + ($orig -replace '\|', 'x' -replace 'x(\d+)$', '@$1') + "   monitor says: " + (Ddc-State))

# ---- 1. make the monitor look at its DVI input (VCP 0x60: 3 = DVI-1) ----
$inp = [Probe]::Vcp($target, 0x60, $false, 0)
if ($inp -ne 3) {
    $r = [Probe]::Vcp($target, 0x60, $true, 3)
    Start-Sleep -Seconds 5
    Say ("input was $inp - told the monitor to switch to DVI (result $r); monitor now says: " + (Ddc-State))
} else { Say 'monitor already reports its DVI input as selected' }

# ---- 2. step through signals ----
$offered = @([Probe]::Modes($target))
$steps = @('1920|1080|60', '1680|1050|60', '1600|900|60', '1280|1024|60', '1280|720|60', '1024|768|60', '800|600|60') | Where-Object { $offered -contains $_ }
foreach ($s in $steps) {
    $q = $s -split '\|'; $name = "$($q[0])x$($q[1]) @ $($q[2]) Hz"
    $rc = [Probe]::SetTemp($target, [int]$q[0], [int]$q[1], [int]$q[2])
    Start-Sleep -Milliseconds 1500
    $scr = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $target } | Select-Object -First 1
    $form = $null
    if ($scr) {
        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.TopMost = $true; $form.ShowInTaskbar = $false; $form.BackColor = [System.Drawing.Color]::White
        $form.Bounds = $scr.Bounds
        $l = New-Object System.Windows.Forms.Label; $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.Font = New-Object System.Drawing.Font('Segoe UI', 48, [System.Drawing.FontStyle]::Bold); $l.Text = "LATSZIK?`n$name"; $form.Controls.Add($l)
        $form.Show()
    }
    $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $StepSeconds) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    Say ("step {0,-20} driver result {1}   monitor says: {2}" -f $name, $rc, (Ddc-State))
    if ($form) { $form.Close(); $form.Dispose() }
}

# ---- 3. back to the stored mode ----
$rc = [Probe]::Restore($target); Start-Sleep -Seconds 2
Say ("restored (result $rc): " + ([Probe]::Current($target) -replace '\|', 'x' -replace 'x(\d+)$', '@$1') + "   monitor says: " + (Ddc-State))
