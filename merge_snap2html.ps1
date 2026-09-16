<#
.SYNOPSIS
    Consolidate Snap2HTML 2.5+ show snapshots under a single 'Shows' root.

.DESCRIPTION
    Reads two (or more) Snap2HTML 2.5+ (V2 / dataVersion 2) snapshot files,
    typically shows-A_2_R.html and shows-S_2_Z.html, and writes one snapshot
    that adheres to the Snap2HTML 2.5 template.html format.

    Each input is a snapshot of a 'shows' folder (possibly on a different
    drive). This script drops those original root folders and re-parents
    every show folder from every input under a new synthetic root named
    'Shows'. The page title is also set to 'Shows'.

    Folder ids in the second and later inputs are remapped so every
    parent/subfolder reference stays valid. Top-level show folders are
    listed in Snap2HTML's natural sort order (case-insensitive, 'folder 2'
    before 'folder 10'). Header counters (file count, folder count, total
    size) are recomputed from the combined tree.

    The output is produced by filling the placeholders in template.html
    ([PAGE TITLE], [DIR DATA], [NUM FILES], ...), not by rewriting one of
    the inputs. Works with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER InputFiles
    Snapshot files to consolidate. Defaults to shows-A_2_R.html and
    shows-S_2_Z.html next to this script.

.PARAMETER OutputFile
    Destination HTML file. Default: shows.html next to this script
    (or in the current directory if the script is not in a 'shows' folder).

.PARAMETER TemplateFile
    Snap2HTML 2.5 template.html to fill. Default: template.html in the
    repository root (parent of this script's folder).

.PARAMETER Title
    Name of the synthetic root folder and of the page title. Default: Shows.

.PARAMETER KeepOrder
    Keep each input's original child order (A then S, ...) instead of
    re-sorting the combined top-level listing.

.EXAMPLE
    PS> .\shows\consolidate_shows.ps1

    Consolidates shows\shows-A_2_R.html and shows\shows-S_2_Z.html into
    shows\shows.html with root/title 'Shows'.

.EXAMPLE
    PS> .\shows\consolidate_shows.ps1 -OutputFile shows\shows.html -Title Shows

.NOTES
    If script execution is blocked by policy, run it with:
    powershell -ExecutionPolicy Bypass -File .\shows\consolidate_shows.ps1
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InputFiles,

    [Parameter()]
    [Alias('o')]
    [string]$OutputFile,

    [Parameter()]
    [string]$TemplateFile,

    [Parameter()]
    [string]$Title = 'Shows',

    [Parameter()]
    [switch]$KeepOrder
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

function Resolve-ExistingFile {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$What)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('{0} not found: {1}' -f $What, $Path)
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

# $PSScriptRoot is the script's folder (not the caller's) on PS 3+.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$repoRoot  = Split-Path -Parent $scriptDir
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'template.html'))) {
    $repoRoot = $scriptDir
}

if (-not $TemplateFile) {
    $TemplateFile = Join-Path $repoRoot 'template.html'
}
$TemplateFile = Resolve-ExistingFile -Path $TemplateFile -What 'template'

if (-not $InputFiles -or $InputFiles.Count -eq 0) {
    $InputFiles = @(
        (Join-Path $scriptDir 'shows-A_2_R.html'),
        (Join-Path $scriptDir 'shows-S_2_Z.html')
    )
}
if ($InputFiles.Count -lt 2) {
    throw 'at least two input snapshot files are required'
}
$resolvedInputs = @()
foreach ($p in $InputFiles) {
    $resolvedInputs += (Resolve-ExistingFile -Path $p -What 'input snapshot')
}

if (-not $OutputFile) {
    $OutputFile = Join-Path $scriptDir 'shows.html'
}
$OutputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)

if ([string]::IsNullOrWhiteSpace($Title)) {
    throw 'Title must be a non-empty string'
}

# ---------------------------------------------------------------------------
# Helpers (Snap2HTML 2.5 encoding / formatting)
# ---------------------------------------------------------------------------

