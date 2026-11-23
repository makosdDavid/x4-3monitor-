<#
dock-replug.ps1 - "pull the dock out and plug it back in", done in software.

Fault it is for (measured 2026-11-23): after the PC wakes from sleep, the monitors behind the USB-C dock stay
dark. Windows keeps sending them their signal, the monitors answer on their control channel and report standby;
taking them off the desktop and back did not help, re-plugging the dock did.

What it does: restarts, one after the other, the devices a physical re-plug resets - until every monitor reports
a picture again (checked over the monitors' own control channel, so nobody has to answer a question):
   ucsi  the laptop's USB Type-C connector manager (re-negotiates the port, the closest thing to a re-plug)
   hub   the dock's own USB hub
   (the graphics-adapter step was removed 2026-11-23: it crashed the PC)
The step that worked is remembered and tried first next time. Needs administrator rights (asks via UAC).

  dock-replug.ps1                 run when a dock monitor is dark (does nothing if all monitors show a picture)
  dock-replug.ps1 -Force          run even if every monitor reports a picture
  dock-replug.ps1 -Step gpu       only this step (ucsi | hub | gpu)
  dock-replug.ps1 -WhatIf         show the state and what would be restarted; changes nothing
  dock-replug.ps1 -NoAutoSleep    plugged in: never go to sleep by itself (the sleep is what triggers the fault)
  dock-replug.ps1 -RestoreSleep   put the previous automatic-sleep time back
#>
param(
    [ValidateSet('all', 'ucsi', 'hub', 'gpu')][string]$Step = 'all',
    [switch]$Force, [switch]$WhatIf, [switch]$NoAutoSleep, [switch]$RestoreSleep,
    [string]$DockHub = 'USB\VID_214B&PID_7250*',
    [int]$WaitSeconds = 30
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $here 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
$log = Join-Path $stateDir 'dock-replug.log'
$lastFile = Join-Path $stateDir 'dock-replug-last.json'
function Say($t) { $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $t; Write-Host $line; Add-Content -LiteralPath $log -Value $line -Encoding UTF8 }
function Box($t) { Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.Form; $f.TopMost = $true; [void][System.Windows.Forms.MessageBox]::Show($f, $t, 'Dokkolo'); $f.Dispose() }

# ---------- automatic sleep on mains power ----------
if ($NoAutoSleep -or $RestoreSleep) {
    $sleepFile = Join-Path $stateDir 'sleep-before.txt'
    $cur = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Current AC Power Setting Index: (0x[0-9a-f]+)').Matches[0].Groups[1].Value
    $curSec = [Convert]::ToInt32($cur, 16)
    if ($NoAutoSleep) {
        if ($curSec -ne 0 -and -not (Test-Path $sleepFile)) { Set-Content -LiteralPath $sleepFile -Value $curSec }
        if ($WhatIf) { Say "WhatIf: automatic sleep on mains is $curSec s now; would set it to never"; exit 0 }
        powercfg /change standby-timeout-ac 0
        Say "automatic sleep on mains: $curSec s -> never (exit code $LASTEXITCODE)"
    } else {
        $old = $(if (Test-Path $sleepFile) { [int](Get-Content $sleepFile) } else { 1800 })
        if ($WhatIf) { Say "WhatIf: would set automatic sleep on mains back to $old s"; exit 0 }
        powercfg /change standby-timeout-ac ([int]($old / 60))
        Say "automatic sleep on mains: back to $old s (exit code $LASTEXITCODE)"
    }
    exit 0
}

# ---------- what the monitors say about themselves ----------
if (-not ('MonDdc' -as [type])) { Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath (Join-Path $here 'diag\MonDdc.cs')) }
function Get-Mon {
    $list = @()
    foreach ($l in [MonDdc]::Read()) { $p = $l -split '\|'; $list += [pscustomobject]@{ At = $p[0]; Power = [int]$p[1]; Input = [int]$p[2] } }
    $list
}
function Describe-Mon($m) { ($m | ForEach-Object { "[$($_.At)] " + $(if ($_.Power -eq 1) { 'picture' } elseif ($_.Power -lt 0) { 'no answer' } else { "DARK (power state $($_.Power))" }) }) -join '   ' }

$before = @(Get-Mon)
$total = $before.Count
$dark = @($before | Where-Object { $_.Power -ne 1 }).Count
Say ("monitors: " + (Describe-Mon $before))

# ---------- the devices ----------
$dev = [ordered]@{}
$u = Get-PnpDevice -Class UCM -PresentOnly -ErrorAction SilentlyContinue | Select-Object -First 1
if ($u) { $dev['ucsi'] = $u.InstanceId }
$h = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like $DockHub } | Select-Object -First 1
if ($h) { $dev['hub'] = $h.InstanceId }
$g = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'NVIDIA' } | Select-Object -First 1
if ($g) { $dev['gpu'] = $g.InstanceId }
# gpu step REMOVED 2026-11-23: restarting the graphics adapter crashed the PC (unexpected reboot 13:33)
$order = @('ucsi', 'hub') | Where-Object { $dev.Contains($_) }
if ($Step -ne 'all') { $order = @($order | Where-Object { $_ -eq $Step }) }
elseif (Test-Path $lastFile) {
    $last = (Get-Content -Raw $lastFile | ConvertFrom-Json).step
    if ($order -contains $last) { $order = @($last) + @($order | Where-Object { $_ -ne $last }) }
}
Say ("steps: " + (($order | ForEach-Object { "$_ = $($dev[$_])" }) -join ' ; '))

