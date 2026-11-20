# x4cockpit3 - shared helpers: settings, profile detection, game-process check, invariant formatting.
# Windows PowerShell 5.1 compatible. Dot-source this file; it defines functions only.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Fmt {
  # String.Format with the invariant culture (a decimal point, never a decimal comma).
  param([string]$Format)
  return [string]::Format($script:Inv, $Format, [object[]]$args)
}

function ConvertTo-InvString($v) {
  if ($null -eq $v) { return $null }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  return [Convert]::ToString($v, $script:Inv)
}

# Keys the config switcher is allowed to write. Anything else in "cockpit" is rejected.
$script:AllowedCockpitKeys = @('fullscreen', 'borderless', 'res_width', 'res_height', 'fov', 'menuwidthscale', 'confinemouse')

function Get-DefaultSettings {
  return [ordered]@{
    profileDir           = ''      # '' = auto: newest <Documents>\Egosoft\X4\<numeric id>\config.xml
    gameExe              = ''      # '' = auto: <tool>\..\..\X4.exe if it exists, else any process named X4 counts
    backupDir            = ''      # '' = <tool>\backups      (config.xml copies, never deleted by the tool)
    stateDir             = ''      # '' = <tool>\state        (saved original values, window state, companion flag)
    companionSkipFlag    = ''      # '' = <stateDir>\cockpit-active.flag ; 'none' = do not write a flag
    companionWindowTitle = 'X4 Companion'
    centreMatch          = ''      # '' = the primary monitor; else regex on EDID code / monitor name
    sideMatch            = ''      # '' = any other monitor; else regex on EDID code / monitor name
    yTolerancePx         = 8
    fovBaseAspect        = 1.7778  # assumption: fov is horizontal degrees at a 16:9 base (Hor+)
    cockpit              = [ordered]@{
      fullscreen     = 'false'
      borderless     = 'false'
      res_width      = '7280'
      res_height     = '1440'
      fov            = '0.6667'
      menuwidthscale = '0.47'
      confinemouse   = 'true'
    }
  }
}

function Read-CockpitSettings {
  param([string]$ToolRoot, [string]$SettingsFile = '')
  $s = Get-DefaultSettings
  $file = $SettingsFile
  if (-not $file) { $file = Join-Path $ToolRoot 'settings.json' }
  $s['_file'] = ''
  if (Test-Path -LiteralPath $file) {
    $j = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) {
      if ($p.Name.StartsWith('_')) { continue }
      if ($p.Name -eq 'cockpit') {
        if ($null -eq $p.Value) { continue }
        foreach ($q in $p.Value.PSObject.Properties) {
          if ($q.Name.StartsWith('_')) { continue }
          if ($script:AllowedCockpitKeys -notcontains $q.Name) {
            throw "settings: cockpit key '$($q.Name)' is not allowed (allowed: $($script:AllowedCockpitKeys -join ', '))"
          }
          if ($null -eq $q.Value) { $s.cockpit.Remove($q.Name) } else { $s.cockpit[$q.Name] = ConvertTo-InvString $q.Value }
        }
      } elseif ($s.Contains($p.Name)) {
        $s[$p.Name] = $p.Value
      } else {
        throw "settings: unknown key '$($p.Name)' in $file"
      }
    }
    $s['_file'] = $file
  } elseif ($SettingsFile) {
    throw "settings file not found: $SettingsFile"
  }
  if (-not $s.backupDir) { $s.backupDir = Join-Path $ToolRoot 'backups' }
  if (-not $s.stateDir) { $s.stateDir = Join-Path $ToolRoot 'state' }
  if (-not $s.companionSkipFlag) { $s.companionSkipFlag = Join-Path $s.stateDir 'cockpit-active.flag' }
  if (-not $s.gameExe) {
    $guess = Join-Path (Split-Path -Parent (Split-Path -Parent $ToolRoot)) 'X4.exe'
    if (Test-Path -LiteralPath $guess) { $s.gameExe = [IO.Path]::GetFullPath($guess) }
  }
  $s.yTolerancePx = [int]$s.yTolerancePx
  $s.fovBaseAspect = [double]$s.fovBaseAspect
  Test-CockpitValues $s.cockpit
  return $s
}