function Get-JavaScriptString {
    # HttpUtility.JavaScriptStringEncode() with default settings, including
    # the surrounding quotes. Used for names inside p([...]) data lines.
    # AllowEmptyString: PowerShell treats '' as "missing" on Mandatory
    # [string] params, but linkRoot (and similar) is legitimately empty.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if     ($code -eq 34)  { [void]$sb.Append('\"') }
        elseif ($code -eq 92)  { [void]$sb.Append('\\') }
        elseif ($code -eq 10)  { [void]$sb.Append('\n') }
        elseif ($code -eq 13)  { [void]$sb.Append('\r') }
        elseif ($code -eq 9)   { [void]$sb.Append('\t') }
        elseif ($code -eq 8)   { [void]$sb.Append('\b') }
        elseif ($code -eq 12)  { [void]$sb.Append('\f') }
        elseif ($code -lt 32 -or $code -eq 38 -or $code -eq 39 -or
                $code -eq 60 -or $code -eq 62 -or $code -eq 0x85 -or
                $code -eq 0x2028 -or $code -eq 0x2029) {
            [void]$sb.AppendFormat('\u{0:x4}', $code)
        }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-Base36 {
    param([Parameter(Mandatory = $true)][long]$Number)
    if ($Number -lt 0) { return ('-' + (ConvertTo-Base36 (-$Number))) }
    if ($Number -eq 0) { return '0' }
    $digits = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $sb = New-Object System.Text.StringBuilder
    while ($Number -gt 0) {
        $rem = [long]0
        $Number = [Math]::DivRem($Number, 36, [ref]$rem)
        [void]$sb.Insert(0, $digits[[int]$rem])
    }
    return $sb.ToString()
}

function ConvertFrom-Base36 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WhatValue = 'base-36 number'
    )
    if ($Value -notmatch '^[0-9A-Za-z]+$') {
        throw ('{0}: {1} is not a valid base-36 number: ''{2}''' -f $Path, $WhatValue, $Value)
    }
    $v = [long]0
    foreach ($ch in $Value.ToCharArray()) {
        $d = [int]$ch
        if     ($d -ge 48 -and $d -le 57) { $d -= 48 }
        elseif ($d -ge 65 -and $d -le 90) { $d -= 55 }
        else                              { $d -= 87 }
        $v = $v * 36 + $d
    }
    return $v
}

function Get-CSharpFileSize {
    # Utils.BytesToFilesize() - what Snap2HTML writes into [TOT SIZE].
    param(
        [Parameter(Mandatory = $true)][long]$Bytes,
        [string]$DecimalSeparator = '.'
    )
    $kb = 1024L; $mb = 1048576L; $gb = 1073741824L; $tb = 1099511627776L
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 0 -and $Bytes -lt $kb) { return ('' + $Bytes + ' bytes') }
    if     ($Bytes -lt $mb) { $val = $Bytes / $kb; $dec = 0; $unit = 'KB' }
    elseif ($Bytes -lt $gb) { $val = $Bytes / $mb; $dec = 1; $unit = 'MB' }
    elseif ($Bytes -lt $tb) { $val = $Bytes / $gb; $dec = 2; $unit = 'GB' }
    else                    { $val = $Bytes / $tb; $dec = 2; $unit = 'TB' }
    $r = [Math]::Round($val, $dec)
    if ($dec -eq 0) { $s = [string]::Format($inv, '{0:0}', $r) }
    else {
        $fmt = '{0:0.' + ('#' * $dec) + '}'
        $s = [string]::Format($inv, $fmt, $r)
    }
    return ($s.Replace('.', $DecimalSeparator) + ' ' + $unit)
}

function Get-PaddedDigits {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory = $true)][int]$Width
    )
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -ge '0' -and $c -le '9') {
            $j = $i
            while ($j -lt $Text.Length -and $Text[$j] -ge '0' -and $Text[$j] -le '9') { $j++ }
            [void]$sb.Append($Text.Substring($i, $j - $i).PadLeft($Width, '0'))
            $i = $j
        }
        else {
            [void]$sb.Append($c)
            $i++
        }
    }
    return $sb.ToString()
}