if ($WhatIf) { Say "WhatIf: $dark of $total monitors dark; nothing is changed."; exit 0 }
if ($dark -eq 0 -and -not $Force) { Say 'every monitor reports a picture - nothing to do'; Box "Minden monitor kepet jelez - nincs teendo.`n(Ha megis sotet valamelyik: dock-replug.ps1 -Force)"; exit 0 }
if (-not $order.Count) { Say 'none of the devices was found'; Box 'Nem talalom az ujrainditando eszkozoket.'; exit 2 }

# ---------- administrator rights ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'), '-Step', $Step, '-Force', '-WaitSeconds', $WaitSeconds)
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a } catch { Say 'administrator rights were not given - nothing changed' }
    exit 0
}

# ---------- one elevated run at a time (two parallel runs restarted devices under each other on 2026-11-23) ----------
$mx = New-Object System.Threading.Mutex($false, 'Global\x4cockpit3-dock-replug'); $gotMx = $false
try { $gotMx = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $gotMx = $true }
if (-not $gotMx) { Say 'another run is already working - this one stops'; exit 0 }

# ---------- restart, check, next ----------
$fixedBy = ''
foreach ($s in $order) {
    Say "restarting $s ($($dev[$s]))"
    $out = & pnputil.exe /restart-device $dev[$s] 2>&1 | Out-String
    Say ("  pnputil exit $LASTEXITCODE : " + (($out -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | '))
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false
    Start-Sleep -Seconds 5
    while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds) {
        $now = @(Get-Mon)
        if ($now.Count -ge $total -and @($now | Where-Object { $_.Power -ne 1 }).Count -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 3
    }
    Say ("  after $([int]$sw.Elapsed.TotalSeconds) s: " + (Describe-Mon @(Get-Mon)))
    if ($ok) { $fixedBy = $s; break }
}
if ($fixedBy) {
    Say "PICTURE BACK after step: $fixedBy"
    @{ step = $fixedBy; when = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -LiteralPath $lastFile -Encoding UTF8
    Box "A monitorok ujra kepet jeleznek.`nEz segitett: $fixedBy"
} else {
    Say 'NOT FIXED by any software step'
    Box "Szoftverbol nem jott vissza a kep (probalva: $($order -join ', ')).`nMost csak a dokkolo kihuzasa-bedugasa segit. A naplo: state\dock-replug.log"
}
