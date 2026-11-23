<#
X4Switch tests: drive X4Switch.exe through its command line against FAKES only.
  fake game    : the cockpit kit's testtarget.exe (imitates X4's window behaviour; --hidden = fully transparent,
                 click-through, never activated, exits by itself after --seconds), copied as <run>\game\X4.exe
  fake tree    : <run>\game\tools\{x4switch, x4cockpit3, x4companion} = COPIES of the real scripts/binaries, so the
                 real kit state, the real config.xml and the real companion are never used
  fake profile : <run>\profile\4242\config.xml (synthetic)
  monitors     : synthetic layouts (monitorsJson); real starts use a small rectangle (64,64 640x360)
  companion    : a PowerShell TCP stub server on a test port, a stub "browser" (transparent, off-screen, never
                 activated) and a test mutex name - the real watcher, server and window are not seen or touched
Every process started here is stopped by PID at the end (never the real game, a browser or the real server).
Usage: powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 [-WorkDir <dir>] [-Port 8797]
#>
[CmdletBinding()]
param([string]$WorkDir = '', [int]$Port = 8797)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$tools = Split-Path -Parent $root
$kit = Join-Path $tools 'x4cockpit3'
$comp = Join-Path $tools 'x4companion'
$exeSrc = Join-Path $root 'X4Switch.exe'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not $WorkDir) { $WorkDir = Join-Path $here '_work' }
$run = Join-Path $WorkDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:pass = 0; $script:fail = 0; $script:failed = @(); $script:n = 0

function Assert([bool]$Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass++; Write-Host "  PASS $Name" }
  else { $script:fail++; $script:failed += $Name; Write-Host "  FAIL $Name"; if ($Detail) { Write-Host ('       ' + (($Detail.Trim()) -replace "`n", "`n       ")) } }
}
function Wait-Until([scriptblock]$Cond, [int]$Sec = 30) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $Sec) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 250 }
  return [bool](& $Cond)
}
function Test-Port {
  $c = New-Object Net.Sockets.TcpClient
  try { $ar = $c.BeginConnect('127.0.0.1', $Port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne(400)) { $c.EndConnect($ar); $true } else { $false } } catch { $false } finally { $c.Close() }
}
function Lines($f) { if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }).Count } else { 0 } }
function Hash([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function Q([string]$s) { if ($s -match '[\s"]' -or $s -eq '') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }

# ---- safety: never stop the real game, a browser, the real companion server or a real watcher
$realGame = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $tools) 'X4.exe'))
$liveServer = @(netstat -ano | Select-String -Pattern '127\.0\.0\.1:8788\s+\S+\s+LISTENING\s+(\d+)' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
function Stop-Pid([int]$id) {
  if (-not $id -or $id -eq $PID) { return }
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if (-not $p) { return }
  $path = $null; try { $path = $p.Path } catch { }
  $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
  $cl = ''; if ($ci) { $cl = [string]$ci.CommandLine }
  if ($p.ProcessName -match '^(brave|chrome|msedge|firefox)$' -or $liveServer -contains $id -or ($path -and $path -ieq $realGame) -or ($cl -like '*watch_x4.ps1*' -and $cl -notlike "*$run*")) {
    Write-Host "  (refusing to stop protected pid $id $($p.ProcessName))"; return }
  try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { }
}
function Get-Mine { @(Get-CimInstance Win32_Process | Where-Object { ($_.ExecutablePath -and $_.ExecutablePath -like "$run\*") -or ($_.CommandLine -and $_.CommandLine -like "*$run*") }) }
function Stop-Game { Get-Mine | Where-Object { $_.Name -in 'X4.exe', 'launcher.exe' } | ForEach-Object { Stop-Pid ([int]$_.ProcessId) }; [void](Wait-Until { -not (GamePids) } 10) }
function GamePids { @(Get-CimInstance Win32_Process -Filter "Name='X4.exe'" | Where-Object { $_.ExecutablePath -ieq $fakeExe } | ForEach-Object { [int]$_.ProcessId }) }
function Kill-Windows { if (Test-Path -LiteralPath $marker) { Get-Content -LiteralPath $marker | Where-Object { $_ } | ForEach-Object { Stop-Pid ([int](($_ -split '\|')[0])) } } }
function Kill-Servers {
  Get-Mine | Where-Object { $_.CommandLine -like '*stub_server.ps1*' -and $_.Name -ne 'conhost.exe' } | ForEach-Object { Stop-Pid ([int]$_.ProcessId) }
  Get-Mine | Where-Object { $_.CommandLine -like '*stub_server.ps1*' } | ForEach-Object { Stop-Pid ([int]$_.ProcessId) }
  [void](Wait-Until { -not (Test-Port) } 10)
}
function ParentName([int]$id) {
  $c = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
  if (-not $c) { return '' }
  $pp = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.ParentProcessId)" -ErrorAction SilentlyContinue
  if ($pp) { return [string]$pp.Name } return "(gone:$($c.ParentProcessId))"
}