function Get-V2NaturalKeys {
    param([Parameter(Mandatory = $true)][string[]]$Names)
    $maxDigits = 0
    foreach ($n in $Names) {
        foreach ($m in [regex]::Matches($n, '\d+')) {
            if ($m.Value.Length -gt $maxDigits) { $maxDigits = $m.Value.Length }
        }
    }
    $keys = [string[]]::new($Names.Count)
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $keys[$i] = Get-PaddedDigits -Text $Names[$i] -Width $maxDigits
    }
    return $keys
}

function ConvertTo-JsMetaObject {
    # DataContractJsonSerializer-style compact object, keys in the given
    # order, forward slashes escaped as '\/'.
    param([Parameter(Mandatory = $true)][object]$Object)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{')
    $first = $true
    foreach ($prop in $Object.PSObject.Properties) {
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        $name = Get-JavaScriptString ([string]$prop.Name)
        # Get-JavaScriptString also encodes <>&' which JSON does not need,
        # but the key names here are plain ASCII identifiers.
        [void]$sb.Append($name)
        [void]$sb.Append(':')
        $v = $prop.Value
        if ($v -is [string]) {
            $enc = Get-JavaScriptString $v
            [void]$sb.Append($enc.Replace('/', '\/'))
        }
        else {
            [void]$sb.Append(([long]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture))
        }
    }
    [void]$sb.Append('}')
    return $sb.ToString()
}

function Get-HtmlEncoded {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-JsStringInner {
    # Inner (unquoted) JS string for use inside the already-quoted
    # title: "..." SNAPMETA field.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )
    $q = Get-JavaScriptString $Value
    return $q.Substring(1, $q.Length - 2)
}

function Get-UnixSeconds {
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc')
    return [int64]([datetime]::UtcNow - $epoch).TotalSeconds
}

function Read-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = [System.Text.UTF8Encoding]::new($false, $true)
    if ($hasBom) { $text = $enc.GetString($bytes, 3, $bytes.Length - 3) }
    else         { $text = $enc.GetString($bytes) }
    return @{ Text = $text; HasBom = $hasBom }
}

# ---------------------------------------------------------------------------
# V2 data-line parsing (prefix only: name / parent / refs)
# ---------------------------------------------------------------------------

$script:PLinePrefixRx = [regex]::new(
    '^p\(\["((?:\\.|[^"\\])*)",(-?\d+),"((?:\\.|[^"\\])*)"(.*)$',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
)

function ConvertFrom-PLine {
    # Split a p([...]) line into folder-item / parent / refs / rest without
    # re-parsing the (potentially huge) file list. The folder item is the
    # already-escaped inner JSON string 'name*size*date'.
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Index = 0
    )
    $m = $script:PLinePrefixRx.Match($Line)
    if (-not $m.Success) {
        $excerpt = $Line.Substring(0, [Math]::Min(80, $Line.Length))
        throw ('{0}: cannot parse data line {1}: {2}' -f $Path, ($Index + 1), $excerpt)
    }
    $folderItem = $m.Groups[1].Value
    $parts = $folderItem.Split('*')
    if ($parts.Count -ne 3) {
        throw ('{0}: dirs[{1}][0] must be ''name*size*date''' -f $Path, $Index)
    }
    # Decode the (JS-escaped) folder name via JSON.
    try {
        $name = [string](ConvertFrom-Json -InputObject ('"' + $parts[0] + '"'))
    }
    catch {
        $name = $parts[0]
    }
    $sizeStr = $parts[1]
    if ($sizeStr -eq '-1') { $size = [long]-1 }
    else {
        $size = ConvertFrom-Base36 -Value $sizeStr -Path $Path -WhatValue ("dirs[$Index] folder size")
    }
    $ts = ConvertFrom-Base36 -Value $parts[2] -Path $Path -WhatValue ("dirs[$Index] folder date")
    $parent = [int]$m.Groups[2].Value
    $refsStr = $m.Groups[3].Value
    $refs = New-Object System.Collections.Generic.List[int]
    if ($refsStr -ne '') {
        foreach ($r in ($refsStr -split '\*')) {
            if ($r -notmatch '^\d+$') {
                throw ('{0}: dirs[{1}] has a non-decimal subfolder id: ''{2}''' -f $Path, $Index, $r)
            }
            $refs.Add([int]$r)
        }
    }
    return [pscustomobject]@{
        Raw        = $Line
        FolderItem = $folderItem
        Name       = $name
        Size       = $size
        Ts         = $ts
        Parent     = $parent
        Refs       = $refs
        RefsStr    = $refsStr
        Rest       = $m.Groups[4].Value
        IsRoot     = ($parent -eq -1)
    }
}

