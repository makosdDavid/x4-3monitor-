# x4cockpit3 - textual edits of the game's config.xml.
# Only the elements named in the value set are touched; every other byte of the file stays as it was
# (no XML re-serialisation, same line endings, same BOM state). Pure functions except Read/Write-ConfigFile.

function Read-ConfigFile([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $start = 0
  if ($bom) { $start = 3 }
  $enc = New-Object Text.UTF8Encoding($false, $true)   # throw on invalid bytes instead of silently replacing them
  $text = $enc.GetString($bytes, $start, $bytes.Length - $start)
  return [pscustomobject]@{ Path = $Path; Bom = $bom; Text = $text; Bytes = $bytes }
}

function ConvertTo-ConfigBytes([string]$Text, [bool]$Bom) {
  $enc = New-Object Text.UTF8Encoding($false)
  $body = $enc.GetBytes($Text)
  if (-not $Bom) { return , $body }
  $out = New-Object byte[] ($body.Length + 3)
  $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
  [Array]::Copy($body, 0, $out, 3, $body.Length)
  return , $out
}

function Write-ConfigFile([string]$Path, [string]$Text, [bool]$Bom) {
  # Write next to the target, then swap it in (File.Replace keeps the target's ACL/attributes).
  $tmp = $Path + '.x4cockpit3-tmp'
  [IO.File]::WriteAllBytes($tmp, (ConvertTo-ConfigBytes $Text $Bom))
  [IO.File]::Replace($tmp, $Path, [NullString]::Value)
}

function Find-ConfigElement([string]$Text, [string]$Key) {
  # <key>value</key> or <key/>; "<fovx>" does not match "fov".
  $k = [regex]::Escape($Key)
  $rx = New-Object regex ('<' + $k + '(?:\s*/>|\s*>([^<]*)</' + $k + '\s*>)')
  $out = @()
  foreach ($m in $rx.Matches($Text)) {
    $val = ''
    if ($m.Groups[1].Success) { $val = $m.Groups[1].Value }
    $out += [pscustomobject]@{ Index = $m.Index; Length = $m.Length; Raw = $m.Value; Value = $val }
  }
  return $out
}

function Get-LineNumber([string]$Text, [int]$Index) {
  $n = 1
  $i = $Text.IndexOf("`n")
  while ($i -ge 0 -and $i -lt $Index) { $n++; $i = $Text.IndexOf("`n", $i + 1) }
  return $n
}

function Get-NewLine([string]$Text) { if ($Text.Contains("`r`n")) { return "`r`n" } else { return "`n" } }

function Get-ChildIndent([string]$Text) {
  $m = [regex]::Match($Text, '(?m)^([ \t]+)<[A-Za-z_]')
  if ($m.Success) { return $m.Groups[1].Value } else { return '  ' }
}

function Format-Element([string]$Key, [string]$Value) {
  return '<' + $Key + '>' + [Security.SecurityElement]::Escape($Value) + '</' + $Key + '>'
}

function Add-ElementBeforeRootEnd([string]$Text, [string]$Element) {
  # Inserts "<indent><element><newline>" at the start of the "</root>" line.
  $end = $Text.LastIndexOf('</root>')
  if ($end -lt 0) { throw 'config.xml has no </root> element' }
  $nl = Get-NewLine $Text
  $indent = Get-ChildIndent $Text
  $ls = $Text.LastIndexOf("`n", [Math]::Max(0, $end - 1)) + 1
  if ($ls -gt $end) { $ls = $end }
  $before = $Text.Substring($ls, $end - $ls)
  if ($before.Trim().Length -eq 0) {
    $ins = $indent + $Element + $nl
    return [pscustomobject]@{ Text = $Text.Insert($ls, $ins); Index = $ls; Inserted = $ins }
  }
  $ins = $nl + $indent + $Element
  return [pscustomobject]@{ Text = $Text.Insert($end, $ins); Index = $end; Inserted = $ins }
}

function Remove-ElementLine([string]$Text, [string]$Key) {
  $k = [regex]::Escape($Key)
  $line = New-Object regex ('(?m)^[ \t]*<' + $k + '(?:\s*/>|\s*>[^<]*</' + $k + '\s*>)[ \t]*\r?\n')
  $ms = $line.Matches($Text)
  if ($ms.Count -eq 1) { return $Text.Remove($ms[0].Index, $ms[0].Length) }
  $inline = New-Object regex ('\r?\n[ \t]*<' + $k + '(?:\s*/>|\s*>[^<]*</' + $k + '\s*>)')
  $ms = $inline.Matches($Text)
  if ($ms.Count -eq 1) { return $Text.Remove($ms[0].Index, $ms[0].Length) }
  throw "cannot remove <$Key>: found $($ms.Count) candidate lines"
}

function Get-ConfigEdit {
  # Applies $Values (ordered key -> string) to $Text.
  # Returns NewText and one change record per key: Key, Existed, OldRaw, OldValue, NewRaw, NewValue, Changed, Line.
  param([string]$Text, $Values)
  $changes = @()
  $repl = @()
  $inserts = @()
  foreach ($key in $Values.Keys) {
    $new = [string]$Values[$key]
    $els = @(Find-ConfigElement $Text $key)
    if ($els.Count -gt 1) { throw "config.xml contains <$key> $($els.Count) times - refusing to guess which one the game uses" }
    $newRaw = Format-Element $key $new
    if ($els.Count -eq 1) {
      $e = $els[0]
      $changed = ($e.Raw -ne $newRaw)
      $changes += [pscustomobject]@{ Key = $key; Existed = $true; OldRaw = $e.Raw; OldValue = $e.Value; NewRaw = $newRaw; NewValue = $new; Changed = $changed; Line = (Get-LineNumber $Text $e.Index) }
      if ($changed) { $repl += [pscustomobject]@{ Index = $e.Index; Length = $e.Length; Raw = $newRaw } }
    } else {
      $changes += [pscustomobject]@{ Key = $key; Existed = $false; OldRaw = $null; OldValue = $null; NewRaw = $newRaw; NewValue = $new; Changed = $true; Line = 0 }
      $inserts += $newRaw
    }
  }
  $t = $Text
  foreach ($r in ($repl | Sort-Object Index -Descending)) { $t = $t.Remove($r.Index, $r.Length).Insert($r.Index, $r.Raw) }
  foreach ($el in $inserts) {
    $res = Add-ElementBeforeRootEnd $t $el
    $t = $res.Text
    $c = $changes | Where-Object { $_.NewRaw -eq $el -and -not $_.Existed } | Select-Object -First 1
    $c.Line = Get-LineNumber $t ($res.Index + 1)
  }
  return [pscustomobject]@{ NewText = $t; Changes = $changes }
}

function Get-ConfigRestore {
  # Undoes a previous Get-ConfigEdit using its saved change records ($Saved: Key, Existed, OldRaw).
  # Keys that existed get their original element text back; keys that were inserted are removed with their line.
  param([string]$Text, $Saved)
  $t = $Text
  $out = @()
  foreach ($c in $Saved) {
    $els = @(Find-ConfigElement $t $c.Key)
    if ($els.Count -gt 1) { throw "config.xml contains <$($c.Key)> $($els.Count) times - refusing to guess" }
    if ($c.Existed) {
      if ($els.Count -eq 1) {
        $e = $els[0]
        $out += [pscustomobject]@{ Key = $c.Key; Action = 'restore'; From = $e.Raw; To = $c.OldRaw; Changed = ($e.Raw -ne $c.OldRaw); Line = (Get-LineNumber $t $e.Index) }
        if ($e.Raw -ne $c.OldRaw) { $t = $t.Remove($e.Index, $e.Length).Insert($e.Index, $c.OldRaw) }
      } else {
        $res = Add-ElementBeforeRootEnd $t $c.OldRaw
        $t = $res.Text
        $out += [pscustomobject]@{ Key = $c.Key; Action = 're-add'; From = $null; To = $c.OldRaw; Changed = $true; Line = (Get-LineNumber $t ($res.Index + 1)) }
      }
    } else {
      if ($els.Count -eq 1) {
        $line = Get-LineNumber $t $els[0].Index
        $t = Remove-ElementLine $t $c.Key
        $out += [pscustomobject]@{ Key = $c.Key; Action = 'remove'; From = $els[0].Raw; To = $null; Changed = $true; Line = $line }
      } else {
        $out += [pscustomobject]@{ Key = $c.Key; Action = 'absent'; From = $null; To = $null; Changed = $false; Line = 0 }
      }
    }
  }
  return [pscustomobject]@{ NewText = $t; Changes = $out }
}

function Test-ConfigValues([string]$Text, $Values) {
  # Parses the text as XML and checks that /root/<key> has the expected value. Returns a list of problems.
  $problems = @()
  try { $x = New-Object Xml.XmlDocument; $x.LoadXml($Text) } catch { return @("not well-formed XML: $($_.Exception.Message)") }
  foreach ($k in $Values.Keys) {
    $n = $x.DocumentElement.SelectSingleNode($k)
    if ($null -eq $n) { $problems += "<$k> missing" }
    elseif ($n.InnerText -ne [string]$Values[$k]) { $problems += "<$k> is '$($n.InnerText)', expected '$($Values[$k])'" }
  }
  return $problems
}
