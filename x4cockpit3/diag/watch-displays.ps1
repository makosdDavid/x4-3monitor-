<#
watch-displays.ps1 - READ-ONLY continuous log of everything that connects, disconnects or changes:
  monitors (connected / part of the desktop / mode / position), USB devices (present + status),
  and new warnings/errors of the graphics driver, USB and Type-C (UCSI) in the System event log.
Writes only when something changes: state\watch-displays.log (one timestamped line per change).
Start:  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File diag\watch-displays.ps1
Stop :  diag\watch-displays.ps1 -Stop
#>
param([int]$EverySeconds = 3, [switch]$Stop)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path (Split-Path -Parent $here) 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
$log = Join-Path $stateDir 'watch-displays.log'
$pidFile = Join-Path $stateDir 'watch-displays.pid'
if ($Stop) {
    if (Test-Path $pidFile) { $p = [int](Get-Content $pidFile); $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine -match 'watch-displays') { Stop-Process -Id $p -Force; 'stopped' } else { 'not running' }; Remove-Item $pidFile -ErrorAction SilentlyContinue } else { 'not running' }
    exit 0
}
$mutex = New-Object System.Threading.Mutex($false, 'Local\x4cockpit3-watch-displays')
$got = $false; try { $got = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { exit 0 }
Set-Content -LiteralPath $pidFile -Value $PID
function Log($t) { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $t) -Encoding UTF8 }

# the same reader the fix-displays script uses (first Add-Type block of that file)
$src = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $here) 'fix-displays.ps1')
$a = $src.IndexOf("Add-Type @'"); $b = $src.IndexOf("'@", $a)
Add-Type -TypeDefinition $src.Substring($a + 11, $b - $a - 11)

Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath (Join-Path $here 'MonDdc.cs'))
$script:tick = 0; $script:pic = @{}
function Snapshot {
    $s = @{}
    # what each monitor says about itself (picture / dark) - asked only every 10th round (about every 30 s)
    if (($script:tick++ % 10) -eq 0) {
        $script:pic = @{}
        try { foreach ($l in [MonDdc]::Read()) { $p = $l -split '\|'
            $script:pic["PICTURE monitor at $($p[0])"] = $(if ($p[1] -eq '1') { 'shows a picture' } elseif ($p[1] -eq '-1') { 'does not answer' } else { "DARK (power state $($p[1]))" }) + " input=$($p[2])" } } catch { }
    }
    foreach ($k in $script:pic.Keys) { $s[$k] = $script:pic[$k] }
    try {
        foreach ($line in [DispFix]::ActiveOutputs()) {
            $p = $line -split '\|', 3; $c = [DispFix]::Current($p[0]) -split '\|'
            if ($c.Count -ge 5) { $s["DESKTOP $($p[1]) [$($p[0] -replace '\\\\\.\\','')]"] = "$($c[0])x$($c[1])@$($c[2]) at $($c[3]),$($c[4])" }
        }
    } catch { $s['DESKTOP read error'] = $_.Exception.Message }
    try {
        $tech = @{}
        Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop | ForEach-Object { $tech[$_.InstanceName] = [int]$_.VideoOutputTechnology }
        Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
            $t = $tech[$_.InstanceName]; $via = $(if ($t -eq 5) { 'laptop-hdmi' } elseif ($t -eq 10) { 'dock-dp' } elseif ($t -eq 11 -or $t -lt 0) { 'internal' } else { "tech$t" })
            $s["MONITOR $(($_.InstanceName -split '\\')[1]) ($via) $(($_.InstanceName -split '\\')[2])"] = "connected, active=$($_.Active)"
        }
    } catch { }
    try {
        Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB\\%'" -ErrorAction Stop | ForEach-Object {
            $s["USB $($_.PNPDeviceID)"] = "$($_.Name) | status=$($_.Status)" + $(if ($_.ConfigManagerErrorCode) { " error=$($_.ConfigManagerErrorCode)" } else { '' })
        }
    } catch { }
    $s
}

Log "===== watch started (pid $PID, every $EverySeconds s) ====="
$prev = Snapshot
foreach ($k in ($prev.Keys | Sort-Object)) { Log ("  = $k : $($prev[$k])") }
$lastEvt = Get-Date
while ($true) {
    Start-Sleep -Seconds $EverySeconds
    $now = Snapshot
    foreach ($k in ($now.Keys | Sort-Object)) {
        if (-not $prev.ContainsKey($k)) { Log ("  + $k : $($now[$k])") }
        elseif ($prev[$k] -ne $now[$k]) { Log ("  ~ $k : $($prev[$k])  ->  $($now[$k])") }
    }
    foreach ($k in ($prev.Keys | Sort-Object)) { if (-not $now.ContainsKey($k)) { Log ("  - $k (was: $($prev[$k]))") } }
    $prev = $now
    try {
        $since = $lastEvt; $lastEvt = Get-Date
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'nvlddmkm|Display|Ucm|UCSI|USB|Kernel-PnP|amdkmdag|WHEA' } | Sort-Object TimeCreated | ForEach-Object {
                $m = ($_.Message -split "`r?`n")[0]; if ($m.Length -gt 200) { $m = $m.Substring(0, 200) }
                Log ("  ! EVENT $($_.TimeCreated.ToString('HH:mm:ss')) $($_.ProviderName) id=$($_.Id) $($_.LevelDisplayName): $m")
            }
    } catch { }
}