function Get-RemappedPLine {
    # Rebuild a non-root p([...]) line with parent/refs shifted by $Offset.
    # Direct children of the old root (parent 0) stay parent 0 so they hang
    # off the new synthetic root. The file list (Rest) is preserved
    # byte-for-byte.
    param(
        [Parameter(Mandatory = $true)]$Parsed,
        [Parameter(Mandatory = $true)][int]$Offset
    )
    if ($Parsed.IsRoot) {
        throw 'Get-RemappedPLine cannot emit a root entry'
    }
    if ($Parsed.Parent -eq 0) { $parent = 0 }
    else                      { $parent = $Parsed.Parent + $Offset }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('p(["')
    [void]$sb.Append($Parsed.FolderItem)
    [void]$sb.Append('",')
    [void]$sb.Append($parent)
    [void]$sb.Append(',"')
    $first = $true
    foreach ($r in $Parsed.Refs) {
        if (-not $first) { [void]$sb.Append('*') }
        $first = $false
        [void]$sb.Append(($r + $Offset))
    }
    [void]$sb.Append('"')
    [void]$sb.Append($Parsed.Rest)
    return $sb.ToString()
}

function Get-SnapDataLines {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $startTag = '// [SNAPDATA]'
    $endTag   = '// [/SNAPDATA]'
    $sIdx = $Text.IndexOf($startTag, [System.StringComparison]::Ordinal)
    $eIdx = $Text.IndexOf($endTag,   [System.StringComparison]::Ordinal)
    if ($sIdx -lt 0 -or $eIdx -lt 0 -or $eIdx -le $sIdx) {
        throw ('{0}: not a Snap2HTML 2.5+ snapshot ([SNAPDATA] markers missing)' -f $Path)
    }
    $region = $Text.Substring($sIdx + $startTag.Length, ($eIdx - $sIdx - $startTag.Length))
    $parsed = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($line in ($region -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line.Trim() -eq '') { continue }
        $parsed.Add((ConvertFrom-PLine -Line $line -Path $Path -Index $i))
        $i++
    }
    if ($parsed.Count -lt 1) {
        throw ('{0}: no p(...) data lines found' -f $Path)
    }
    if (-not $parsed[0].IsRoot) {
        throw ('{0}: the first folder entry must be a root folder' -f $Path)
    }
    return $parsed
}