# ---- the manager under test
function X([string[]]$A, [int]$TimeoutSec = 240, [string]$Instance = 'Local\X4SwitchTest') {
  $script:n++
  $out = Join-Path $run ('out-{0:D3}.txt' -f $script:n)
  $all = @($A) + @('--instance', $Instance, '--log-dir', $mgrLogs)
  $p = Start-Process -FilePath $mgr -ArgumentList (($all | ForEach-Object { Q $_ }) -join ' ') -PassThru -NoNewWindow -RedirectStandardOutput $out
  $null = $p.Handle
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { Stop-Pid $p.Id; Write-Host "  (manager timed out: $($A -join ' '))" }
  $p.WaitForExit()
  $txt = ''; if (Test-Path -LiteralPath $out) { $txt = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) }
  $j = $null
  $jl = @($txt -split "`r?`n" | Where-Object { $_ -like '@@X4SWITCH *' }) | Select-Object -Last 1
  if ($jl) { $j = $jl.Substring(11) | ConvertFrom-Json }
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $txt; J = $j }
}
function Set-Mgr([hashtable]$Extra = @{}) {
  $o = [ordered]@{ _comment = 'test settings (must survive a save)'; gameArgs = ''; monitorsJson = $topoOk; cockpitLogDir = $launchLogs
    companionMutex = $testMutex; dashboardWaitSeconds = 20; launchWaitSeconds = 30 }
  foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
  ($o | ConvertTo-Json) | Set-Content -LiteralPath $mgrSettings -Encoding UTF8
}

