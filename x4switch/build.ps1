<#
.SYNOPSIS
  Builds X4Switch.exe next to this script with Zig (zig cc, x86_64-windows-gnu). Nothing else is used or downloaded.

.DESCRIPTION
  zig.exe: -Zig <path>  >  $env:X4SWITCH_ZIG  >  $env:X4C3_ZIG  >  first line of zig.path here  >  first line of
  ..\x4cockpit3\native\zig.path  >  zig on PATH.   (zig.path files are machine-local and gitignored.)
  Zig caches: $env:ZIG_GLOBAL_CACHE_DIR / $env:ZIG_LOCAL_CACHE_DIR if set, otherwise "cache" and "cache-local" next
  to the folder that holds zig.exe. The icon (src\x4switch.ico) is drawn here with System.Drawing if it is missing.
  Prints the SHA-256 of the output. Exit code 0 = built.
#>
[CmdletBinding()]
param([string]$Zig = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $here 'src'

if (-not $Zig) { $Zig = $env:X4SWITCH_ZIG }
if (-not $Zig) { $Zig = $env:X4C3_ZIG }
foreach ($pf in (Join-Path $here 'zig.path'), (Join-Path $here '..\x4cockpit3\native\zig.path')) {
  if (-not $Zig -and (Test-Path -LiteralPath $pf)) { $Zig = (Get-Content -LiteralPath $pf -TotalCount 1).Trim() }
}
if (-not $Zig) { $c = Get-Command zig.exe -ErrorAction SilentlyContinue; if ($c) { $Zig = $c.Source } }
if (-not $Zig -or -not (Test-Path -LiteralPath $Zig)) { Write-Host 'ERROR: zig.exe not found. Pass -Zig <path>, set X4SWITCH_ZIG, or put the path into zig.path.'; exit 1 }
$zigDir = Split-Path -Parent $Zig
if (-not $env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR = Join-Path (Split-Path -Parent $zigDir) 'cache' }
if (-not $env:ZIG_LOCAL_CACHE_DIR) { $env:ZIG_LOCAL_CACHE_DIR = Join-Path (Split-Path -Parent $zigDir) 'cache-local' }
Write-Host "zig    : $Zig ($(& $Zig version))"
Write-Host "caches : $env:ZIG_GLOBAL_CACHE_DIR | $env:ZIG_LOCAL_CACHE_DIR"

# ---- icon: three screens, drawn at 16/24/32/48/256 px, stored as PNG frames in one .ico
$ico = Join-Path $src 'x4switch.ico'
if (-not (Test-Path -LiteralPath $ico)) {
  Add-Type -AssemblyName System.Drawing
  $frames = @()
  foreach ($n in 16, 24, 32, 48, 256) {
    $bmp = New-Object Drawing.Bitmap($n, $n, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $u = $n / 16.0
    $bg = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 0x1e, 0x22, 0x2a))
    $g.FillRectangle($bg, [single](0.5 * $u), [single](1.5 * $u), [single](15 * $u), [single](13 * $u))
    $side = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 0x98, 0xa1, 0xb0))
    $acc = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 0x3d, 0x8b, 0xfd))
    $g.FillRectangle($side, [single](1.5 * $u), [single](5 * $u), [single](3 * $u), [single](5 * $u))
    $g.FillRectangle($acc, [single](5 * $u), [single](3.5 * $u), [single](6 * $u), [single](8 * $u))
    $g.FillRectangle($side, [single](11.5 * $u), [single](5 * $u), [single](3 * $u), [single](5 * $u))
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $frames += , @($n, $ms.ToArray())
  }
  $fs = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter($fs)
  $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
  $off = 6 + 16 * $frames.Count
  foreach ($f in $frames) {
    $dim = $f[0]; if ($dim -ge 256) { $dim = 0 }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$f[1].Length); $bw.Write([uint32]$off)
    $off += $f[1].Length
  }
  foreach ($f in $frames) { $bw.Write([byte[]]$f[1]) }
  $bw.Flush(); [IO.File]::WriteAllBytes($ico, $fs.ToArray())
  Write-Host "icon   : $ico (generated)"
}

$target = Join-Path $here 'X4Switch.exe'
$a = @('cc', '-target', 'x86_64-windows-gnu', '-O2', '-std=c11', '-Wall', '-Wextra', '-Wno-unused-parameter',
  '-Wno-missing-field-initializers', '-Wno-cast-function-type', '-fno-sanitize=undefined', '-DUNICODE', '-D_UNICODE',
  'main.c', 'core.c', 'gui.c', 'json.c', 'i18n.c', 'x4switch.rc', '-Wl,--subsystem,windows',
  '-luser32', '-lgdi32', '-lkernel32', '-lshell32', '-lole32', '-loleaut32', '-lws2_32', '-lcomdlg32', '-ldwmapi', '-luxtheme',
  '-o', $target)
Push-Location $src   # the .rc references the manifest and icon relative to src\
try {
  $ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr (warnings) into errors otherwise
  $log = & $Zig @a 2>&1 | ForEach-Object { "$_" } | Out-String
  $ErrorActionPreference = 'Stop'
} finally { Pop-Location }
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target)) { Write-Host $log; Write-Host 'BUILD FAILED'; exit 1 }
if ($log.Trim()) { Write-Host $log.TrimEnd() }
Write-Host ("sha256 : {0}  X4Switch.exe ({1} bytes)" -f (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash, (Get-Item -LiteralPath $target).Length)
Write-Host 'BUILD OK'
exit 0