function Get-SnapMeta {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $sIdx = $Text.IndexOf('// [SNAPMETA]', [System.StringComparison]::Ordinal)
    $eIdx = $Text.IndexOf('// [/SNAPMETA]', [System.StringComparison]::Ordinal)
    if ($sIdx -lt 0 -or $eIdx -lt 0 -or $eIdx -le $sIdx) {
        throw ('{0}: [SNAPMETA] block missing' -f $Path)
    }
    $block = $Text.Substring($sIdx, ($eIdx - $sIdx))
    function Grab([string]$Pattern, [string]$Label) {
        $m = [regex]::Match($block, $Pattern)
        if (-not $m.Success) { throw ('{0}: could not find snap.{1}' -f $Path, $Label) }
        return $m.Groups[1].Value
    }
    $dataVer = [int](Grab '(?m)^\s*dataVersion:\s*(\d+)' 'dataVersion')
    if ($dataVer -ne 2) {
        throw ('{0}: unsupported data version {1} (need Snap2HTML 2.5+ / dataVersion 2)' -f $Path, $dataVer)
    }
    return [pscustomobject]@{
        Title       = Grab 'title:\s*"((?:[^"\\]|\\.)*)"' 'title'
        Timestamp   = [int64](Grab '(?m)^\s*timestamp:\s*(\d+)' 'timestamp')
        NumFiles    = [int64](Grab '(?m)^\s*numFiles:\s*(\d+)' 'numFiles')
        NumDirs     = [int64](Grab '(?m)^\s*numDirs:\s*(\d+)' 'numDirs')
        Bytes       = [int64](Grab '(?m)^\s*bytes:\s*(\d+)' 'bytes')
        AppName     = Grab 'appName:\s*"((?:[^"\\]|\\.)*)"' 'appName'
        AppLink     = Grab 'appLink:\s*"((?:[^"\\]|\\.)*)"' 'appLink'
        AppVersion  = Grab 'appVersion:\s*"((?:[^"\\]|\\.)*)"' 'appVersion'
        DataVersion = $dataVer
    }
}

function Unescape-JsString {
    param([Parameter(Mandatory = $true)][string]$Value)
    try { return [string](ConvertFrom-Json -InputObject ('"' + $Value + '"')) }
    catch { return $Value }
}

# ---------------------------------------------------------------------------
# Load inputs
# ---------------------------------------------------------------------------

$snapshots = @()
foreach ($path in $resolvedInputs) {
    Write-Host ('Reading {0}' -f $path)
    $read = Read-Utf8File -Path $path
    $meta = Get-SnapMeta -Text $read.Text -Path $path
    $lines = Get-SnapDataLines -Text $read.Text -Path $path
    if ($lines.Count -ne [int]$meta.NumDirs) {
        throw ('{0}: snap.numDirs is {1} but the data contains {2} folders' -f $path, $meta.NumDirs, $lines.Count)
    }
    $snapshots += [pscustomobject]@{
        Path     = $path
        Name     = (Split-Path -Leaf $path)
        Meta     = $meta
        Lines    = $lines
        Root     = $lines[0]
        Children = @($lines | Select-Object -Skip 1)
    }
}

foreach ($snap in $snapshots) {
    $nRoot = 0
    foreach ($e in $snap.Lines) { if ($e.IsRoot) { $nRoot++ } }
    if ($nRoot -ne 1) {
        throw ('{0}: expected a single root folder, found {1}' -f $snap.Path, $nRoot)
    }
    foreach ($e in $snap.Children) {
        if ($e.Parent -lt 0 -or $e.Parent -ge $snap.Lines.Count) {
            throw ('{0}: folder ''{1}'' has parent id {2} out of range' -f $snap.Path, $e.Name, $e.Parent)
        }
    }
}

# ---------------------------------------------------------------------------
# Flatten every input's show folders under a synthetic $Title root
# ---------------------------------------------------------------------------

# Final layout:
#   index 0              = synthetic root ($Title)
#   1 .. n0              = non-root folders of input 0 (ids unchanged)
#   n0+1 ..              = non-root folders of input 1, ids shifted by n0
#   ...
# Direct children of each old root (parent 0) become children of the new root.

$outLines = New-Object System.Collections.Generic.List[string]
$topLevel = New-Object System.Collections.Generic.List[object]   # @{ Id; Name }
$offset = 0
$rootTs = [int64]0
$rootUnreadable = $false
$dupNames = @{}

