<#
dsc-test.ps1 - EXPERIMENT: flip the NVIDIA driver's DISABLE_DSC value (Display Stream Compression).
The NVIDIA INF sets DISABLE_DSC=1 for some 2021-22 ASUS laptops. With DSC allowed, two 1920x1080 screens
may fit on a slow dock link. Undocumented by NVIDIA; needs a reboot; every NVIDIA driver install resets it.

  dsc-test.ps1 -On      allow DSC   (DISABLE_DSC=0), original key exported first
  dsc-test.ps1 -Off     vendor default (DISABLE_DSC=1)
  dsc-test.ps1          only show the current value (no admin needed)

Asks for administrator rights itself (UAC). Backups: state\nvidia-<key>-<timestamp>.reg (never overwritten).
#>
param([switch]$On, [switch]$Off)
$ErrorActionPreference = 'Stop'
$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$nv = @(Get-ChildItem -LiteralPath $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | Where-Object {
    $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
    $p -and ("$($p.ProviderName) $($p.DriverDesc)" -match 'NVIDIA')
})
if ($nv.Count -ne 1) { Write-Host "Expected exactly one NVIDIA display adapter key, found $($nv.Count). Nothing changed."; if ($On -or $Off) { Read-Host 'Enter to close' | Out-Null }; exit 2 }
$key = $nv[0]
$props = Get-ItemProperty -LiteralPath $key.PSPath
Write-Host ("Adapter : {0} (driver {1}), key {2}" -f $props.DriverDesc, $props.DriverVersion, $key.PSChildName)
Write-Host ("Current : DISABLE_DSC = {0}" -f $(if ($null -eq $props.DISABLE_DSC) { '(not set)' } else { $props.DISABLE_DSC }))
if (-not ($On -or $Off)) { exit 0 }
if ($On -and $Off) { Write-Host 'Use either -On or -Off.'; exit 2 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $flag = $(if ($On) { '-On' } else { '-Off' })
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), $flag)
    exit 0
}

try {
    $stateDir = Join-Path $PSScriptRoot 'state'
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
    $regPath = $key.Name   # HKEY_LOCAL_MACHINE\...
    $backup = Join-Path $stateDir ("nvidia-{0}-{1}.reg" -f $key.PSChildName, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    & reg.exe export $regPath $backup | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backup)) { throw "backup failed (reg export exit $LASTEXITCODE) - nothing changed" }
    Write-Host "Backup  : $backup"
    $want = $(if ($On) { 0 } else { 1 })
    Set-ItemProperty -LiteralPath $key.PSPath -Name 'DISABLE_DSC' -Value $want -Type DWord
    $now = (Get-ItemProperty -LiteralPath $key.PSPath).DISABLE_DSC
    Write-Host ("Now     : DISABLE_DSC = {0}" -f $now)
    if ($now -ne $want) { throw 'the value did not change' }
    Add-Content -LiteralPath (Join-Path $stateDir 'dsc-test.log') -Value ("{0} DISABLE_DSC {1} -> {2} (backup {3})" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $props.DISABLE_DSC, $now, (Split-Path -Leaf $backup))
    Write-Host ''
    Write-Host 'RESTART the computer now: the driver reads this value only at start.'
} catch {
    Write-Host ("FAILED: " + $_.Exception.Message)
}
Read-Host 'Enter to close' | Out-Null
