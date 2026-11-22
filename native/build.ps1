<#
.SYNOPSIS
  Builds launcher.exe, x4c3hook.dll and testtarget.exe into native\out\ with Zig (zig cc, x86_64-windows-gnu).

.DESCRIPTION
  Zig is the only tool used; no other compiler, library or download. Where zig.exe is found, in this order:
    -Zig <path>  >  $env:X4C3_ZIG  >  the first line of native\zig.path (machine-local, gitignored)  >  zig on PATH.
  Zig caches: $env:ZIG_GLOBAL_CACHE_DIR / $env:ZIG_LOCAL_CACHE_DIR if set, otherwise "cache" and "cache-local"
  next to the folder that holds zig.exe (e.g. <tools>\zig\cache for <tools>\zig\zig-x86_64-windows-0.17.1\zig.exe).
  Prints the SHA-256 of every output. Exit code 0 = all three built.
#>
[CmdletBinding()]
param([string]$Zig = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Zig) { $Zig = $env:X4C3_ZIG }
if (-not $Zig) {
  $pf = Join-Path $here 'zig.path'
  if (Test-Path -LiteralPath $pf) { $Zig = (Get-Content -LiteralPath $pf -TotalCount 1).Trim() }
}
if (-not $Zig) { $c = Get-Command zig.exe -ErrorAction SilentlyContinue; if ($c) { $Zig = $c.Source } }
if (-not $Zig -or -not (Test-Path -LiteralPath $Zig)) {
  Write-Host 'ERROR: zig.exe not found. Pass -Zig <path>, set X4C3_ZIG, or put the path into native\zig.path.'
  exit 1
}
$zigDir = Split-Path -Parent $Zig
if (-not $env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR = Join-Path (Split-Path -Parent $zigDir) 'cache' }
if (-not $env:ZIG_LOCAL_CACHE_DIR) { $env:ZIG_LOCAL_CACHE_DIR = Join-Path (Split-Path -Parent $zigDir) 'cache-local' }
Write-Host "zig    : $Zig ($(& $Zig version))"
Write-Host "caches : $env:ZIG_GLOBAL_CACHE_DIR | $env:ZIG_LOCAL_CACHE_DIR"

$out = Join-Path $here 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$common = @('cc', '-target', 'x86_64-windows-gnu', '-O2', '-std=c11', '-Wall', '-Wextra', '-Wno-unused-parameter',
  '-Wno-missing-field-initializers', '-Wno-unused-function', '-fno-sanitize=undefined', '-DUNICODE', '-D_UNICODE')
$jobs = @(
  @{ Name = 'launcher.exe'; Args = @('launcher.c', 'launcher.rc', '-Wl,--subsystem,windows', '-lkernel32') },
  @{ Name = 'x4c3hook.dll'; Args = @('-shared', 'hook.c', 'hook.rc', '-luser32', '-lkernel32') },
  @{ Name = 'testtarget.exe'; Args = @('testtarget.c', 'testtarget.rc', '-Wl,--subsystem,windows', '-luser32', '-lgdi32', '-lkernel32') }
)
$ok = $true
Push-Location $here   # .rc files reference their manifests relative to this folder
try {
  foreach ($j in $jobs) {
    $target = Join-Path $out $j.Name
    $a = $common + $j.Args + @('-o', $target)
    Write-Host "build  : $($j.Name)"
    $ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr (warnings) into errors otherwise
    $log = & $Zig @a 2>&1 | ForEach-Object { "$_" } | Out-String
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target)) { Write-Host $log; Write-Host "FAILED : $($j.Name)"; $ok = $false; continue }
    if ($log.Trim()) { Write-Host $log.TrimEnd() }
  }
} finally { Pop-Location }
foreach ($j in $jobs) {
  $t = Join-Path $out $j.Name
  if (Test-Path -LiteralPath $t) { Write-Host ("sha256 : {0}  {1} ({2} bytes)" -f (Get-FileHash -LiteralPath $t -Algorithm SHA256).Hash, $j.Name, (Get-Item -LiteralPath $t).Length) }
}
if ($ok) { Write-Host 'BUILD OK'; exit 0 } else { Write-Host 'BUILD FAILED'; exit 1 }