foreach ($snap in $snapshots) {
    $nKeep = $snap.Children.Count
    Write-Host ('  {0}: {1} folders (dropping root ''{2}'', keeping {3} show folders)' -f `
        $snap.Name, $snap.Lines.Count, $snap.Root.Name, $nKeep)

    if ($snap.Root.Size -eq -1) { $rootUnreadable = $true }
    if ($snap.Root.Ts -gt $rootTs) { $rootTs = $snap.Root.Ts }

    foreach ($childId in $snap.Root.Refs) {
        if ($childId -le 0 -or $childId -ge $snap.Lines.Count) {
            throw ('{0}: root references invalid subfolder id {1}' -f $snap.Path, $childId)
        }
        $child = $snap.Lines[$childId]
        $newId = $childId + $offset
        $key = $child.Name.ToLowerInvariant()
        if ($dupNames.ContainsKey($key)) {
            Write-Warning ('duplicate top-level folder name ''{0}'' (from {1} and {2}); keeping both' -f `
                $child.Name, $dupNames[$key], $snap.Name)
        }
        else { $dupNames[$key] = $snap.Name }
        $topLevel.Add([pscustomobject]@{ Id = $newId; Name = $child.Name })
    }

    foreach ($e in $snap.Children) {
        if ($offset -eq 0) {
            $outLines.Add($e.Raw)
        }
        else {
            $outLines.Add((Get-RemappedPLine -Parsed $e -Offset $offset))
        }
    }
    $offset += $nKeep
}

$nDirs = $outLines.Count + 1   # + synthetic root
$nFiles = [int64]0
$nBytes = [int64]0
foreach ($snap in $snapshots) {
    $nFiles += $snap.Meta.NumFiles
    $nBytes += $snap.Meta.Bytes
}

if (-not $KeepOrder -and $topLevel.Count -gt 1) {
    $names = [string[]]::new($topLevel.Count)
    $ids   = [int[]]::new($topLevel.Count)
    for ($k = 0; $k -lt $topLevel.Count; $k++) {
        $names[$k] = $topLevel[$k].Name
        $ids[$k]   = $topLevel[$k].Id
    }
    $keys = Get-V2NaturalKeys -Names $names
    [Array]::Sort($keys, $ids, [System.StringComparer]::OrdinalIgnoreCase)
    $rootRefsStr = ($ids -join '*')
}
else {
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($t in $topLevel) { $ids.Add([int]$t.Id) }
    $rootRefsStr = ($ids -join '*')
}

if ($rootUnreadable) { $deep36 = '-1' }
else                 { $deep36 = ConvertTo-Base36 ([long]$nBytes) }

$nowUnix = Get-UnixSeconds
$metaObj = [pscustomobject]([ordered]@{
    linkRoot  = ''
    numDirs   = $nDirs
    numFiles  = $nFiles
    sourceDir = $Title
    timestamp = $nowUnix
    title     = $Title
    totBytes  = $nBytes
})
$metaJson = ConvertTo-JsMetaObject -Object $metaObj

$nameInner = (Get-JavaScriptString $Title)
$nameInner = $nameInner.Substring(1, $nameInner.Length - 2)
$rootLine = 'p(["{0}*{1}*{2}",-1,"{3}",{4}])' -f `
    $nameInner, $deep36, (ConvertTo-Base36 $rootTs), $rootRefsStr, $metaJson

$dirLines = New-Object System.Collections.Generic.List[string]
$dirLines.Add($rootLine)
foreach ($ln in $outLines) { $dirLines.Add($ln) }
$dirData = ($dirLines -join "`n") + "`n"

Write-Host ('Combined {0} show folders under root ''{1}'' ({2} folders, {3} files)' -f `
    $topLevel.Count, $Title, $nDirs, $nFiles)

# ---------------------------------------------------------------------------
# Fill template.html
# ---------------------------------------------------------------------------

$tplRead = Read-Utf8File -Path $TemplateFile
$template = $tplRead.Text
if ($template.IndexOf('[DIR DATA]', [System.StringComparison]::Ordinal) -lt 0) {
    throw ('{0}: does not look like Snap2HTML template.html ([DIR DATA] placeholder missing)' -f $TemplateFile)
}