$job = [IntPtr]::Zero
try {
  if (-not (Test-Path -LiteralPath $exeSrc)) { throw "build first: $exeSrc missing" }
  foreach ($f in 'native\out\launcher.exe', 'native\out\x4c3hook.dll', 'native\out\testtarget.exe') { if (-not (Test-Path -LiteralPath (Join-Path $kit $f))) { throw "cockpit kit binary missing: $f (native\build.cmd)" } }
  if (Test-Port) { throw "test port $Port is already in use - pick another with -Port" }

  # ================================================================== fake tree
  Write-Host "== setup: $run"
  $g = Join-Path $run 'game'; $sw = Join-Path $g 'tools\x4switch'; $kc = Join-Path $g 'tools\x4cockpit3'; $cc = Join-Path $g 'tools\x4companion'
  foreach ($d in $sw, (Join-Path $kc 'lib'), (Join-Path $kc 'native\out'), (Join-Path $cc 'state'), (Join-Path $run 'bin'), (Join-Path $run 'profile\4242'), (Join-Path $run 'launchlogs')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $mgr = Join-Path $sw 'X4Switch.exe'; Copy-Item -LiteralPath $exeSrc -Destination $mgr
  foreach ($f in 'cockpit.ps1', 'cockpit-launch.ps1', 'x4cockpit3.ps1') { Copy-Item -LiteralPath (Join-Path $kit $f) -Destination $kc }
  Copy-Item -Path (Join-Path $kit 'lib\*.ps1') -Destination (Join-Path $kc 'lib')
  foreach ($f in 'launcher.exe', 'x4c3hook.dll') { Copy-Item -LiteralPath (Join-Path $kit "native\out\$f") -Destination (Join-Path $kc 'native\out') }
  $fakeExe = Join-Path $g 'X4.exe'; Copy-Item -LiteralPath (Join-Path $kit 'native\out\testtarget.exe') -Destination $fakeExe
  Copy-Item -LiteralPath (Join-Path $comp 'watch_x4.ps1') -Destination $cc
  $mgrSettings = Join-Path $sw 'settings.json'; $mgrLogs = Join-Path $run 'mgrlogs'; $launchLogs = Join-Path $run 'launchlogs'
  $testMutex = 'Local\X4CompanionWatcherSwitchTest'
  # synthetic profile + kit settings
  $prof = Join-Path $run 'profile\4242'; $cfg = Join-Path $prof 'config.xml'
  [IO.File]::WriteAllText($cfg, "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<root>`r`n  <fullscreen>true</fullscreen>`r`n  <borderless>false</borderless>`r`n  <fov>1.3333</fov>`r`n  <confinemouse>false</confinemouse>`r`n  <res_width>3440</res_width>`r`n  <res_height>1440</res_height>`r`n</root>`r`n")
  $cfgOrig = Hash $cfg
  ([ordered]@{ profileDir = $prof; backupDir = (Join-Path $run 'backups'); companionWindowTitle = 'x4switch-test-no-such-window'; sideMatch = 'DELD05F|P2714H' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $kc 'settings.json') -Encoding UTF8
  $kitState = Join-Path $kc 'state\cockpit-state.json'; $kitFlag = Join-Path $kc 'state\cockpit-active.flag'
  function M($dev, $code, $name, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$prim) { [pscustomobject]@{ Device = "\\.\$dev"; Name = $name; Code = $code; Primary = $prim; X = $x; Y = $y; W = $w; H = $h; Hz = 60; WidthMm = 598; HeightMm = 336 } }
  $topoOk = Join-Path $run 'topo-target.json'
  @((M 'DISPLAY2' 'DELD05F' 'DELL P2714H' -1920 180 1920 1080 $false), (M 'DISPLAY1' 'AUS3438' 'VG34VQL3A' 0 0 3440 1440 $true), (M 'DISPLAY3' 'DELD05E' 'DELL P2714H' 3440 180 1920 1080 $false)) | ConvertTo-Json | Set-Content -LiteralPath $topoOk -Encoding UTF8
  $topoBad = Join-Path $run 'topo-bothleft.json'
  @((M 'DISPLAY2' 'DELD05F' 'DELL P2714H' -3840 126 1920 1080 $false), (M 'DISPLAY3' 'DELD05E' 'DELL P2714H' -1920 126 1920 1080 $false), (M 'DISPLAY1' 'AUS3438' 'VG34VQL3A' 0 0 3440 1440 $true)) | ConvertTo-Json | Set-Content -LiteralPath $topoBad -Encoding UTF8
  # companion stubs
  $starts = Join-Path $run 'starts.txt'; $marker = Join-Path $run 'marker.txt'; $title = 'X4 Companion SWITCHTEST'
  $stubServer = Join-Path $run 'bin\stub_server.ps1'
  Set-Content -LiteralPath $stubServer -Encoding ASCII -Value @'
param([int]$Port, [string]$Starts)
Add-Content -LiteralPath $Starts -Value $PID
$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $l.Start()
while ($true) { $c = $l.AcceptTcpClient(); try { $s = $c.GetStream(); $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.0 200 OK`r`n`r`n<title>stub</title>"); $s.Write($b, 0, $b.Length) } catch { }; $c.Close() }
'@
  $stubWin = Join-Path $run 'bin\stubwin.exe'
  Add-Type -OutputType WindowsApplication -OutputAssembly $stubWin -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.IO; using System.Drawing; using System.Windows.Forms;
public class StubForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80 | 0x20; return p; } } // NOACTIVATE|TOOLWINDOW|TRANSPARENT
}
public static class StubBrowser {
    [STAThread] public static void Main(string[] a) {
        File.AppendAllText(a[0], System.Diagnostics.Process.GetCurrentProcess().Id + "|" + string.Join(" ", a) + Environment.NewLine);
        var f = new StubForm { Text = a[1], FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual,
                               Location = new Point(-32000, -32000), Size = new Size(1, 1), Opacity = 0, ShowInTaskbar = false };
        Application.Run(f);
    }
}
'@
  ([ordered]@{ port = $Port; windowTitle = $title; serverStartTimeoutSec = 20; browserExe = $stubWin; browserArgs = @($marker, $title, '--app={url}')
      serverCommand = @($psExe, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $stubServer, "$Port", $starts); skipWindowFlag = $kitFlag } | ConvertTo-Json) |
    Set-Content -LiteralPath (Join-Path $cc 'state\watcher.json') -Encoding UTF8
  if (-not ('JobRun' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class JobRun {
    [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
    [StructLayout(LayoutKind.Sequential)] struct IO { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IO Io; public UIntPtr a, b, c, d; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SI { public int cb; public string r, d, t; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, i, o, e; }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr hp, ht; public int pid, tid; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, IntPtr env, string dir, ref SI si, out PI pi);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a, string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    public static IntPtr NewJob() { var j = CreateJobObjectW(IntPtr.Zero, null); var i = new EXT(); i.Basic.LimitFlags = 0x2000; SetInformationJobObject(j, 9, ref i, Marshal.SizeOf(typeof(EXT))); return j; }
    public static IntPtr StartInJob(IntPtr job, string cmdline, out int pid) {   // suspended -> into the job -> resumed
        var si = new SI(); si.cb = Marshal.SizeOf(typeof(SI)); PI pi;
        if (!CreateProcessW(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000, IntPtr.Zero, null, ref si, out pi)) throw new System.ComponentModel.Win32Exception();
        if (!AssignProcessToJobObject(job, pi.hp)) throw new System.ComponentModel.Win32Exception();
        ResumeThread(pi.ht); CloseHandle(pi.ht); pid = pi.pid; return pi.hp;
    }
}
'@
  }

  # ================================================================== S: selftest, usage, auto-detection, language
  Write-Host '== S: selftest, usage, settings auto-detection, language'
  $r = X @('--selftest')
  Assert ($r.Code -eq 0 -and $r.Out -match 'selftest: \d+ checks, 0 failed') 'S1 --selftest: all internal checks pass' $r.Out
  $r = X @('--bogus'); $r2 = X @('--mode', 'triple')
  Assert ($r.Code -eq 4 -and $r2.Code -eq 4 -and $r.Out -match 'usage|--mode cockpit\|single') 'S2 unknown option / unknown mode: usage, exit 4' $r.Out
  $r = X @('--status', '--json')
  $uiHu = (Get-UICulture).TwoLetterISOLanguageName -eq 'hu'
  Assert ($r.Code -eq 0 -and $r.J -and $r.J.paths.gameExe -ieq $fakeExe -and $r.J.paths.cockpitDir -ieq $kc -and $r.J.paths.companionDir -ieq $cc) 'S3 no settings.json: game two levels up, kit and companion as siblings' $r.Out
  Assert ($r.J.dashboard.companionInstalled -and $r.J.hook.present -and $r.J.config.mode -eq 'off' -and -not $r.J.game.running -and $r.J.dashboard.port -eq $Port) 'S3 detected: companion (port from its watcher.json), hook files, config OFF, game not running' $r.Out
  Assert ($r.J.language -eq $(if ($uiHu) { 'hu' } else { 'en' })) "S4 no language setting: follows the Windows UI language ($((Get-UICulture).Name))" $r.J.language
  $r = X @('--status', '--lang', 'hu')
  Assert ($r.Out -match 'Játék\s+\[idle\] nem fut' -and $r.Out -match 'Monitorok') 'S4 --lang hu: Hungarian texts' $r.Out
  Set-Mgr @{ language = 'hu' }
  $r = X @('--status'); $r2 = X @('--status', '--lang', 'en')
  Assert ($r.Out -match 'nem fut' -and $r2.Out -match 'not running') 'S4 language from settings.json (hu), --lang en overrides it' ($r.Out + $r2.Out)
  Set-Mgr
  $r = X @('--status', '--json')
  Assert ($r.J.layout.ok -and $r.J.layout.summary -eq 'DELL P2714H | VG34VQL3A | DELL P2714H' -and $r.J.cockpitCard -match 'Ready') 'S5 synthetic target layout: OK, summary Dell | VG34VQL3A | Dell, cockpit card Ready' $r.Out
  $bad = Join-Path $run 'bad-settings.json'; Set-Content -LiteralPath $bad -Value '{ "gameArgs": ' -Encoding ASCII
  $r = X @('--status', '--settings', $bad)
  Assert ($r.Code -eq 0 -and $r.Out -match 'unreadable') 'S6 unreadable settings.json: defaults, reported, still works' $r.Out

  # ================================================================== C: cockpit mode
  Write-Host '== C: cockpit mode'
  $r = X @('--mode', 'cockpit', '--no-start', '--json')
  $c = [IO.File]::ReadAllText($cfg)
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'switched' -and (Test-Path -LiteralPath $kitState) -and (Test-Path -LiteralPath $kitFlag) -and $c -match '<res_width>7280</res_width>' -and $c -match '<fov>0.6667</fov>') 'C1 switch without starting: kit cockpit-on ran (values, state, companion flag)' $r.Out
  Assert (-not (GamePids)) 'C1 nothing started'
  $r = X @('--mode', 'cockpit', '--dry-run', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'whatif' -and $r.Out -match '--rect -1920,0,7280,1440' -and -not (GamePids)) 'C2 --dry-run: the exact launcher command (rect from the layout), nothing started' $r.Out
  $r = X @('--mode', 'single', '--no-start', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'switched' -and (Hash $cfg) -eq $cfgOrig -and -not (Test-Path -LiteralPath $kitFlag) -and -not (Test-Path -LiteralPath $kitState)) 'C3 single, switch without starting: config byte-identical to before, flag and state removed' $r.Out
  Set-Mgr @{ monitorsJson = $topoBad }
  $r = X @('--mode', 'cockpit', '--json')
  Assert ($r.Code -eq 2 -and $r.J.result -eq 'refused-layout' -and $r.Out -match 'RIGHT:' -and (Hash $cfg) -eq $cfgOrig -and -not (Test-Path -LiteralPath $kitState)) 'C4 arrangement mismatch: refused before touching config.xml, problem named' $r.Out
  $r = X @('--check-monitors'); Set-Mgr; $r2 = X @('--check-monitors')
  Assert ($r.Code -eq 2 -and $r2.Code -eq 0 -and $r2.Out -match 'Monitors: DELL P2714H \| VG34VQL3A \| DELL P2714H') 'C5 --check-monitors: mismatch exit 2, target exit 0' ($r.Out + $r2.Out)
  $dll = Join-Path $kc 'native\out\x4c3hook.dll'; Rename-Item -LiteralPath $dll -NewName 'x4c3hook.dll.off'
  $r = X @('--mode', 'cockpit', '--json'); $s1 = X @('--status', '--json')
  Rename-Item -LiteralPath "$dll.off" -NewName 'x4c3hook.dll'
  Assert ($r.Code -eq 2 -and $r.J.result -eq 'refused-hook-missing' -and $r.Out -match 'x4c3hook\.dll' -and (Hash $cfg) -eq $cfgOrig) 'C6 hook DLL missing: refused, file named, config untouched' $r.Out
  Assert (-not $s1.J.hook.present -and $s1.J.cockpitCard -match 'hook') 'C6 status: hook files missing, cockpit card not ready' $s1.Out
  Set-Mgr @{ rect = '1,2,3' }
  $r = X @('--mode', 'cockpit', '--json')
  Assert ($r.Code -eq 2 -and $r.J.result -eq 'refused-rect') 'C7 invalid rectangle override: refused' $r.Out
  # real start through the kit's launcher: small rectangle, hidden fake game
  $tl = Join-Path $run 'target-cockpit.log'
  Set-Mgr @{ rect = '64,64,640,360'; gameArgs = "--hidden --seconds 40 --log `"$tl`"" }
  $r = X @('--mode', 'cockpit', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'active' -and $r.J.hookActive -and $r.J.gamePid -gt 0) 'C8 start: cockpit-on + launcher, hook ACTIVE, game pid reported' $r.Out
  $gp = [int]$r.J.gamePid
  [void](Wait-Until { (Test-Path -LiteralPath $tl) -and ((Get-Content -LiteralPath $tl -Raw) -match 'created hwnd') } 10)
  $tlog = ''; if (Test-Path -LiteralPath $tl) { $tlog = Get-Content -LiteralPath $tl -Raw }
  Assert ((GamePids) -contains $gp -and $tlog -match '--hidden --seconds 40 --log') 'C8 the fake game runs with the configured arguments' $tlog
  $lpar = ParentName $gp; $lp = (Get-CimInstance Win32_Process -Filter "ProcessId=$gp").ParentProcessId; $lppar = ParentName $lp
  Assert ($lpar -eq 'launcher.exe' -and $lppar -match '^WmiPrvSE') "C8 detached: game <- launcher.exe <- $lppar (not this manager)" "$lpar / $lppar"
  $r = X @('--status', '--json')
  Assert ($r.J.game.running -and $r.J.game.startedAs -eq 'cockpit' -and $r.J.config.mode -eq 'on' -and $r.J.cockpitCard -match 'Running' -and $r.J.singleCard -match 'close it') 'C9 status: running, started as cockpit (hook ACTIVE), config ON' $r.Out
  $h = Hash $cfg
  $r = X @('--mode', 'single', '--json'); $r2 = X @('--mode', 'cockpit', '--json'); $r3 = X @('--mode', 'single', '--no-start', '--json')
  Assert ($r.Code -eq 2 -and $r.J.result -eq 'refused-game-running' -and $r2.Code -eq 2 -and $r3.Code -eq 2 -and (Hash $cfg) -eq $h -and @(GamePids).Count -eq 1 -and $r.Out -match "pid $gp") 'C10 game running: every switch/start refused, config untouched, no second game, nothing killed' ($r.Out + $r2.Out)
  Stop-Game
  # fail-safe result from the launcher (contract stub in the copied kit): exit 3 with the reason from the logs
  $cl = Join-Path $kc 'cockpit-launch.ps1'; Copy-Item -LiteralPath $cl -Destination "$cl.real"
  Set-Content -LiteralPath $cl -Encoding ASCII -Value 'param([switch]$Json, [string]$GameArgs, [string]$Rect, [string]$SettingsFile, [string]$MonitorsJson, [string]$LogDir, [int]$WaitSeconds, [switch]$WhatIf)
Write-Host "launcher: pid=4242 hook=NOT active - the game runs as without the launcher"
Write-Host ''@@X4JSON {"tool":"cockpit-launch","result":"failsafe","exit":3,"gamePid":4242,"reason":["hook DLL not found: test"]}''
exit 3'
  $r = X @('--mode', 'cockpit', '--json')
  Move-Item -LiteralPath "$cl.real" -Destination $cl -Force
  Assert ($r.Code -eq 3 -and $r.J.result -eq 'failsafe' -and $r.Out -match 'WITHOUT the window hook' -and $r.Out -match 'hook DLL not found: test') 'C11 launcher fail-safe: exit 3, reason from the logs shown' $r.Out

  # ================================================================== D: single monitor + dashboard
  Write-Host '== D: single monitor + dashboard'
  $tl2 = Join-Path $run 'target-single.log'
  Set-Mgr @{ gameArgs = "--hidden --seconds 60 --log `"$tl2`"" }
  $r = X @('--mode', 'single', '--json')
  $gp = [int]$r.J.gamePid
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'started' -and $gp -gt 0 -and (GamePids) -contains $gp) 'D1 start: game started, pid reported' $r.Out
  Assert ((Hash $cfg) -eq $cfgOrig -and -not (Test-Path -LiteralPath $kitFlag)) 'D1 cockpit-off ran first: config original, flag gone' $r.Out
  Assert ((ParentName $gp) -match '^WmiPrvSE') "D1 detached: the game's parent is $(ParentName $gp), not the manager"
  Assert ((Lines $starts) -eq 1 -and (Lines $marker) -eq 1 -and (Test-Port) -and $r.Out -match 'Dashboard window opened') 'D1 watcher not running: the manager started the server once and opened the window once' $r.Out
  [void](Wait-Until { (Test-Path -LiteralPath $tl2) } 10)
  Assert ((Test-Path -LiteralPath $tl2) -and (Get-Content -LiteralPath $tl2 -Raw) -match '--hidden --seconds 60 --log') 'D1 the configured game arguments reached the game'
  Stop-Game
  $r = X @('--mode', 'single', '--json')
  Assert ($r.Code -eq 0 -and (Lines $starts) -eq 1 -and (Lines $marker) -eq 1 -and $r.Out -match 'already open') 'D2 again with server + window present: no second server, no second window' $r.Out
  Stop-Game
  # a running companion watcher (test mutex) does the dashboard; the manager only waits for it
  Kill-Windows
  $wlog = Join-Path $cc 'logs\watcher.log'
  $wp = Start-Process -FilePath $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $cc 'watch_x4.ps1')`" -GameExe `"$fakeExe`" -MutexName $testMutex -PollSeconds 1" -WindowStyle Hidden -PassThru
  [void](Wait-Until { (Test-Path -LiteralPath $wlog) -and (Select-String -LiteralPath $wlog -SimpleMatch 'watcher start (loop)' -Quiet) } 30)
  $r = X @('--mode', 'single', '--json')
  Assert ($r.Code -eq 0 -and $r.Out -match 'companion watcher is running' -and $r.Out -match 'The dashboard is open') 'D3 watcher running: the manager leaves the dashboard to it and confirms it appeared' $r.Out
  Start-Sleep -Seconds 3
  Assert ((Lines $marker) -eq 2 -and (Lines $starts) -eq 1) 'D3 exactly one new window, no second server (never two windows)' "windows $(Lines $marker), servers $(Lines $starts)"
  Stop-Pid $wp.Id; Stop-Game
  # open dashboard (explicit), dry run and real
  $r = X @('--open-dashboard', '--dry-run', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'whatif' -and $r.Out -match 'window present' -and (Lines $marker) -eq 2) 'D4 --open-dashboard --dry-run: reports, opens nothing' $r.Out
  Kill-Windows
  $r = X @('--open-dashboard', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'open' -and (Lines $marker) -eq 3 -and (Lines $starts) -eq 1) 'D4 --open-dashboard: window opened (game not running), server reused' $r.Out
  # companion not installed: still usable as single monitor without dashboard
  Set-Mgr @{ gameArgs = "--hidden --seconds 20 --log `"$tl2`""; companionDir = (Join-Path $run 'no-companion-here') }
  $r = X @('--mode', 'single', '--json'); $s1 = X @('--status', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'started' -and $r.Out -match 'No dashboard' -and (Lines $marker) -eq 3) 'D5 companion missing: game started, "no dashboard" said, nothing else opened' $r.Out
  Assert (-not $s1.J.dashboard.companionInstalled) 'D5 status: companion not installed'
  Stop-Game
  $r = X @('--mode', 'single', '--dry-run', '--json')
  Assert ($r.Code -eq 0 -and $r.J.result -eq 'whatif' -and $r.Out -match 'Would start: "?' + [regex]::Escape($fakeExe) -and -not (GamePids)) 'D6 single --dry-run: the exact game command, nothing started' $r.Out

  # ================================================================== J: detached starts survive the manager (kill-on-close job)
  Write-Host '== J: detached starts survive the manager'
  Kill-Windows; Kill-Servers
  Set-Mgr @{ gameArgs = "--hidden --seconds 60 --log `"$tl2`"" }
  $job = [JobRun]::NewJob()
  $jp = 0; $hp = [JobRun]::StartInJob($job, "`"$mgr`" --mode single --instance Local\X4SwitchTest --log-dir `"$mgrLogs`"", [ref]$jp)
  $ctlPid = 0; $hc = [JobRun]::StartInJob($job, "`"$psExe`" -NoProfile -Command Start-Sleep 120", [ref]$ctlPid)
  $done = [JobRun]::WaitForSingleObject($hp, 180000) -eq 0
  $code = [uint32]99; [void][JobRun]::GetExitCodeProcess($hp, [ref]$code)
  Assert ($done -and $code -eq 0) "J1 manager inside a kill-on-close job: finished (exit $code)"
  $gpids = @(GamePids); $winPid = 0; if ((Lines $marker) -gt 0) { $winPid = [int]((@(Get-Content -LiteralPath $marker | Where-Object { $_ }))[-1] -split '\|')[0] }
  [JobRun]::CloseHandle($hp) | Out-Null; [JobRun]::CloseHandle($hc) | Out-Null
  [JobRun]::CloseHandle($job) | Out-Null; $job = [IntPtr]::Zero
  Start-Sleep -Seconds 2
  Assert (-not (Get-Process -Id $ctlPid -ErrorAction SilentlyContinue)) 'J1 harness: a plain child in the job was killed when the job closed'
  Assert ($gpids.Count -eq 1 -and (Get-Process -Id $gpids[0] -ErrorAction SilentlyContinue)) 'J1 the game survived the job (manager tree) being killed' "game pids: $($gpids -join ',')"
  Assert ((Test-Port) -and $winPid -and (Get-Process -Id $winPid -ErrorAction SilentlyContinue)) 'J1 the dashboard server and window survived too'
  Stop-Game

  # ================================================================== I/G: single instance, GUI smoke, last choice, logs
  Write-Host '== I/G: single instance, GUI smoke test, last choice, log cap'
  Set-Mgr
  $hold = Join-Path $run 'hold.txt'
  $holder = Start-Process -FilePath $mgr -ArgumentList "--gui-smoke `"$hold`" --hold-ms 15000 --instance Local\X4SwitchTest --log-dir `"$mgrLogs`"" -PassThru
  [void](Wait-Until { (Test-Path -LiteralPath $hold) -and (Get-Item -LiteralPath $hold).Length -gt 0 } 30)
  Start-Sleep -Milliseconds 500
  $r = X @('--mode', 'single', '--no-start', '--json'); $r2 = X @('--status')
  Assert ($r.Code -eq 5 -and $r.J.result -eq 'refused-instance' -and $r2.Code -eq 0) 'I1 second instance: changes refused (exit 5), read-only status still allowed' ($r.Out + $r2.Out)
  [void]$holder.WaitForExit(30000)
  $r = X @('--mode', 'single', '--no-start', '--json')
  Assert ($r.Code -eq 0) 'I1 after the first instance closed: allowed again' $r.Out
  $smoke = Join-Path $run 'smoke.txt'; $bmp = Join-Path $run 'window.bmp'
  $r = X @('--gui-smoke', $smoke, '--render', $bmp, '--smoke-save')
  $st = ''; if (Test-Path -LiteralPath $smoke) { $st = [IO.File]::ReadAllText($smoke, [Text.Encoding]::UTF8) }
  Assert ($r.Code -eq 0 -and $st -match 'visible=0' -and $st -match 'lang=en' -and $st -match 'lang=hu') 'G1 GUI smoke: window created hidden (never shown), dumped in both languages' $st
  $want = @('Cockpit – three monitors', 'Single monitor \+ dashboard', 'Switch mode without starting', 'Open dashboard window', 'Check monitors', 'Open logs folder', 'Refresh',
    'Pilótafülke – három monitor', 'Egy monitor \+ műszerfal', 'Mód váltása indítás nélkül', 'Műszerfal ablak megnyitása', 'Monitorok ellenőrzése', 'Naplómappa megnyitása', 'Frissítés',
    'Start:  Cockpit', 'Indítás:  Pilótafülke')
  $missing = @($want | Where-Object { $st -notmatch $_ })
  Assert ($missing.Count -eq 0) 'G1 every main control text present in English and Hungarian' ($missing -join ', ')
  Assert ($st -match 'class=Edit .*text=' -and ($st -match 'Mentés' -or $st -match 'text=Save') -and ($st -match 'Tallózás' -or $st -match 'Browse')) 'G1 settings window: fields and buttons created' $st
  Assert ($st -match 'right arrow on the cockpit card -> selected single') 'G2 keyboard: right arrow on the cockpit card selects the single card' $st
  $ms = Get-Content -LiteralPath $mgrSettings -Raw | ConvertFrom-Json
  Assert ($ms.lastMode -eq 'single' -and $ms._comment -eq 'test settings (must survive a save)' -and $ms.monitorsJson -eq $topoOk) 'G3 last choice remembered in settings.json; unknown and advanced keys kept' (Get-Content -LiteralPath $mgrSettings -Raw)
  Assert ($st -match 'render: ok' -and (Test-Path -LiteralPath $bmp) -and (Get-Item -LiteralPath $bmp).Length -gt 100000) 'G4 off-screen render of the window written (no screen capture)'
  $big = Join-Path $mgrLogs 'x4switch.log'
  [IO.File]::WriteAllText($big, ('x' * 600000))
  $r = X @('--status')
  Assert ((Test-Path -LiteralPath "$big.1") -and (Get-Item -LiteralPath $big).Length -lt 200000) 'L1 log over 512 KB: rotated to x4switch.log.1, new log small'
} catch {
  $script:fail++; $script:failed += "unexpected error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
  Write-Host "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
} finally {
  if ($job -ne [IntPtr]::Zero) { [void][JobRun]::CloseHandle($job) }
  if ($run -and (Test-Path -LiteralPath $run)) {
    Kill-Windows
    1..2 | ForEach-Object { Get-Mine | ForEach-Object { Stop-Pid ([int]$_.ProcessId) }; Start-Sleep -Milliseconds 700 }
    Write-Host ("leftover test processes after cleanup: {0}" -f @(Get-Mine).Count)
  }
}
Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed   (work dir: {2})" -f $script:pass, $script:fail, $run)
foreach ($f in $script:failed) { Write-Host "  failed: $f" }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
