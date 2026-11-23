<#
linkstate.ps1 - READ-ONLY snapshot of every display link as Windows + the NVIDIA driver see it.
Run after every re-plug:
  powershell -NoProfile -ExecutionPolicy Bypass -File diag\linkstate.ps1
Output: console + appended to linkstate-history.log (same folder), each block timestamped.
-Edid also prints the registry EDID inventory (raw EDIDs Windows has stored per monitor instance).
#>
param([switch]$Edid, [switch]$NoLog)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not ('LinkProbe' -as [type])) { Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath (Join-Path $here 'LinkProbe.cs')) }
$out = New-Object System.Collections.Generic.List[string]
$out.Add("===== linkstate " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') + " =====")
foreach ($l in [LinkProbe]::DisplayConfigReport()) { $out.Add($l) }
$gdi = @(Add-Type -AssemblyName System.Windows.Forms -PassThru | Out-Null; [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName })
foreach ($l in [LinkProbe]::NvReport([string[]]$gdi)) { $out.Add($l) }
# WMI view (monitor-reported connection type, active flag)
try {
  $cp = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop
  $ids = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
  foreach ($c in $cp) {
    $id = $ids | Where-Object { $_.InstanceName -eq $c.InstanceName }
    $out.Add(("WMI {0} tech={1} active={2}" -f ($c.InstanceName -replace '\\[^\\]*$',''), [LinkProbe]::Tech([uint32]$c.VideoOutputTechnology), $(if ($id) { $id.Active } else { '?' })))
  }
} catch { $out.Add("WMI: " + $_.Exception.Message) }
# Dock USB side: SuperSpeed hub present => Type-C pin assignment with only 2 DP lanes (USB3 shares the cable)
$dockUsb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_214B&PID_7250|VID_05E3&PID_0625|VID_2109&PID_0102|VID_0B95&PID_1790|VID_0000&PID_0001' })
foreach ($d in $dockUsb) { $la = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_LastArrivalDate -ErrorAction SilentlyContinue).Data; $out.Add(("USB {0,-6} {1} | {2} | arrived {3}" -f $d.Status, $d.FriendlyName, $d.InstanceId, $la)) }
$ss = @($dockUsb | Where-Object { $_.InstanceId -match 'VID_05E3&PID_0625' }).Count
$out.Add("DOCK USB3 (SuperSpeed hub 05E3:0625) present: " + $(if ($ss) { 'YES -> expect 2 DP lanes' } else { 'no -> USB2-only (4-lane DP possible) or dock absent' }))
if ($Edid) {
  Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY' -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($inst in (Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue)) {
      $dp = Join-Path $inst.PSPath 'Device Parameters'
      $e = (Get-ItemProperty -LiteralPath $dp -Name EDID -ErrorAction SilentlyContinue).EDID
      $present = $null -ne (Get-PnpDevice -InstanceId ("DISPLAY\" + $_.PSChildName + "\" + $inst.PSChildName) -PresentOnly -ErrorAction SilentlyContinue)
      if ($e) { $out.Add(("REG-EDID DISPLAY\{0}\{1} present={2} len={3}: {4}" -f $_.PSChildName, $inst.PSChildName, $present, $e.Length, [LinkProbe]::EdidSummary([byte[]]$e))) }
    }
  }
}
$out | ForEach-Object { Write-Output $_ }
if (-not $NoLog) { Add-Content -LiteralPath (Join-Path $here 'linkstate-history.log') -Value $out -Encoding UTF8 }