$baseMeta = $snapshots[0].Meta
$appName = Unescape-JsString $baseMeta.AppName
$appLink = Unescape-JsString $baseMeta.AppLink
$appVer  = Unescape-JsString $baseMeta.AppVersion
if ([string]::IsNullOrWhiteSpace($appName)) { $appName = 'Snap2HTML' }
if ([string]::IsNullOrWhiteSpace($appLink)) { $appLink = 'https://www.rlvision.com' }
if ([string]::IsNullOrWhiteSpace($appVer))  { $appVer  = '2.52' }

$enUS = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
$now  = Get-Date
$genDate = $now.ToString('M/d/yyyy', $enUS)
$genTime = $now.ToString('h:mm tt', $enUS)
$totSize = Get-CSharpFileSize -Bytes $nBytes

$pageTitleHtml = Get-HtmlEncoded $Title
$bodyTitle     = (Get-HtmlEncoded $Title).Replace('\', '\<wbr>')
$pageTitleJs   = Get-JsStringInner $Title

# Longer tokens first so [PAGE TITLE JS] is not eaten by [PAGE TITLE].
$replacements = [ordered]@{
    '[PAGE TITLE JS]' = $pageTitleJs
    '[PAGE TITLE]'    = $pageTitleHtml
    '[BODY TITLE]'    = $bodyTitle
    '[APP NAME]'      = (Get-HtmlEncoded $appName)
    '[APP VER]'       = (Get-HtmlEncoded $appVer)
    '[APP LINK]'      = $appLink
    '[GEN TIMESTAMP]' = ([string]$nowUnix)
    '[GEN DATE]'      = $genDate
    '[GEN TIME]'      = $genTime
    '[NUM FILES]'     = ([string]$nFiles)
    '[NUM DIRS]'      = ([string]$nDirs)
    '[TOT BYTES]'     = ([string]$nBytes)
    '[TOT SIZE]'      = $totSize
    '[DATA VER]'      = '2'
    '[DIR DATA]'      = $dirData
}

$output = $template
foreach ($key in $replacements.Keys) {
    $count = ([regex]::Matches($output, [regex]::Escape($key))).Count
    if ($count -lt 1 -and $key -ne '[DIR DATA]') {
        Write-Warning ('template placeholder {0} was not found' -f $key)
    }
    $output = $output.Replace($key, [string]$replacements[$key])
}

# Provenance comment next to the generator's own comment.
$inputNames = ($snapshots | ForEach-Object { $_.Name }) -join ', '
$today = $now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$note = '<!-- Consolidated from {0} using consolidate_shows.ps1 on {1} -->' -f $inputNames, $today
$rxNote = [regex]'(?m)^(<!-- This file was generated by .*?-->\r?)$'
if (($rxNote.Matches($output)).Count -eq 1) {
    $output = $rxNote.Replace($output, ('${1}' + "`n" + $note.Replace('$', '$$')), 1)
}

$leftover = [regex]::Match($output,
    '\[(PAGE TITLE JS|PAGE TITLE|BODY TITLE|DIR DATA|NUM FILES|NUM DIRS|TOT BYTES|TOT SIZE|GEN DATE|GEN TIME|GEN TIMESTAMP|APP NAME|APP VER|APP LINK|DATA VER)\]')
if ($leftover.Success) {
    throw ('template placeholder {0} was not replaced' -f $leftover.Value)
}

$outDir = Split-Path -Parent $OutputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
# Match template.html: UTF-8, no BOM, LF line endings (already LF from the template).
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($OutputFile, $output, $utf8NoBom)

Write-Host ''
Write-Host ('Wrote {0}' -f $OutputFile)
Write-Host ('  Title:   {0}' -f $Title)
Write-Host ('  Root:    {0} ({1} show folders from {2} snapshots)' -f $Title, $topLevel.Count, $snapshots.Count)
Write-Host ('  Folders: {0}' -f $nDirs)
Write-Host ('  Files:   {0}' -f $nFiles)
Write-Host ('  Total:   {0}' -f $totSize)