function Test-CockpitValues($values) {
  foreach ($k in $values.Keys) {
    $v = [string]$values[$k]
    switch ($k) {
      { $_ -in 'fullscreen', 'borderless', 'confinemouse' } { if ($v -notin 'true', 'false') { throw "settings: cockpit.$k must be 'true' or 'false' (got '$v')" } }
      { $_ -in 'res_width', 'res_height' } { if ($v -notmatch '^\d{3,5}$') { throw "settings: cockpit.$k must be an integer (got '$v')" } }
      'fov' {
        if ($v -notmatch '^\d+(\.\d+)?$') { throw "settings: cockpit.fov must be a number like 0.6667 (got '$v')" }
        $d = [double]$v
        if ($d -le 0.2 -or $d -gt 1.3334) { throw "settings: cockpit.fov $v is outside 0.2..1.3333 (degrees = fov x 90)" }
      }
      'menuwidthscale' {
        if ($v -notmatch '^\d+(\.\d+)?$') { throw "settings: cockpit.menuwidthscale must be a number (got '$v')" }
        $d = [double]$v
        if ($d -lt 0.1 -or $d -gt 1.0) { throw "settings: cockpit.menuwidthscale $v is outside 0.10..1.00 (the game's own range)" }
      }
    }
  }
}

function Find-X4ProfileDir {
  # Newest profile = numeric folder under <Documents>\Egosoft\X4 whose config.xml was written last.
  param([string]$BaseDir = '')
  if (-not $BaseDir) { $BaseDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Egosoft\X4' }
  if (-not (Test-Path -LiteralPath $BaseDir)) { return $null }
  $cands = @(Get-ChildItem -LiteralPath $BaseDir -Directory -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'config.xml')) })
  if ($cands.Count -eq 0) { return $null }
  $best = $cands | Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'config.xml')).LastWriteTimeUtc } -Descending | Select-Object -First 1
  return [pscustomobject]@{ Dir = $best.FullName; Candidates = @($cands | ForEach-Object { $_.FullName }) }
}

function Resolve-ConfigPath($Settings) {
  if ($Settings.profileDir) {
    $p = Join-Path $Settings.profileDir 'config.xml'
    if (-not (Test-Path -LiteralPath $p)) { throw "config.xml not found in profileDir '$($Settings.profileDir)'" }
    return $p
  }
  $f = Find-X4ProfileDir
  if (-not $f) { throw 'No X4 profile found under Documents\Egosoft\X4 (set "profileDir" in settings.json).' }
  if ($f.Candidates.Count -gt 1) { Write-Host ("note: {0} profiles found, using the newest: {1}" -f $f.Candidates.Count, $f.Dir) }
  return (Join-Path $f.Dir 'config.xml')
}

function Get-GameProcesses {
  # Processes that count as "the game is running". With a known exe path only that exe counts; a process of the
  # same name whose path cannot be read is counted too (conservative). Without a known path, any process named X4.
  # -RequirePathMatch (used before moving a window): only a process whose path is readable AND equals GameExe.
  param([string]$GameExe = '', [switch]$RequirePathMatch)
  $name = 'X4'
  if ($GameExe) { $name = [IO.Path]::GetFileNameWithoutExtension($GameExe) }
  $out = @()
  foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
    $path = $null
    try { $path = $p.Path } catch { }
    $match = $false
    if (-not $GameExe) { $match = (-not $RequirePathMatch) -or [bool]$path }
    elseif (-not $path) { $match = -not $RequirePathMatch }
    elseif ([string]::Equals([IO.Path]::GetFullPath($path), [IO.Path]::GetFullPath($GameExe), [StringComparison]::OrdinalIgnoreCase)) { $match = $true }
    if ($match) { $out += [pscustomobject]@{ Id = $p.Id; Path = $path; MainWindowHandle = $p.MainWindowHandle } }
  }
  return $out
}
