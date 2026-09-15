<#
.SYNOPSIS
    Consolidates two or more Snap2HTML snapshot files into a single snapshot.

.DESCRIPTION
    Snap2HTML (http://www.rlvision.com) generates self-contained HTML snapshots
    of a folder tree. Two on-disk data formats exist; this script auto-detects
    the format of every input file and refuses to mix formats in one merge.

    V1 - Snap2HTML 2.0 to 2.14 ("D.p" format). The data lives in a JavaScript
    array `dirs`, one "D.p([...])" line per folder:

        [ "dirpath*0*modified date",           # item 0 (forward slashes)
          "filename*size*modified date",       # one item per file inside
          ...
          <int: total size of the files above>,
          "id1*id2*..."                        # indices (into dirs) of
        ]                                      # subfolders ("" if none)

    V2 - Snap2HTML 2.5+ ("p" format, dataVersion 2). The data lives between
    the "// [SNAPDATA]" and "// [/SNAPDATA]" markers, one "p([...])" line per
    folder:

        [ "foldername*size*date",              # name only; size is the
                                               # RECURSIVE subtree total in
                                               # base 36 ("-1" = unreadable);
                                               # date is a base-36 unix
                                               # timestamp
          <int: parent folder id>,              # -1 for root folders
          "id1*id2*...",                        # subfolder ids
          "filename*size*date",                 # one item per file (base-36
          ...                                   # size and date)
          {linkRoot:..., numDirs:..., numFiles:..., sourceDir:...,
           timestamp:..., title:..., totBytes:...}   # root folders only
        ]

    Ids are relative to the owning root folder. A file may contain several
    roots (each new root resets the id space), which the template displays as
    a multi-root listing.

    Merging:

      * Same root folder (V1 and V2): the folder tree of each additional
        snapshot is appended with every subfolder reference id remapped; the
        root entry (and any folder found in more than one snapshot) is
        merged - file lists are unioned by name, sizes summed (V2 recursive
        sizes are recomputed bottom-up), subfolder references unioned;
        header stats are recomputed.
      * Different root folders (V2 only): the snapshots are combined into one
        multi-root snapshot, a capability the V2 format supports natively.
        The viewer renders such a snapshot under a synthetic parent node
        labelled with the snapshot title, so merging two folders that share a
        name (say E:\shows and H:\shows) displays that name twice - use
        -FlattenRoot.
      * Subfolder references of merged folders are sorted by folder name
        using a natural sort ("2" before "10", case-insensitive), matching
        Snap2HTML's own output order (disable with -KeepOrder).
      * the first input file is used as the template: everything outside the
        data block and the counters is preserved byte-for-byte (plus a
        "<!-- Merged from ... -->" provenance comment; a UTF-8 BOM, if
        present, is preserved)
      * every input is validated and the output is re-parsed and verified
        before the script reports success

    Options:

      * -FlattenRoot (V2 only) folds every root folder of every input into
        ONE root, so the result is a plain single-root listing instead of a
        multi-root snapshot. Folders are matched by their path relative to
        their original root, so identically named folders coming from
        different roots are merged (file lists unioned, sizes recomputed).
        The surviving root is named after -Title, or after the first
        snapshot's root folder when no title is given. When the inputs
        disagree about the root's sourceDir or linkRoot, the root is re-based
        on that name and file linking is turned off, because a single root
        can only carry one link root.
      * -Title TEXT replaces the page title everywhere it is shown: the
        <title> tag, the <h1> heading, window.snap.title and every root's
        metadata "title". Use it to drop the generator's "Snapshot of D:\..."
        wording.

    This is a port of merge_snap2html.py and produces byte-identical output.

    Works with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    PS> .\merge_snap2html.ps1 shows\shows-A_R.html shows\shows-S_Z.html -OutputFile shows\shows-A_Z.html

    Merges the two snapshots into shows\shows-A_Z.html.

.EXAMPLE
    PS> .\merge_snap2html.ps1 a.html b.html c.html -KeepOrder -o all.html

    Merges three snapshots, keeping raw snapshot order in folder listings.

.EXAMPLE
    PS> .\merge_snap2html.ps1 shows\shows-A_2_R.html shows\shows-S_2_Z.html -FlattenRoot -Title Shows -o shows\shows-A_2_Z.html

    Folds the E:\shows and H:\shows snapshots into a single root folder
    called "Shows", titled "Shows", instead of a two-root listing that shows
    "shows" twice under a synthetic "Snapshot of E:\shows" parent.

.NOTES
    If script execution is blocked by policy, run it with:
    powershell -ExecutionPolicy Bypass -File .\merge_snap2html.ps1 ...
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InputFiles,

    [Parameter()]
    [Alias('o')]
    [string]$OutputFile = 'merged.html',

    [Parameter()]
    [switch]$KeepOrder,

    [Parameter()]
    [switch]$FlattenRoot,

    [Parameter()]
    [object]$Title = $null
)

$ErrorActionPreference = 'Stop'

# Distinguish "no -Title given" from an empty title string.
$script:HasTitle = ($null -ne $Title)
if ($script:HasTitle) { $Title = [string]$Title }

$script:MarkerStart = 'Array.prototype.p = Array.prototype.push;'
$script:MarkerEnd   = 'delete(Array.prototype.p)'

$script:V2SnapDataStart = '// [SNAPDATA]'
$script:V2SnapDataEnd   = '// [/SNAPDATA]'
$script:V2SnapMetaStart = '// [SNAPMETA]'
$script:V2SnapMetaEnd   = '// [/SNAPMETA]'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function New-CSHashtable {
    # A case-SENSITIVE hashtable (PowerShell's @{} literals are case-insensitive;
    # a plain .NET Hashtable matches the behaviour of Python dicts used by
    # merge_snap2html.py).
    return (New-Object System.Collections.Hashtable)
}

function Get-JsonString {
    # Serialize a string as a JSON string literal, escaping only what must be
    # escaped (non-ASCII characters are written through raw, matching the
    # output of Python's json.dumps(..., ensure_ascii=False) and Snap2HTML's
    # own output).
    param([Parameter(Mandatory = $true)][string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if     ($code -eq 34)  { [void]$sb.Append('\"') }    # double quote
        elseif ($code -eq 92)  { [void]$sb.Append('\\') }    # backslash
        elseif ($code -eq 10)  { [void]$sb.Append('\n') }
        elseif ($code -eq 13)  { [void]$sb.Append('\r') }
        elseif ($code -eq 9)   { [void]$sb.Append('\t') }
        elseif ($code -eq 8)   { [void]$sb.Append('\b') }
        elseif ($code -eq 12)  { [void]$sb.Append('\f') }
        elseif ($code -lt 32)  { [void]$sb.AppendFormat('\u{0:x4}', $code) }
        else                   { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-JavaScriptString {
    # Mirror System.Web's HttpUtility.JavaScriptStringEncode() with default
    # settings - what Snap2HTML 2.5+ uses for names inside data lines. Like
    # Get-JsonString, but '<', '>', '&', ''' and U+0085/U+2028/U+2029 are
    # escaped as \uxxxx as well.
    param([Parameter(Mandatory = $true)][string]$Value)
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
        else                   { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-HumanSize {
    # Same formatting as the template's bytesToSize().
    param([Parameter(Mandatory = $true)][long]$Bytes)
    $kb = 1024L; $mb = 1048576L; $gb = 1073741824L; $tb = 1099511627776L
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 0 -and $Bytes -lt $kb) { return ('' + $Bytes + ' bytes') }
    if ($Bytes -lt $mb) { return [string]::Format($inv, '{0:0} KB',  $Bytes / $kb) }
    if ($Bytes -lt $gb) { return [string]::Format($inv, '{0:0.0} MB', $Bytes / $mb) }
    if ($Bytes -lt $tb) { return [string]::Format($inv, '{0:0.00} GB', $Bytes / $gb) }
    return [string]::Format($inv, '{0:0.00} TB', $Bytes / $tb)
}

function Get-CSharpFileSize {
    # Mirror the Snap2HTML 2.5+ generator's Utils.BytesToFilesize():
    # [Math]::Round (banker's rounding) and the shortest decimal
    # representation of the rounded value - what goes into the "[TOT SIZE]"
    # placeholder. The decimal separator depends on the locale of the machine
    # that generated the file, so the input's separator is passed through.
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

function ConvertTo-Base36 {
    # Base 36 with uppercase digits, like the generator's
    # Utils.DecimalToArbitrarySystem().
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
    # Base 36 -> long, with validation (input may use any case).
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WhatValue
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

function ConvertTo-DCJS {
    # Serialize a parsed metadata object the way the generator's
    # DataContractJsonSerializer does: compact separators, keys in the order
    # they were parsed, forward slashes escaped as '\/'. Only the scalar
    # shapes that appear in root metadata objects are supported.
    param([Parameter(Mandatory = $true)][object]$Object)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{')
    $first = $true
    foreach ($prop in $Object.PSObject.Properties) {
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        [void]$sb.Append((Get-JsonString ([string]$prop.Name)))
        [void]$sb.Append(':')
        $v = $prop.Value
        if ($null -eq $v)            { [void]$sb.Append('null') }
        elseif ($v -is [bool])       { [void]$sb.Append(('' + $v).ToLower()) }
        elseif ($v -is [string])     { [void]$sb.Append((Get-JsonString $v)) }
        elseif ($v -is [sbyte] -or $v -is [byte] -or $v -is [int16] -or $v -is [uint16] -or
                $v -is [int] -or $v -is [uint32] -or $v -is [long] -or $v -is [double] -or
                $v -is [decimal])    { [void]$sb.Append((Get-NumberToInvariantString $v)) }
        else { throw ('cannot serialize metadata value of type {0}' -f $v.GetType().Name) }
    }
    [void]$sb.Append('}')
    # '/' appears only inside string values, so a global replace is safe and
    # matches the DataContractJsonSerializer output byte-for-byte.
    return $sb.ToString().Replace('/', '\/')
}

function Get-NumberToInvariantString {
    param([Parameter(Mandatory = $true)][object]$Number)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Number -is [double] -or $Number -is [decimal] -or $Number -is [single]) {
        return $Number.ToString('G15', $inv)
    }
    return $Number.ToString($inv)
}

function Get-PaddedDigits {
    # Pad every run of digits in the string to $Width with leading zeros
    # (mirrors the generator's OrderByNatural padding step).
    param(
        [Parameter(Mandatory = $true)][string]$Text,
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
    # Sort keys for a sibling set, mirroring the generator's OrderByNatural():
    # pad digit runs to the widest digit run in the set, compare
    # case-insensitively. This makes 'folder 2' sort before 'folder 10'.
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

function Get-EntryPath {
    # "dirpath*0*date" -> "dirpath"
    param([Parameter(Mandatory = $true)][object]$Entry)
    $e = @($Entry)
    $first = $e[0]
    return ((([string]$first) -split '\*', 2)[0])
}

function Get-EntryName {
    # "E:/shows/foo bar" -> "foo bar"
    param([Parameter(Mandatory = $true)][object]$Entry)
    $p = Get-EntryPath $Entry
    $i = $p.LastIndexOf([char]'/')
    if ($i -ge 0) { return $p.Substring($i + 1) }
    return $p
}

function Get-FileNamePart {
    # "filename*size*date" -> "filename"
    param([Parameter(Mandatory = $true)][string]$FileItem)
    return (($FileItem -split '\*', 2)[0])
}

function Get-FileSizePart {
    # "filename*size*date" -> size (long)
    param([Parameter(Mandatory = $true)][string]$FileItem)
    return [long](($FileItem -split '\*', 3)[1])
}

function Get-RefIds {
    # "1*2*4" -> @(1, 2, 4);  "" -> @()
    param([Parameter(Mandatory = $true)][string]$Refs)
    $list = New-Object System.Collections.Generic.List[int]
    if ($Refs -ne '') {
        foreach ($x in ($Refs -split '\*')) {
            if ($x -ne '') { $list.Add([int]$x) }
        }
    }
    return $list.ToArray()
}

function Get-RegexGroup1 {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $m = [regex]::Match($Text, $Pattern)
    if (-not $m.Success) {
        throw ('{0}: could not find {1}' -f $Path, $Label)
    }
    return $m.Groups[1].Value
}

function Read-SnapshotFile {
    # Read a snapshot file as strict UTF-8. A leading BOM is stripped and
    # reported so the writer can preserve it (Snap2HTML 2.5+ writes one).
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('cannot read {0}: file does not exist' -f $Path)
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = [System.Text.UTF8Encoding]::new($false, $true)   # strict UTF-8
    try {
        if ($hasBom) { $text = $enc.GetString($bytes, 3, $bytes.Length - 3) }
        else         { $text = $enc.GetString($bytes) }
    }
    catch {
        throw ('{0}: file is not valid UTF-8 ({1})' -f $Path, $_.Exception.Message)
    }
    return @{ Text = $text; HasBom = $hasBom }
}

function Get-SnapshotFormat {
    # 'V1' (Snap2HTML 2.0-2.14) or 'V2' (Snap2HTML 2.5+)
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ([regex]::IsMatch($Text, '(?m)^// \[SNAPDATA\]\s*$')) { return 'V2' }
    $i = $Text.IndexOf($script:MarkerStart, [System.StringComparison]::Ordinal)
    if ($i -ge 0) { return 'V1' }
    throw ('{0}: does not look like a Snap2HTML snapshot (neither V1 nor V2 data markers found)' -f $Path)
}

# ---------------------------------------------------------------------------
# Parsing (V1)
# ---------------------------------------------------------------------------

function Test-SnapshotDirs {
    # Structural validation of a dirs array.
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Dirs,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $seenPaths = New-CSHashtable
    $referenced = New-CSHashtable

    for ($idx = 0; $idx -lt $Dirs.Count; $idx++) {
        $entry = @($Dirs[$idx])
        $n = $entry.Count
        if ($n -lt 3) {
            throw ('{0}: dirs[{1}] is malformed (must be a list of >= 3 items)' -f $Path, $idx)
        }
        $head = $entry[0]
        if (-not ($head -is [string])) {
            throw ('{0}: dirs[{1}][0] must be ''path*0*date''' -f $Path, $idx)
        }
        if ((([regex]::Matches($head, '\*')).Count) -lt 2) {
            throw ('{0}: dirs[{1}][0] must be ''path*0*date''' -f $Path, $idx)
        }
        for ($k = 1; $k -le ($n - 3); $k++) {
            $item = $entry[$k]
            if (-not ($item -is [string])) {
                throw ('{0}: dirs[{1}] has a malformed file item' -f $Path, $idx)
            }
            if ((([regex]::Matches($item, '\*')).Count) -lt 2) {
                throw ('{0}: dirs[{1}] has a malformed file item: ''{2}''' -f $Path, $idx, $item)
            }
        }
        $sizeVal = $entry[$n - 2]
        if (-not ($sizeVal -is [int] -or $sizeVal -is [long] -or $sizeVal -is [double])) {
            throw ('{0}: dirs[{1}] size field must be an integer' -f $Path, $idx)
        }
        if (-not ($entry[$n - 1] -is [string])) {
            throw ('{0}: dirs[{1}] subfolder reference field must be a string' -f $Path, $idx)
        }

        $p = Get-EntryPath $entry
        if ($seenPaths.ContainsKey($p)) {
            throw ('{0}: duplicate folder path: {1}' -f $Path, $p)
        }
        $seenPaths[$p] = $true

        $refsStr = $entry[$n - 1]
        $refsStr = [string]$refsStr
        foreach ($ref in (Get-RefIds $refsStr)) {
            if ($ref -le 0 -or $ref -ge $Dirs.Count) {
                throw ('{0}: dirs[{1}] references invalid subfolder id {2}' -f $Path, $idx, $ref)
            }
            if ($ref -eq $idx) {
                throw ('{0}: dirs[{1}] references itself' -f $Path, $idx)
            }
            if ($referenced.ContainsKey($ref)) {
                $refPath = Get-EntryPath $Dirs[$ref]
                throw ('{0}: folder {1} ({2}) is referenced by more than one parent' -f $Path, $ref, $refPath)
            }
            $referenced[$ref] = $true
        }
    }

    $orphans = @()
    for ($i = 1; $i -lt $Dirs.Count; $i++) {
        if (-not $referenced.ContainsKey($i)) { $orphans += $i }
    }
    if ($orphans.Count -gt 0) {
        $names = @()
        foreach ($o in ($orphans | Select-Object -First 5)) {
            $names += (Get-EntryPath $Dirs[$o])
        }
        [Console]::Error::WriteLine(
            ('WARNING: {0}: {1} folder(s) are not referenced by any parent and will not show in the tree view: {2}' -f `
                $Path, $orphans.Count, ($names -join ', ')))
    }
}

function ConvertFrom-Snapshot {
    # Parse one V1 snapshot file, validating its data structure and header stats.
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('cannot read {0}: file does not exist' -f $Path)
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path

    $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)   # no BOM, throw on invalid UTF-8
    try {
        $text = [System.IO.File]::ReadAllText($resolved, $utf8Strict)
    }
    catch {
        throw ('{0}: file is not valid UTF-8 ({1})' -f $Path, $_.Exception.Message)
    }

    $sIdx = $text.IndexOf($script:MarkerStart, [System.StringComparison]::Ordinal)
    $eIdx = $text.IndexOf($script:MarkerEnd, [System.StringComparison]::Ordinal)
    if ($sIdx -lt 0 -or $eIdx -lt 0 -or $eIdx -lt $sIdx) {
        throw ('{0}: does not look like a Snap2HTML snapshot (data markers missing)' -f $Path)
    }

    $dirs = New-Object System.Collections.Generic.List[object]
    $region = $text.Substring($sIdx, ($eIdx - $sIdx))
    foreach ($line in ($region -split "`n")) {
        $stripped = $line.Trim()
        if ($stripped.StartsWith('D.p([', [System.StringComparison]::Ordinal) -and
            $stripped.EndsWith(')', [System.StringComparison]::Ordinal)) {
            $json = $stripped.Substring(4, ($stripped.Length - 5))
            try {
                $entry = @(ConvertFrom-Json -InputObject $json)
            }
            catch {
                $excerpt = $stripped.Substring(0, [Math]::Min(60, $stripped.Length))
                throw ('{0}: cannot parse data line {1}: {2}' -f $Path, $excerpt, $_.Exception.Message)
            }
            $dirs.Add($entry)
        }
    }
    if ($dirs.Count -lt 1) {
        throw ('{0}: no D.p(...) data lines found' -f $Path)
    }

    Test-SnapshotDirs -Dirs $dirs -Path $Path

    # Derived counters.
    $numFiles = 0
    $totalBytes = [long]0
    foreach ($e in $dirs) {
        $ea = @($e)
        $numFiles += ($ea.Count - 3)
        $sizeItem = $ea[$ea.Count - 2]
        $totalBytes += [long]$sizeItem
    }

    # Header metadata.
    $meta = @{}
    $meta['title']         = Get-RegexGroup1 -Text $text -Pattern '<title>(.*?)</title>' -Label '<title>' -Path $Path
    $meta['numberOfFiles'] = [long](Get-RegexGroup1 -Text $text -Pattern 'var numberOfFiles\s*=\s*(\d+);' -Label 'numberOfFiles variable' -Path $Path)
    $meta['linkFiles']     = (Get-RegexGroup1 -Text $text -Pattern 'var linkFiles\s*=\s*([^;]+);' -Label 'linkFiles variable' -Path $Path).Trim()
    $meta['linkProtocol']  = Get-RegexGroup1 -Text $text -Pattern 'var linkProtocol\s*=\s*"([^"]*)";' -Label 'linkProtocol variable' -Path $Path
    $meta['linkRoot']      = Get-RegexGroup1 -Text $text -Pattern 'var linkRoot\s*=\s*"([^"]*)";' -Label 'linkRoot variable' -Path $Path
    $meta['sourceRoot']    = Get-RegexGroup1 -Text $text -Pattern 'var sourceRoot\s*=\s*"([^"]*)";' -Label 'sourceRoot variable' -Path $Path

    $m = [regex]::Match($text, '>(\d+) files in (\d+) folders\s*\(<span id="tot_size">(\d+)</span>\)')
    if (-not $m.Success) {
        throw ('{0}: could not find the header stats line' -f $Path)
    }
    $statsFiles = [long]$m.Groups[1].Value
    $statsDirs  = [long]$m.Groups[2].Value
    $statsBytes = [long]$m.Groups[3].Value

    $rootPath = Get-EntryPath $dirs[0]

    # Cross-check the header counters against the actual data.
    if ($meta['numberOfFiles'] -ne $numFiles) {
        throw ('{0}: numberOfFiles is {1} but the data contains {2} files' -f $Path, $meta['numberOfFiles'], $numFiles)
    }
    if ($statsFiles -ne $numFiles) { throw ('{0}: header file count does not match the data' -f $Path) }
    if ($statsDirs -ne $dirs.Count) { throw ('{0}: header folder count does not match the data' -f $Path) }
    if ($statsBytes -ne $totalBytes) { throw ('{0}: header total size does not match the data' -f $Path) }
    if ($rootPath -ne $meta['sourceRoot']) {
        throw ('{0}: root entry path ({1}) does not match sourceRoot ({2})' -f $Path, $rootPath, $meta['sourceRoot'])
    }

    return [pscustomobject]@{
        Path       = $Path
        Text       = $text
        Dirs       = $dirs
        NumFiles   = $numFiles
        NumDirs    = $dirs.Count
        TotalBytes = $totalBytes
        RootPath   = $rootPath
        Meta       = $meta
    }
}

# ---------------------------------------------------------------------------
# Parsing (V2)
# ---------------------------------------------------------------------------

function ConvertFrom-V2DataLine {
    # Validate and normalize one p([...]) data line into an entry object
    # (ids still stored relative to the root; converted by the caller).
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not ($Line.StartsWith('p([', [System.StringComparison]::Ordinal) -and
              $Line.EndsWith(')', [System.StringComparison]::Ordinal))) {
        throw ('{0}: unexpected content in the data block: ''{1}''' -f $Path, $Line.Substring(0, [Math]::Min(60, $Line.Length)))
    }
    $json = $Line.Substring(2, $Line.Length - 3)
    try {
        $raw = @(ConvertFrom-Json -InputObject $json)
    }
    catch {
        throw ('{0}: cannot parse data line {1}: {2}' -f $Path, ($Index + 1), $_.Exception.Message)
    }

    if ($raw.Count -lt 3) {
        throw ('{0}: dirs[{1}] is malformed (must be an array of >= 3 items)' -f $Path, $Index)
    }
    if (-not ($raw[0] -is [string])) {
        throw ('{0}: dirs[{1}][0] (folder item) must be a string' -f $Path, $Index)
    }
    $fparts = $raw[0] -split '\*'
    if ($fparts.Count -ne 3) {
        throw ('{0}: dirs[{1}][0] must be ''name*size*date'' (exactly 2 asterisks)' -f $Path, $Index)
    }
    $name = $fparts[0]
    if ($fparts[1] -eq '-1') {
        $size = [long]-1
    }
    else {
        $size = ConvertFrom-Base36 -Value $fparts[1] -Path $Path -WhatValue "dirs[$Index][0] folder size"
        if ($size -lt 0) {
            throw ('{0}: dirs[{1}][0] folder size is negative: ''{2}''' -f $Path, $Index, $fparts[1])
        }
    }
    $ts = ConvertFrom-Base36 -Value $fparts[2] -Path $Path -WhatValue "dirs[$Index][0] folder date"

    $parentItem = $raw[1]
    if (-not ($parentItem -is [int] -or $parentItem -is [long])) {
        throw ('{0}: dirs[{1}][1] (parent id) must be an integer' -f $Path, $Index)
    }
    $parent = [int]$parentItem
    if ($parent -lt -1) {
        throw ('{0}: dirs[{1}][1] (parent id) must be -1 or non-negative' -f $Path, $Index)
    }

    if (-not ($raw[2] -is [string])) {
        throw ('{0}: dirs[{1}][2] (subfolder references) must be a string' -f $Path, $Index)
    }
    $refs = New-Object System.Collections.Generic.List[int]
    if ($raw[2] -ne '') {
        foreach ($r in ($raw[2] -split '\*')) {
            if ($r -notmatch '^\d+$') {
                throw ('{0}: dirs[{1}][2] subfolder id is not a plain decimal number: ''{2}''' -f $Path, $Index, $r)
            }
            $refs.Add([int]$r)
        }
    }

    $isRoot = ($parent -eq -1)
    $metaObj = $null
    $lastIdx = $raw.Count - 1
    if ($isRoot) {
        if ($raw.Count -lt 4 -or -not ($raw[$lastIdx] -is [System.Management.Automation.PSCustomObject])) {
            throw ('{0}: root folder entry {1} must end with a metadata object' -f $Path, $Index)
        }
        $metaObj = $raw[$lastIdx]
        foreach ($key in @('title', 'sourceDir', 'linkRoot', 'numFiles', 'numDirs', 'totBytes')) {
            if ($null -eq $metaObj.PSObject.Properties[$key]) {
                throw ('{0}: root folder entry {1} metadata lacks ''{2}''' -f $Path, $Index, $key)
            }
        }
        if (-not (($metaObj.sourceDir -is [string]) -and $metaObj.sourceDir -ne '')) {
            throw ('{0}: root folder entry {1} metadata has an empty sourceDir' -f $Path, $Index)
        }
        $fileItems = @()
        if ($lastIdx -ge 4) { $fileItems = $raw[3..($lastIdx - 1)] }   # root: files end before the metadata object
    }
    else {
        $fileItems = @()
        if ($lastIdx -ge 3) { $fileItems = $raw[3..$lastIdx] }
    }

    $files = New-Object System.Collections.Generic.List[object]
    $seen = @{}     # case-insensitive: file names on Windows filesystems
    foreach ($it in $fileItems) {
        if (-not ($it -is [string])) {
            throw ('{0}: dirs[{1}] has a non-string file item: ''{2}''' -f $Path, $Index, "$it")
        }
        $fp = $it -split '\*'
        if ($fp.Count -ne 3) {
            throw ('{0}: dirs[{1}] has a malformed file item (need exactly ''name*size*date''): ''{2}''' -f $Path, $Index, $it)
        }
        $fsize = ConvertFrom-Base36 -Value $fp[1] -Path $Path -WhatValue "file size in dirs[$Index]"
        $fts   = ConvertFrom-Base36 -Value $fp[2] -Path $Path -WhatValue "file date in dirs[$Index]"
        if ($fsize -lt 0) {
            throw ('{0}: dirs[{1}] file ''{2}'' has a negative size' -f $Path, $Index, $fp[0])
        }
        if ($fts -lt 0) {
            throw ('{0}: dirs[{1}] file ''{2}'' has a negative date' -f $Path, $Index, $fp[0])
        }
        if ($seen.ContainsKey($fp[0])) {
            throw ('{0}: dirs[{1}] contains duplicate file name ''{2}''' -f $Path, $Index, $fp[0])
        }
        $seen[$fp[0]] = $true
        $files.Add(@([string]$fp[0], [long]$fsize, [long]$fts))
    }

    return [pscustomobject]@{
        Name     = $name
        Size     = $size
        Ts       = $ts
        Parent   = $parent
        Refs     = $refs.ToArray()
        Files    = $files
        MetaObj  = $metaObj
        MetaText = $(if ($null -ne $metaObj) { ConvertTo-DCJS $metaObj } else { $null })
        Path     = $null
        Dirty    = $false
        Owner    = -1
        Deep     = [long]0
    }
}

function Set-V2Paths {
    # Fill the full path of every entry (sourceDir + names).
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $n = $Entries.Count
    foreach ($e in $Entries) {
        if ($e.Parent -eq -1) { $e.Path = [string]$e.MetaObj.sourceDir }
    }
    for ($idx = 0; $idx -lt $n; $idx++) {
        if ($null -ne $Entries[$idx].Path) { continue }
        $chain = New-Object System.Collections.Generic.List[int]
        $i = $idx
        while ($null -eq $Entries[$i].Path) {
            $chain.Add($i)
            $i = $Entries[$i].Parent
            if ($chain.Count -gt $n) {
                throw ('{0}: parent chain of folder {1} is cyclic' -f $Path, $idx)
            }
        }
        for ($k = $chain.Count - 1; $k -ge 0; $k--) {
            $j = $chain[$k]
            $pp = $Entries[$Entries[$j].Parent].Path
            if ($pp.EndsWith('\')) { $Entries[$j].Path = $pp + $Entries[$j].Name }
            else                   { $Entries[$j].Path = $pp + '\' + $Entries[$j].Name }
        }
    }
}

function ConvertFrom-SnapshotV2 {
    # Parse one V2 snapshot file, validating the data structure.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $sIdx = $Text.IndexOf($script:V2SnapDataStart, [System.StringComparison]::Ordinal)
    $eIdx = $Text.IndexOf($script:V2SnapDataEnd, [System.StringComparison]::Ordinal)
    if ($sIdx -lt 0 -or $eIdx -lt 0 -or $eIdx -lt $sIdx) {
        throw ('{0}: data block markers ([SNAPDATA]) missing' -f $Path)
    }
    $region = $Text.Substring($sIdx + $script:V2SnapDataStart.Length, ($eIdx - $sIdx - $script:V2SnapDataStart.Length))

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($region -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line.Trim() -eq '') { continue }
        $entries.Add((ConvertFrom-V2DataLine -Line $line -Index $entries.Count -Path $Path))
    }
    if ($entries.Count -lt 1) {
        throw ('{0}: no p(...) data lines found' -f $Path)
    }
    $n = $entries.Count

    # Root offsets: like the template's runtime, an entry's stored ids are
    # relative to the most recent root folder (parent == -1) at a smaller
    # array index.
    $ownerRoot = [int[]]::new($n)
    $cur = -1
    for ($idx = 0; $idx -lt $n; $idx++) {
        if ($entries[$idx].Parent -eq -1) { $cur = $idx }
        $ownerRoot[$idx] = $cur
    }
    if ($entries[0].Parent -ne -1) {
        throw ('{0}: the first folder entry must be a root folder' -f $Path)
    }

    # Convert ids to absolute and validate the reference structure.
    for ($idx = 0; $idx -lt $n; $idx++) {
        $e = $entries[$idx]
        if ($e.Parent -ne -1) {
            if ($e.Parent -lt 0) {
                throw ('{0}: dirs[{1}] parent id is negative' -f $Path, $idx)
            }
            $e.Parent = $e.Parent + $ownerRoot[$idx]
        }
        for ($k = 0; $k -lt $e.Refs.Count; $k++) {
            $e.Refs[$k] = $e.Refs[$k] + $ownerRoot[$idx]
        }
    }

    $referenced = New-CSHashtable
    for ($idx = 0; $idx -lt $n; $idx++) {
        $e = $entries[$idx]
        if ($e.Parent -ne -1) {
            if ($e.Parent -ge $n) {
                throw ('{0}: dirs[{1}] parent id {2} is out of range' -f $Path, $idx, $e.Parent)
            }
            if ($e.Parent -eq $idx) {
                throw ('{0}: dirs[{1}] is its own parent' -f $Path, $idx)
            }
        }
        foreach ($r in $e.Refs) {
            if ($r -ge $n) {
                throw ('{0}: dirs[{1}] references invalid subfolder id {2}' -f $Path, $idx, $r)
            }
            if ($r -eq $idx) {
                throw ('{0}: dirs[{1}] references itself' -f $Path, $idx)
            }
            if ($referenced.ContainsKey($r)) {
                throw ('{0}: folder {1} (''{2}'') is referenced by more than one parent' -f $Path, $r, $entries[$r].Name)
            }
            $referenced[$r] = $true
        }
    }

    Set-V2Paths -Entries $entries -Path $Path

    $seenPaths = @{}     # case-insensitive (Windows paths)
    for ($idx = 0; $idx -lt $n; $idx++) {
        $p = $entries[$idx].Path
        if ($seenPaths.ContainsKey($p)) {
            throw ('{0}: duplicate folder path: {1}' -f $Path, $p)
        }
        $seenPaths[$p] = $true
    }

    # Recompute recursive folder sizes bottom-up and check them against the
    # stored values (only for entries reachable from a root).
    $reachable = @{}
    $roots = @()
    for ($idx = 0; $idx -lt $n; $idx++) { if ($entries[$idx].Parent -eq -1) { $roots += $idx } }
    foreach ($r in $roots) {
        $stack = New-Object System.Collections.Generic.Stack[int]
        $stack.Push($r)
        while ($stack.Count -gt 0) {
            $i = $stack.Pop()
            if ($reachable.ContainsKey($i)) { continue }
            $reachable[$i] = $true
            foreach ($c in $entries[$i].Refs) { $stack.Push($c) }
        }
    }
    $unreachable = @()
    for ($i = 0; $i -lt $n; $i++) { if (-not $reachable.ContainsKey($i)) { $unreachable += $i } }
    if ($unreachable.Count -gt 0) {
        $names = @()
        foreach ($u in ($unreachable | Select-Object -First 5)) { $names += $entries[$u].Path }
        [Console]::Error::WriteLine(
            ('WARNING: {0}: {1} folder(s) are not reachable from any root folder: {2}' -f `
                $Path, $unreachable.Count, ($names -join ', ')))
    }

    $deep = New-CSHashtable
    foreach ($r in $roots) {
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push(@($r, $false))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $i = [int]$item[0]
            if ($item[1]) {
                if ($entries[$i].Size -eq -1) {
                    $deep[$i] = [long]-1
                }
                else {
                    $total = [long]0
                    foreach ($f in $entries[$i].Files) { $total += [long]$f[1] }
                    foreach ($c in $entries[$i].Refs) {
                        if ($deep[$c] -ne -1) { $total += [long]$deep[$c] }
                    }
                    $deep[$i] = $total
                }
            }
            else {
                $stack.Push(@($i, $true))
                foreach ($c in $entries[$i].Refs) {
                    if (-not $deep.ContainsKey($c)) { $stack.Push(@($c, $false)) }
                }
            }
        }
    }
    foreach ($i in $unreachable) { $deep[$i] = $entries[$i].Size }

    for ($idx = 0; $idx -lt $n; $idx++) {
        $e = $entries[$idx]
        if ($e.Size -ne -1 -and $reachable.ContainsKey($idx)) {
            if ($e.Size -ne [long]$deep[$idx]) {
                throw ('{0}: stored size of ''{1}'' ({2}) does not match the sum of its contents ({3}); the file was not generated by Snap2HTML or is corrupted' -f `
                    $Path, $e.Path, $e.Size, $deep[$idx])
            }
        }
        $e.Deep = [long]$deep[$idx]
    }

    # --- header (window.snap block) ----------------------------------------
    $m0 = $Text.IndexOf($script:V2SnapMetaStart, [System.StringComparison]::Ordinal)
    $m1 = $Text.IndexOf($script:V2SnapMetaEnd, [System.StringComparison]::Ordinal)
    if ($m0 -lt 0 -or $m1 -lt 0 -or $m1 -lt $m0) {
        throw ('{0}: header block markers ([SNAPMETA]) missing' -f $Path)
    }
    $snapmeta = $Text.Substring($m0, ($m1 + $script:V2SnapMetaEnd.Length - $m0))

    $title = Get-RegexGroup1 -Text $snapmeta -Pattern 'title:\s*"((?:[^"\\]|\\.)*)"' -Label 'snap.title' -Path $Path
    $hNumFiles = [long](Get-RegexGroup1 -Text $snapmeta -Pattern '(?m)^\s*numFiles:\s*(\d+)' -Label 'snap.numFiles' -Path $Path)
    $hNumDirs  = [long](Get-RegexGroup1 -Text $snapmeta -Pattern '(?m)^\s*numDirs:\s*(\d+)' -Label 'snap.numDirs' -Path $Path)
    $hBytes    = [long](Get-RegexGroup1 -Text $snapmeta -Pattern '(?m)^\s*bytes:\s*(\d+)' -Label 'snap.bytes' -Path $Path)
    $hDataVer  = [int](Get-RegexGroup1 -Text $snapmeta -Pattern '(?m)^\s*dataVersion:\s*(\d+)' -Label 'snap.dataVersion' -Path $Path)
    if ($hDataVer -ne 2) {
        throw ('{0}: unsupported data version {1} (this script supports version 2, Snap2HTML 2.5+)' -f $Path, $hDataVer)
    }

    # --- stats line under the page title ------------------------------------
    $m = [regex]::Match($Text, '>(\d+) files in (\d+) folders\s*\(\<span id="tot_size"\>([^<]+)\</span>\)')
    if (-not $m.Success) {
        throw ('{0}: could not find the header stats line' -f $Path)
    }
    $stats = @{
        Files   = [long]$m.Groups[1].Value
        Dirs    = [long]$m.Groups[2].Value
        TotSize = $m.Groups[3].Value.Trim()
        DecSep  = '.'
    }
    $dm = [regex]::Match($stats.TotSize, '^\d+([.,]\d+)?\s+(bytes|KB|MB|GB|TB)$')
    if ($dm.Success -and $dm.Groups[1].Value -ne '') { $stats.DecSep = $dm.Groups[1].Value.Substring(0, 1) }

    # Derived counters.
    $numFiles = [long]0
    $totalBytes = [long]0
    foreach ($e in $entries) {
        $numFiles += $e.Files.Count
        foreach ($f in $e.Files) { $totalBytes += [long]$f[1] }
    }

    # Cross-check the header counters against the actual data.
    if ($hNumFiles -ne $numFiles) {
        throw ('{0}: snap.numFiles is {1} but the data contains {2} files' -f $Path, $hNumFiles, $numFiles)
    }
    if ($hNumDirs -ne $n) { throw ('{0}: snap.numDirs does not match the data' -f $Path) }
    if ($hBytes -ne $totalBytes) { throw ('{0}: snap.bytes does not match the data' -f $Path) }
    if ($stats.Files -ne $numFiles) { throw ('{0}: header file count does not match the data' -f $Path) }
    if ($stats.Dirs -ne $n) { throw ('{0}: header folder count does not match the data' -f $Path) }
    $expectedTot = Get-CSharpFileSize -Bytes $totalBytes -DecimalSeparator $stats.DecSep
    if ($expectedTot -ne $stats.TotSize) {
        [Console]::Error::WriteLine(
            ('NOTE: {0}: formatted total size is ''{1}'' but the data adds up to ''{2}''; using the computed value for the output' -f `
                $Path, $stats.TotSize, $expectedTot))
    }

    # Per-root metadata must agree with the data as well.
    foreach ($r in $roots) {
        $sub = Get-V2Subtree -Entries $entries -Root $r
        $meta = $entries[$r].MetaObj
        if ([long]$meta.numDirs -ne $sub.Count) {
            throw ('{0}: root ''{1}'' metadata numDirs {2} != {3}' -f $Path, $entries[$r].Path, $meta.numDirs, $sub.Count)
        }
        $subFiles = [long]0
        $subBytes = [long]0
        foreach ($i in @($sub.Keys)) {
            $subFiles += $entries[$i].Files.Count
            foreach ($f in $entries[$i].Files) { $subBytes += [long]$f[1] }
        }
        if ([long]$meta.numFiles -ne $subFiles) {
            throw ('{0}: root ''{1}'' metadata numFiles mismatch' -f $Path, $entries[$r].Path)
        }
        if ([long]$meta.totBytes -ne $subBytes) {
            throw ('{0}: root ''{1}'' metadata totBytes mismatch' -f $Path, $entries[$r].Path)
        }
    }

    return [pscustomobject]@{
        Path       = $Path
        Text       = $Text
        Entries    = $entries
        Roots      = $roots
        NumFiles   = $numFiles
        NumDirs    = $n
        TotalBytes = $totalBytes
        Header     = @{ Title = $title; NumFiles = $hNumFiles; NumDirs = $hNumDirs; Bytes = $hBytes; DataVersion = $hDataVer }
        Stats      = $stats
    }
}

# ---------------------------------------------------------------------------
# Merging
# ---------------------------------------------------------------------------

function Merge-Snapshots {
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshots,
        [switch]$KeepOrder
    )

    $rootPath = $Snapshots[0].RootPath
    for ($i = 1; $i -lt $Snapshots.Count; $i++) {
        if ($Snapshots[$i].RootPath -ne $rootPath) {
            throw ('{0}: root folder is ''{1}'' but the first snapshot uses ''{2}'' - only snapshots of the same root can be merged' -f `
                $Snapshots[$i].Path, $Snapshots[$i].RootPath, $rootPath)
        }
    }

    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Snapshots[0].Dirs) { $merged.Add(@($e)) }
    $pathIndex = New-CSHashtable
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $pathIndex[(Get-EntryPath $merged[$i])] = $i
    }

    for ($sIdx = 1; $sIdx -lt $Snapshots.Count; $sIdx++) {
        $snap = $Snapshots[$sIdx]

        # Pass 1: decide the target index of every incoming folder. Folders
        # whose path already exists are merged into the existing entry; new
        # folders are appended (placeholder $null, filled in pass 2).
        $targets = [int[]]::new($snap.Dirs.Count)
        $j = 0
        foreach ($entry in $snap.Dirs) {
            $p = Get-EntryPath $entry
            if ($pathIndex.ContainsKey($p)) {
                $targets[$j] = $pathIndex[$p]
            }
            else {
                $t = $merged.Count
                $merged.Add($null)
                $pathIndex[$p] = $t
                $targets[$j] = $t
            }
            $j++
        }

        # Pass 2: fill new entries (with remapped subfolder ids) and merge
        # entries whose path already exists.
        $j = 0
        foreach ($rawEntry in $snap.Dirs) {
            $target = $targets[$j]
            $j++
            $entry = @($rawEntry)
            $n = $entry.Count

            $childRefs = @(Get-RefIds ([string]$entry[$n - 1]))
            $resolved = [int[]]::new($childRefs.Count)
            for ($k = 0; $k -lt $childRefs.Count; $k++) {
                $resolved[$k] = $targets[$childRefs[$k]]
            }

            if ($null -eq $merged[$target]) {
                # New folder: copy with remapped subfolder references.
                $newEntry = [object[]]::new($n)
                for ($k = 0; $k -lt ($n - 1); $k++) { $newEntry[$k] = $entry[$k] }
                $newEntry[$n - 1] = ($resolved -join '*')
                $merged[$target] = $newEntry
            }
            else {
                # Folder already exists: merge files and subfolder references.
                $current = @($merged[$target])
                $cn = $current.Count

                $existingNames = New-CSHashtable
                for ($k = 1; $k -le ($cn - 3); $k++) {
                    $existingNames[(Get-FileNamePart ([string]$current[$k]))] = $true
                }
                $added = New-Object System.Collections.Generic.List[object]
                for ($k = 1; $k -le ($n - 3); $k++) {
                    $fname = Get-FileNamePart ([string]$entry[$k])
                    if (-not $existingNames.ContainsKey($fname)) { $added.Add($entry[$k]) }
                }
                $addedSize = [long]0
                foreach ($f in $added) {
                    $addedSize += (Get-FileSizePart ([string]$f))
                }

                $refSet = New-CSHashtable
                $curRefs = Get-RefIds ([string]$current[$cn - 1])
                foreach ($r in $curRefs) { $refSet[$r] = $true }
                foreach ($r in $resolved) { $refSet[$r] = $true }
                $refArr = [int[]]::new($refSet.Count)
                $refSet.Keys.CopyTo($refArr, 0)
                [Array]::Sort($refArr)

                # path + old files + added files + size + refs
                $newEntry = [object[]]::new($cn + $added.Count)
                $newEntry[0] = $current[0]
                for ($k = 1; $k -le ($cn - 3); $k++) { $newEntry[$k] = $current[$k] }
                $pos = $cn - 2
                foreach ($f in $added) { $newEntry[$pos] = $f; $pos++ }
                $curSizeItem = $current[$cn - 2]
                $newEntry[$pos] = ([long]$curSizeItem + $addedSize); $pos++
                $newEntry[$pos] = ($refArr -join '*')
                $merged[$target] = $newEntry
            }
        }
    }

    for ($i = 0; $i -lt $merged.Count; $i++) {
        if ($null -eq $merged[$i]) {
            throw ('{0}: internal error: unfilled placeholder entries after merge' -f $Snapshots[0].Path)
        }
    }

    if (-not $KeepOrder) {
        # The tree view lists subfolders in reference order; sort each list by
        # folder name (case-insensitive, ordinal) so the merged snapshot is
        # ordered like Snap2HTML's own output. (Two siblings never differ only
        # by case on Windows filesystems, so sort stability is not a concern.)
        for ($i = 0; $i -lt $merged.Count; $i++) {
            $e = @($merged[$i])
            $n = $e.Count
            $refsStr = [string]$e[$n - 1]
            if ($refsStr -ne '') {
                $refs = @(Get-RefIds $refsStr)
                $keys = [string[]]::new($refs.Count)
                for ($k = 0; $k -lt $refs.Count; $k++) {
                    $childEntry = $merged[$refs[$k]]
                    $keys[$k] = Get-EntryName $childEntry
                }
                [Array]::Sort($keys, $refs, [System.StringComparer]::OrdinalIgnoreCase)
                $newEntry = [object[]]::new($n)
                for ($k = 0; $k -lt ($n - 1); $k++) { $newEntry[$k] = $e[$k] }
                $newEntry[$n - 1] = ($refs -join '*')
                $merged[$i] = $newEntry
            }
        }
    }

    return (, $merged)
}

function Get-V2Subtree {
    # All entry indices in the subtree of $Root (root included).
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][int]$Root
    )
    $out = @{}
    $stack = New-Object System.Collections.Generic.Stack[int]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $i = $stack.Pop()
        if ($out.ContainsKey($i)) { continue }
        $out[$i] = $true
        foreach ($c in $Entries[$i].Refs) { $stack.Push($c) }
    }
    return $out
}

function Update-V2Paths {
    # Fill in every entry's relative path, assuming the root entry's Path is
    # already set (unlike Set-V2Paths, which re-reads the meta sourceDir).
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory = $true)][string]$Path
    )
    for ($pass = 0; $pass -le $Entries.Count; $pass++) {
        $missing = 0
        foreach ($e in $Entries) {
            if ($null -ne $e.Path) { continue }
            $pp = $Entries[$e.Parent].Path
            if ($null -eq $pp) { $missing++; continue }
            if ($pp.EndsWith('\')) { $e.Path = $pp + $e.Name }
            else                   { $e.Path = $pp + '\' + $e.Name }
        }
        if ($missing -eq 0) { return }
    }
    throw ('{0}: could not re-base the merged folder paths' -f $Path)
}

function Set-V2MetaString {
    # Set one string-valued key of a root entry: the metadata object and the
    # serialized metadata text, preserving the rest of the text.
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $rx = [regex]::new(('("{0}"\s*:\s*)"(?:[^"\\]|\\.)*"' -f [regex]::Escape($Key)))
    if (($rx.Matches($Entry.MetaText)).Count -lt 1) {
        throw ('{0}: root metadata object does not contain ''{1}''' -f $Path, $Key)
    }
    # '$' is special in .NET regex replacement strings
    $safe = (Get-JsonString -Value $Value).Replace('$', '$$')
    $Entry.MetaText = $rx.Replace($Entry.MetaText, ('${1}' + $safe), 1)
    $Entry.MetaObj.$Key = $Value
    # Guard against a pathological value containing e.g. "sourceDir"."x" -
    # the patched object must still round-trip to the expected value.
    $obj = ConvertFrom-Json -InputObject $Entry.MetaText
    if ([string]$obj.$Key -ne $Value) {
        throw ('{0}: could not set ''{1}'' in the root metadata safely' -f $Path, $Key)
    }
}

function Merge-V2RootFolders {
    # Fold every root folder of every snapshot onto a single root named
    # $Label, returning new snapshots ready for the normal merge.
    # Folders are re-based on their path relative to their own root, so
    # identically named folders coming from different roots merge; a single
    # root can only carry one sourceDir/linkRoot, so when the inputs disagree
    # the root is re-based on $Label and file linking is switched off.
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshots,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $rootMetas = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Snapshots) {
        foreach ($e in $s.Entries) {
            if ($e.Parent -eq -1) { $rootMetas.Add($e.MetaObj) }
        }
    }
    if ($rootMetas.Count -eq 0) {
        throw ('{0}: no root folder found to flatten' -f $Snapshots[0].Path)
    }
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    $links = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $rootMetas) {
        [void]$dirs.Add(([string]$m.sourceDir).ToLowerInvariant())
        [void]$links.Add(([string]$m.linkRoot).ToLowerInvariant())
    }
    $rebased = ($dirs.Count -ne 1 -or $links.Count -ne 1)

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Snapshots) {
        $entries = $s.Entries
        $roots = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i].Parent -eq -1) { $roots.Add($i) }
        }
        $primary = $roots[0]
        $prim = $entries[$primary]

        for ($r = 1; $r -lt $roots.Count; $r++) {
            $src = $entries[$roots[$r]]
            foreach ($c in $src.Refs) { $entries[$c].Parent = $primary }
            $have = New-Object System.Collections.Generic.HashSet[string]
            foreach ($f in $prim.Files) { [void]$have.Add(([string]$f[0]).ToLowerInvariant()) }
            foreach ($f in $src.Files) {
                if (-not $have.Contains(([string]$f[0]).ToLowerInvariant())) { $prim.Files.Add($f) }
            }
            $haveRef = New-Object System.Collections.Generic.HashSet[int]
            $union = New-Object System.Collections.Generic.List[int]
            foreach ($c in $prim.Refs) { [void]$haveRef.Add([int]$c); $union.Add([int]$c) }
            foreach ($c in $src.Refs) {
                if (-not $haveRef.Contains([int]$c)) { [void]$haveRef.Add([int]$c); $union.Add([int]$c) }
            }
            $prim.Refs = $union.ToArray()
        }

        # Drop every root but the primary one and remap all ids.
        $drop = New-Object System.Collections.Generic.HashSet[int]
        for ($r = 1; $r -lt $roots.Count; $r++) { [void]$drop.Add($roots[$r]) }
        $keep = New-Object System.Collections.Generic.List[int]
        $keep.Add($primary)
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($i -ne $primary -and -not $drop.Contains($i)) { $keep.Add($i) }
        }
        $remap = @{}
        for ($new = 0; $new -lt $keep.Count; $new++) { $remap[$keep[$new]] = $new }

        $folded = New-Object System.Collections.Generic.List[object]
        $numFiles = [long]0
        $totalBytes = [long]0
        foreach ($old in $keep) {
            $e = $entries[$old]
            $refs = [int[]]::new($e.Refs.Count)
            for ($k = 0; $k -lt $e.Refs.Count; $k++) { $refs[$k] = $remap[$e.Refs[$k]] }
            $files = New-Object System.Collections.Generic.List[object]
            $files.AddRange($e.Files)
            foreach ($f in $files) { $totalBytes += [long]$f[1] }
            $numFiles += $files.Count
            $parent = $e.Parent
            if ($parent -ne -1) { $parent = $remap[$parent] }
            $folded.Add([pscustomobject]@{
                Name     = $e.Name
                Size     = $e.Size
                Ts       = $e.Ts
                Parent   = $parent
                Refs     = $refs
                Files    = $files
                MetaObj  = $e.MetaObj
                MetaText = $e.MetaText
                Path     = $null
                Dirty    = $false
                Owner    = -1
                Deep     = [long]0
            })
        }

        $root = $folded[0]
        $root.Name = $Label
        $base = [string]$root.MetaObj.sourceDir
        if ($rebased) {
            $base = $Label
            Set-V2MetaString -Entry $root -Key 'sourceDir' -Value $Label -Path $s.Path
            Set-V2MetaString -Entry $root -Key 'linkRoot' -Value '' -Path $s.Path
        }
        $root.Path = $base
        Update-V2Paths -Entries $folded -Path $s.Path

        $out.Add([pscustomobject]@{
            Path       = $s.Path
            Text       = $s.Text
            Entries    = $folded
            Roots      = @(0)
            NumFiles   = $numFiles
            NumDirs    = $folded.Count
            TotalBytes = $totalBytes
            Header     = $s.Header
            Stats      = $s.Stats
        })
    }

    if ($rebased) {
        [Console]::Error::WriteLine((
            'NOTE: -FlattenRoot: the inputs come from different root folders; ' +
            'the merged root is named ''{0}'' and file linking is disabled ' +
            '(a single root can only carry one link root)' -f $Label))
    }
    return $out
}

function Merge-SnapshotsV2 {
    # Merge multiple V2 snapshots into one. Returns @{ Entries; Info }.
    # Works for same-root deep merges as well as multi-root combinations.
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshots,
        [switch]$KeepOrder
    )

    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Snapshots[0].Entries) {
        $files = New-Object System.Collections.Generic.List[object]
        $files.AddRange($e.Files)
        $merged.Add([pscustomobject]@{
            Name     = $e.Name
            Size     = $e.Size
            Ts       = $e.Ts
            Parent   = $e.Parent
            Refs     = [int[]]$e.Refs.Clone()
            Files    = $files
            MetaObj  = $e.MetaObj
            MetaText = $e.MetaText
            Path     = $e.Path
            Dirty    = $false
            Owner    = -1
            Deep     = $e.Deep
        })
    }
    $pathIndex = @{}     # case-insensitive (Windows paths)
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $pathIndex[$merged[$i].Path] = $i
    }

    for ($sIdx = 1; $sIdx -lt $Snapshots.Count; $sIdx++) {
        $snap = $Snapshots[$sIdx]

        # Pass 1: target index of every incoming folder (existing path ->
        # merge; new path -> append).
        $targets = [int[]]::new($snap.Entries.Count)
        for ($i = 0; $i -lt $snap.Entries.Count; $i++) {
            $key = $snap.Entries[$i].Path
            if ($pathIndex.ContainsKey($key)) {
                $targets[$i] = $pathIndex[$key]
            }
            else {
                $t = $merged.Count
                $merged.Add($null)
                $pathIndex[$key] = $t
                $targets[$i] = $t
            }
        }

        # Pass 2: fill the new entries (with remapped ids) and merge the
        # folders that already exist.
        for ($i = 0; $i -lt $snap.Entries.Count; $i++) {
            $e = $snap.Entries[$i]
            $t = $targets[$i]
            $refs = [int[]]::new($e.Refs.Count)
            for ($k = 0; $k -lt $e.Refs.Count; $k++) { $refs[$k] = $targets[$e.Refs[$k]] }

            if ($null -eq $merged[$t]) {
                $files = New-Object System.Collections.Generic.List[object]
                $files.AddRange($e.Files)
                $merged[$t] = [pscustomobject]@{
                    Name     = $e.Name
                    Size     = $e.Size
                    Ts       = $e.Ts
                    Parent   = $(if ($e.Parent -eq -1) { -1 } else { $targets[$e.Parent] })
                    Refs     = $refs
                    Files    = $files
                    MetaObj  = $e.MetaObj
                    MetaText = $e.MetaText
                    Path     = $e.Path
                    Dirty    = $false
                    Owner    = -1
                    Deep     = $e.Deep
                }
            }
            else {
                $cur = $merged[$t]
                # a folder counts as unreadable only if every occurrence of
                # it was unreadable
                if ($cur.Size -eq -1 -and $e.Size -ne -1) { $cur.Size = $e.Size }
                $existing = @{}
                foreach ($f in $cur.Files) { $existing[$f[0]] = $true }
                foreach ($f in $e.Files) {
                    if (-not $existing.ContainsKey($f[0])) { $cur.Files.Add($f) }
                }
                $have = @{}
                foreach ($r in $cur.Refs) { $have[$r] = $true }
                foreach ($r in $refs) {
                    if (-not $have.ContainsKey($r)) {
                        $newRefs = [int[]]::new($cur.Refs.Count + 1)
                        for ($k = 0; $k -lt $cur.Refs.Count; $k++) { $newRefs[$k] = $cur.Refs[$k] }
                        $newRefs[$cur.Refs.Count] = $r
                        $cur.Refs = $newRefs
                        $have[$r] = $true
                    }
                }
                $cur.Dirty = $true
            }
        }
    }

    for ($i = 0; $i -lt $merged.Count; $i++) {
        if ($null -eq $merged[$i]) {
            throw ('{0}: internal error: unfilled placeholder entries after merge' -f $Snapshots[0].Path)
        }
    }

    # --- recompute root ownership (array-position based, as the template
    # runtime computes it) ---------------------------------------------------
    $ownerRoot = [int[]]::new($merged.Count)
    $cur = -1
    for ($idx = 0; $idx -lt $merged.Count; $idx++) {
        if ($merged[$idx].Parent -eq -1) { $cur = $idx }
        $ownerRoot[$idx] = $cur
    }
    for ($idx = 0; $idx -lt $merged.Count; $idx++) { $merged[$idx].Owner = $ownerRoot[$idx] }

    # --- natural sort of the listings of folders that changed -----------------
    if (-not $KeepOrder) {
        foreach ($e in $merged) {
            if (-not $e.Dirty) { continue }
            if ($e.Refs.Count -gt 1) {
                $names = [string[]]::new($e.Refs.Count)
                for ($k = 0; $k -lt $e.Refs.Count; $k++) { $names[$k] = $merged[$e.Refs[$k]].Name }
                $keys = Get-V2NaturalKeys -Names $names
                [Array]::Sort($keys, $e.Refs, [System.StringComparer]::OrdinalIgnoreCase)
            }
            if ($e.Files.Count -gt 1) {
                $farr = $e.Files.ToArray()
                $fnames = [string[]]::new($farr.Count)
                for ($k = 0; $k -lt $farr.Count; $k++) { $fnames[$k] = [string]$farr[$k][0] }
                $keys = Get-V2NaturalKeys -Names $fnames
                [Array]::Sort($keys, $farr, [System.StringComparer]::OrdinalIgnoreCase)
                $files = New-Object System.Collections.Generic.List[object]
                $files.AddRange($farr)
                $e.Files = $files
            }
        }
    }

    # --- recompute recursive sizes bottom-up ----------------------------------
    $n = $merged.Count
    $reachable = @{}
    $roots = @()
    for ($idx = 0; $idx -lt $n; $idx++) { if ($merged[$idx].Parent -eq -1) { $roots += $idx } }
    foreach ($r in $roots) {
        $stack = New-Object System.Collections.Generic.Stack[int]
        $stack.Push($r)
        while ($stack.Count -gt 0) {
            $i = $stack.Pop()
            if ($reachable.ContainsKey($i)) { continue }
            $reachable[$i] = $true
            foreach ($c in $merged[$i].Refs) { $stack.Push($c) }
        }
    }
    $deep = New-CSHashtable
    foreach ($r in $roots) {
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push(@($r, $false))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $i = [int]$item[0]
            if ($item[1]) {
                if ($merged[$i].Size -eq -1) {
                    $deep[$i] = [long]-1
                }
                else {
                    $total = [long]0
                    foreach ($f in $merged[$i].Files) { $total += [long]$f[1] }
                    foreach ($c in $merged[$i].Refs) {
                        if ($deep[$c] -ne -1) { $total += [long]$deep[$c] }
                    }
                    $deep[$i] = $total
                }
            }
            else {
                $stack.Push(@($i, $true))
                foreach ($c in $merged[$i].Refs) {
                    if (-not $deep.ContainsKey($c)) { $stack.Push(@($c, $false)) }
                }
            }
        }
    }
    for ($i = 0; $i -lt $n; $i++) {
        if (-not $deep.ContainsKey($i)) { $deep[$i] = $merged[$i].Size }   # unreachable: keep stored size
        $merged[$i].Deep = [long]$deep[$i]
    }

    # --- per-root metadata counters --------------------------------------------
    $rootStats = @{}
    $rootPaths = @()
    foreach ($r in $roots) {
        $sub = Get-V2Subtree -Entries $merged -Root $r
        $subFiles = [long]0
        $subBytes = [long]0
        foreach ($i in $sub.Keys) {
            $subFiles += $merged[$i].Files.Count
            foreach ($f in $merged[$i].Files) { $subBytes += [long]$f[1] }
        }
        $rootStats[$r] = @{ NumDirs = $sub.Count; NumFiles = $subFiles; TotBytes = $subBytes }
        $rootPaths += $merged[$r].Path
        $merged[$r].MetaText = Update-V2MetaText -MetaText $merged[$r].MetaText -Numbers $rootStats[$r] -Path $Snapshots[0].Path
    }

    $numFiles = [long]0
    $totalBytes = [long]0
    foreach ($e in $merged) {
        $numFiles += $e.Files.Count
        foreach ($f in $e.Files) { $totalBytes += [long]$f[1] }
    }
    $info = @{
        NumRoots   = $roots.Count
        RootPaths  = $rootPaths
        NumDirs    = $merged.Count
        NumFiles   = $numFiles
        TotalBytes = $totalBytes
    }
    return @{ Entries = $merged; Info = $info }
}

function Update-V2MetaText {
    # Patch numDirs/numFiles/totBytes inside a root metadata object,
    # preserving everything else (key order, escaping) byte-for-byte.
    param(
        [Parameter(Mandatory = $true)][string]$MetaText,
        [Parameter(Mandatory = $true)][hashtable]$Numbers,
        [Parameter(Mandatory = $true)][string]$Path
    )
    foreach ($key in @('numDirs', 'numFiles', 'totBytes')) {
        $rx = [regex]::new(('("{0}"\s*:\s*)-?\d+' -f $key))
        if (($rx.Matches($MetaText)).Count -lt 1) {
            throw ('{0}: root metadata object does not contain ''{1}''' -f $Path, $key)
        }
        $MetaText = $rx.Replace($MetaText, ('${1}' + $Numbers[$key]), 1)
    }
    # Guard against a pathological title containing e.g. "numDirs":42 - the
    # patched object must still round-trip to the expected values.
    $obj = ConvertFrom-Json -InputObject $MetaText
    if ([long]$obj.numDirs -ne [long]$Numbers.numDirs -or
        [long]$obj.numFiles -ne [long]$Numbers.numFiles -or
        [long]$obj.totBytes -ne [long]$Numbers.totBytes) {
        throw ('{0}: could not update the root metadata counters safely' -f $Path)
    }
    return $MetaText
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Get-TitleHtml {
    # HTML-escape a title for <title>/<h1>, inserting a <wbr> break after path
    # separators the way the Snap2HTML generator does.
    param([Parameter(Mandatory = $true)][string]$Title)
    $esc = $Title.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    return [regex]::Replace($esc, '([\\/])', '$1<wbr>')
}

function Update-PageTitle {
    # Replace the page title everywhere it is shown (V1 and V2).
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $html = Get-TitleHtml -Title $Title

    $rxTitle = [regex]'<title>.*?</title>'
    if (($rxTitle.Matches($Text)).Count -ne 1) {
        throw ('{0}: could not find the <title> tag to replace' -f $Path)
    }
    $Text = $rxTitle.Replace($Text, ('<title>' + $html + '</title>'), 1)

    $rxH1 = [regex]'<h1>.*?</h1>'
    if (($rxH1.Matches($Text)).Count -ne 1) {
        throw ('{0}: could not find the <h1> heading to replace' -f $Path)
    }
    $Text = $rxH1.Replace($Text, ('<h1>' + $html + '</h1>'), 1)

    if ($Text.Contains($script:V2SnapMetaStart) -and $Text.Contains($script:V2SnapMetaEnd)) {
        $m0 = $Text.IndexOf($script:V2SnapMetaStart, [System.StringComparison]::Ordinal)
        $m1 = $Text.IndexOf($script:V2SnapMetaEnd, [System.StringComparison]::Ordinal)
        $block = $Text.Substring($m0, ($m1 - $m0))
        $rxT = [regex]'(?m)^(\s*title\s*:\s*)"(?:[^"\\]|\\.)*"'
        if (($rxT.Matches($block)).Count -ne 1) {
            throw ('{0}: could not find the title in the [SNAPMETA] block' -f $Path)
        }
        # '$' is special in .NET regex replacement strings
        $safe = (Get-JsonString -Value $Title).Replace('$', '$$')
        $block = $rxT.Replace($block, ('${1}' + $safe), 1)
        $Text = $Text.Substring(0, $m0) + $block + $Text.Substring($m1)
    }
    return $Text
}

function New-MergedHtml {
    # Produce the output HTML from the base file's text and the merged data.
    param(
        [Parameter(Mandatory = $true)]$BaseSnapshot,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$MergedDirs,
        [Parameter(Mandatory = $true)][string[]]$InputNames,
        [Parameter()][string]$Title
    )

    $text = $BaseSnapshot.Text

    # --- 1. replace the data block (only the D.p(...) lines) ---------------
    $ds = $text.IndexOf('D.p([', [System.StringComparison]::Ordinal)
    $de = $text.IndexOf($script:MarkerEnd, [System.StringComparison]::Ordinal)
    if ($ds -lt 0 -or $de -lt 0 -or $de -le $ds) {
        throw ('{0}: could not locate the data block' -f $BaseSnapshot.Path)
    }
    $region = $text.Substring($ds, ($de - $ds))
    $dataMatches = [regex]::Matches($region, '(?m)^D\.p\(.*$')
    if ($dataMatches.Count -eq 0) {
        throw ('{0}: could not locate data lines to replace' -f $BaseSnapshot.Path)
    }
    $last = $dataMatches[$dataMatches.Count - 1]
    # Detect the line terminator used by the data lines ('\n' or '\r\n').
    if ($last.Value.EndsWith("`r")) { $lineTerm = "`r`n" } else { $lineTerm = "`n" }
    # Cut just past the last data line's terminator (the char after its '\n').
    $cut = $ds + $last.Index + $last.Length + 1

    $nFiles = 0
    $nDirs = $MergedDirs.Count
    $nBytes = [long]0
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $nDirs; $i++) {
        $e = @($MergedDirs[$i])
        $n = $e.Count
        $nFiles += ($n - 3)
        $sizeItem = $e[$n - 2]
        $nBytes += [long]$sizeItem
        [void]$sb.Append('D.p([')
        for ($k = 0; $k -lt $n; $k++) {
            if ($k -gt 0) { [void]$sb.Append(',') }
            if ($k -eq ($n - 2)) {
                [void]$sb.Append([string]$sizeItem)      # folder size: plain number
            }
            else {
                $item = $e[$k]
                [void]$sb.Append((Get-JsonString ([string]$item)))
            }
        }
        [void]$sb.Append('])')
        [void]$sb.Append($lineTerm)
    }
    $text = $text.Substring(0, $ds) + $sb.ToString() + $text.Substring($cut)

    # --- 2. update the counters --------------------------------------------
    $rx = [regex]'var numberOfFiles\s*=\s*\d+;'
    if (($rx.Matches($text)).Count -ne 1) {
        throw ('{0}: numberOfFiles variable not found' -f $BaseSnapshot.Path)
    }
    $text = $rx.Replace($text, ('var numberOfFiles = {0};' -f $nFiles), 1)

    $rx2 = [regex]'>\d+ files in \d+ folders\s*\(<span id="tot_size">\d+</span>\)'
    if (($rx2.Matches($text)).Count -ne 1) {
        throw ('{0}: header stats line not found' -f $BaseSnapshot.Path)
    }
    $statsRepl = '>{0} files in {1} folders (<span id="tot_size">{2}</span>)' -f $nFiles, $nDirs, $nBytes
    $text = $rx2.Replace($text, $statsRepl, 1)

    # --- 3. replace the page title when one was requested ------------------
    if ($PSBoundParameters.ContainsKey('Title')) {
        $text = Update-PageTitle -Text $text -Title $Title -Path $BaseSnapshot.Path
    }

    # --- 4. add a provenance comment next to the original one --------------
    $today = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $note = '<!-- Merged from {0} snapshots ({1}) using merge_snap2html.ps1 on {2} -->' -f `
        $InputNames.Count, ($InputNames -join ', '), $today
    $rx3 = [regex]'(?m)^(<!-- This file was generated by .*?-->\r?)$'
    if (($rx3.Matches($text)).Count -eq 1) {
        # '$' is special in .NET regex replacement strings
        $safeNote = $note.Replace('$', '$$')
        $text = $rx3.Replace($text, ('${1}' + $lineTerm + $safeNote), 1)
    }

    return $text
}

function Test-V2StoredIds {
    # Verify that every stored (root-relative) id is non-negative. Ids are
    # relative to the most recent root at a smaller index; a negative value
    # means a folder would have to point at an earlier root.
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][string]$Path
    )
    for ($idx = 0; $idx -lt $Entries.Count; $idx++) {
        $e = $Entries[$idx]
        $owner = $e.Owner
        if ($e.Parent -ne -1 -and ($e.Parent - $owner) -lt 0) { return $false }
        foreach ($r in $e.Refs) {
            if (($r - $owner) -lt 0) { return $false }
        }
    }
    return $true
}

function Get-V2GroupedOrder {
    # Re-order entries depth-first per root so that every subtree is
    # contiguous; this makes all root-relative ids non-negative.
    param([Parameter(Mandatory = $true)]$Entries)
    $order = New-Object System.Collections.Generic.List[int]
    $seen = @{}
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if ($Entries[$i].Parent -ne -1) { continue }
        $stack = New-Object System.Collections.Generic.Stack[int]
        $stack.Push($i)
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            if ($seen.ContainsKey($cur)) { continue }
            $seen[$cur] = $true
            $order.Add($cur)
            for ($k = $Entries[$cur].Refs.Count - 1; $k -ge 0; $k--) {
                $c = $Entries[$cur].Refs[$k]
                if (-not $seen.ContainsKey($c)) { $stack.Push($c) }
            }
        }
    }
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if (-not $seen.ContainsKey($i)) { $order.Add($i) }
    }
    return $order
}

function New-V2EntryLine {
    # Serialize one merged V2 entry into its p([...]) data line:
    #   p(["name*size*ts",parent,"ref1*ref2",...,"file*size*ts",...,{metadata}])
    param([Parameter(Mandatory = $true)][object]$Entry)
    $e = $Entry
    $owner = $e.Owner
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('p(["')
    $q = Get-JavaScriptString ([string]$e.Name)
    [void]$sb.Append($q.Substring(1, $q.Length - 2))   # inner (unquoted) string
    [void]$sb.Append('*')
    [void]$sb.Append((ConvertTo-Base36 ([long]$e.Deep)))
    [void]$sb.Append('*')
    [void]$sb.Append((ConvertTo-Base36 ([long]$e.Ts)))
    [void]$sb.Append('",')
    if ($e.Parent -eq -1) { [void]$sb.Append('-1') }
    else                  { [void]$sb.Append([string]($e.Parent - $owner)) }
    [void]$sb.Append(',"')
    for ($k = 0; $k -lt $e.Refs.Count; $k++) {
        if ($k -gt 0) { [void]$sb.Append('*') }
        [void]$sb.Append([string]($e.Refs[$k] - $owner))
    }
    [void]$sb.Append('"')
    foreach ($f in $e.Files) {
        [void]$sb.Append(',"')
        $q = Get-JavaScriptString ([string]$f[0])
        [void]$sb.Append($q.Substring(1, $q.Length - 2))
        [void]$sb.Append('*')
        [void]$sb.Append((ConvertTo-Base36 ([long]$f[1])))
        [void]$sb.Append('*')
        [void]$sb.Append((ConvertTo-Base36 ([long]$f[2])))
        [void]$sb.Append('"')
    }
    if ($e.Parent -eq -1) {
        [void]$sb.Append(',')
        [void]$sb.Append($e.MetaText)
    }
    [void]$sb.Append('])')
    return $sb.ToString()
}

function New-MergedHtmlV2 {
    # Produce the output HTML from the base file's text and the merged data.
    param(
        [Parameter(Mandatory = $true)]$BaseSnapshot,
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][hashtable]$Info,
        [Parameter(Mandatory = $true)][string[]]$InputNames,
        [Parameter()][string]$Title
    )

    $text = $BaseSnapshot.Text

    # --- 1. replace the data block between the [SNAPDATA] markers -----------
    $i0 = $text.IndexOf($script:V2SnapDataStart, [System.StringComparison]::Ordinal)
    $i0e = $text.IndexOf("`n", $i0)
    if ($i0e -lt 0) { throw ('{0}: malformed [SNAPDATA] marker' -f $BaseSnapshot.Path) }
    $i0e++
    $i1 = $text.IndexOf($script:V2SnapDataEnd, [System.StringComparison]::Ordinal)
    if ($i0 -lt 0 -or $i1 -lt 0 -or $i1 -lt $i0e) {
        throw ('{0}: could not locate the data block' -f $BaseSnapshot.Path)
    }
    $oldRegion = $text.Substring($i0e, ($i1 - $i0e))
    if ($oldRegion.TrimEnd("`n").EndsWith("`r")) { $lineTerm = "`r`n" } else { $lineTerm = "`n" }

    if (-not (Test-V2StoredIds -Entries $Entries -Path $BaseSnapshot.Path)) {
        # A multi-root merge would need negative ids in the natural output
        # order (base entries, then appended ones); emit the entries grouped
        # per root subtree instead, remapping all ids to the new positions.
        $order = Get-V2GroupedOrder -Entries $Entries
        $newIndex = @{}
        for ($new = 0; $new -lt $order.Count; $new++) { $newIndex[$order[$new]] = $new }
        $reordered = New-Object System.Collections.Generic.List[object]
        foreach ($old in $order) {
            $e = $Entries[$old]
            if ($e.Parent -eq -1) { $e.Parent = -1 }
            else                  { $e.Parent = $newIndex[$e.Parent] }
            $newRefs = [int[]]::new($e.Refs.Count)
            for ($k = 0; $k -lt $e.Refs.Count; $k++) { $newRefs[$k] = $newIndex[$e.Refs[$k]] }
            $e.Refs = $newRefs
            $reordered.Add($e)
        }
        $Entries = $reordered
        # recompute root ownership for the new order
        $ownerRoot = [int[]]::new($Entries.Count)
        $cur = -1
        for ($idx = 0; $idx -lt $Entries.Count; $idx++) {
            if ($Entries[$idx].Parent -eq -1) { $cur = $idx }
            $ownerRoot[$idx] = $cur
        }
        for ($idx = 0; $idx -lt $Entries.Count; $idx++) { $Entries[$idx].Owner = $ownerRoot[$idx] }
        if (-not (Test-V2StoredIds -Entries $Entries -Path $BaseSnapshot.Path)) {
            throw ('{0}: cannot merge: the folder tree cannot be serialized with non-negative root-relative ids (orphans across roots?)' -f $BaseSnapshot.Path)
        }
        [Console]::Error::WriteLine('NOTE: entries re-ordered per root to keep folder ids valid')
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $Entries) {
        [void]$sb.Append((New-V2EntryLine -Entry $e))
        [void]$sb.Append($lineTerm)
    }
    $text = $text.Substring(0, $i0e) + $sb.ToString() + $text.Substring($i1)

    # --- 2. update the counters in the [SNAPMETA] block ---------------------
    $m0 = $text.IndexOf($script:V2SnapMetaStart, [System.StringComparison]::Ordinal)
    $m1 = $text.IndexOf($script:V2SnapMetaEnd, [System.StringComparison]::Ordinal)
    if ($m0 -lt 0 -or $m1 -lt 0 -or $m1 -lt $m0) {
        throw ('{0}: could not locate the [SNAPMETA] block' -f $BaseSnapshot.Path)
    }
    $snapmeta = $text.Substring($m0, ($m1 + $script:V2SnapMetaEnd.Length - $m0))
    foreach ($pair in @(@('numFiles', $Info.NumFiles), @('numDirs', $Info.NumDirs), @('bytes', $Info.TotalBytes))) {
        $key = $pair[0]; $val = $pair[1]
        $rx = [regex]::new(('(?m)^(\s*{0}:\s*)\d+(\s*,)' -f $key))
        if (($rx.Matches($snapmeta)).Count -ne 1) {
            throw ('{0}: {1} not found in the [SNAPMETA] block' -f $BaseSnapshot.Path, $key)
        }
        $snapmeta = $rx.Replace($snapmeta, ('${1}' + $val + '${2}'), 1)
    }
    $text = $text.Substring(0, $m0) + $snapmeta + $text.Substring($m1 + $script:V2SnapMetaEnd.Length)

    # --- 3. update the stats line under the page title ----------------------
    $tot = Get-CSharpFileSize -Bytes $Info.TotalBytes -DecimalSeparator $BaseSnapshot.Stats.DecSep
    $rx2 = [regex]'>\d+ files in \d+ folders\s*\(\<span id="tot_size"\>[^<]+\</span>\)'
    if (($rx2.Matches($text)).Count -ne 1) {
        throw ('{0}: header stats line not found' -f $BaseSnapshot.Path)
    }
    $statsRepl = '>{0} files in {1} folders (<span id="tot_size">{2}</span>)' -f `
        $Info.NumFiles, $Info.NumDirs, $tot
    $text = $rx2.Replace($text, $statsRepl, 1)

    # --- 4. replace the page title when one was requested ------------------
    if ($PSBoundParameters.ContainsKey('Title')) {
        $text = Update-PageTitle -Text $text -Title $Title -Path $BaseSnapshot.Path
    }

    # --- 5. add a provenance comment next to the original one ---------------
    $today = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $note = '<!-- Merged from {0} snapshots ({1}) using merge_snap2html.ps1 on {2} -->' -f `
        $InputNames.Count, ($InputNames -join ', '), $today
    $rx3 = [regex]'(?m)^(<!-- This file was generated by .*?-->\r?)$'
    if (($rx3.Matches($text)).Count -eq 1) {
        # '$' is special in .NET regex replacement strings
        $safeNote = $note.Replace('$', '$$')
        $text = $rx3.Replace($text, ('${1}' + $lineTerm + $safeNote), 1)
    }

    return $text
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

function Test-V2Output {
    # Compare the re-parsed output against the inputs: folder set, file set
    # (both case-insensitive) and root set must match.
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][object[]]$Snapshots
    )

    $expectedPaths = @{}
    foreach ($s in $Snapshots) {
        foreach ($e in $s.Entries) { $expectedPaths[$e.Path] = $true }
    }
    $actualPaths = @{}
    foreach ($e in $Result.Entries) { $actualPaths[$e.Path] = $true }
    $missing = @(); $extra = @()
    foreach ($k in @($expectedPaths.Keys)) { if (-not $actualPaths.ContainsKey($k)) { $missing += $k } }
    foreach ($k in @($actualPaths.Keys)) { if (-not $expectedPaths.ContainsKey($k)) { $extra += $k } }
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw ('verification failed: folder set mismatch (missing: {0}, unexpected: {1})' -f `
            (($missing | Select-Object -First 3) -join ', '), (($extra | Select-Object -First 3) -join ', '))
    }

    $expFiles = @{}
    foreach ($s in $Snapshots) {
        foreach ($e in $s.Entries) {
            foreach ($f in $e.Files) {
                $key = $e.Path + '\' + $f[0]
                if (-not $expFiles.ContainsKey($key)) { $expFiles[$key] = $f }
            }
        }
    }
    $actFiles = @{}
    foreach ($e in $Result.Entries) {
        foreach ($f in $e.Files) { $actFiles[$e.Path + '\' + $f[0]] = $f }
    }
    $missing = @(); $extra = @()
    foreach ($k in @($expFiles.Keys)) { if (-not $actFiles.ContainsKey($k)) { $missing += $k } }
    foreach ($k in @($actFiles.Keys)) { if (-not $expFiles.ContainsKey($k)) { $extra += $k } }
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw ('verification failed: file set mismatch (missing: {0}, unexpected: {1})' -f `
            (($missing | Select-Object -First 3) -join ', '), (($extra | Select-Object -First 3) -join ', '))
    }

    $expRoots = @{}
    foreach ($s in $Snapshots) {
        foreach ($e in $s.Entries) { if ($e.Parent -eq -1) { $expRoots[[string]$e.MetaObj.sourceDir] = $true } }
    }
    $actRoots = @{}
    foreach ($e in $Result.Entries) { if ($e.Parent -eq -1) { $actRoots[[string]$e.MetaObj.sourceDir] = $true } }
    $missing = @(); $extra = @()
    foreach ($k in @($expRoots.Keys)) { if (-not $actRoots.ContainsKey($k)) { $missing += $k } }
    foreach ($k in @($actRoots.Keys)) { if (-not $expRoots.ContainsKey($k)) { $extra += $k } }
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw ('verification failed: root folder set mismatch ({0} != {1})' -f `
            ($missing -join ', '), ($extra -join ', '))
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    if ($null -eq $InputFiles -or $InputFiles.Count -lt 2) {
        throw 'at least two input files are required'
    }

    # Read every input once; detect the data format of each.
    $read = @()
    foreach ($p in $InputFiles) {
        $r = Read-SnapshotFile -Path $p
        $r.Format = Get-SnapshotFormat -Text $r.Text -Path $p
        $r.Path = $p
        $read += $r
    }
    $formats = @($read | ForEach-Object { $_.Format } | Select-Object -Unique)
    if ($formats.Count -ne 1) {
        $detail = ($read | ForEach-Object { '{0} is {1}' -f $_.Path, $_.Format }) -join ', '
        throw ('cannot mix data formats in one merge: {0}' -f $detail)
    }

    if ($formats[0] -eq 'V1') {
        # ---------------- V1 (Snap2HTML 2.0-2.14) ----------------
        if ($FlattenRoot) {
            throw ('-FlattenRoot is only supported for the Snap2HTML 2.5+ (V2) data format; V1 snapshots always describe a single root folder')
        }

        $snapshots = @()
        foreach ($p in $InputFiles) {
            $snapshots += @(ConvertFrom-Snapshot -Path $p)
        }

        # All snapshots must link to files the same way.
        for ($i = 1; $i -lt $snapshots.Count; $i++) {
            foreach ($key in @('linkFiles', 'linkProtocol', 'linkRoot', 'sourceRoot')) {
                if ($snapshots[$i].Meta[$key] -cne $snapshots[0].Meta[$key]) {
                    throw ('{0}: {1} is ''{2}'' but the first snapshot uses ''{3}''' -f `
                        $snapshots[$i].Path, $key, $snapshots[$i].Meta[$key], $snapshots[0].Meta[$key])
                }
            }
            if ($snapshots[$i].Meta['title'] -ne $snapshots[0].Meta['title']) {
                [Console]::Error::WriteLine(
                    ('NOTE: {0}: title differs from the first snapshot; keeping ''{1}''' -f `
                        $snapshots[$i].Path, $snapshots[0].Meta['title']))
            }
        }

        $merged = Merge-Snapshots -Snapshots $snapshots -KeepOrder:$KeepOrder

        $inputNames = @($InputFiles | ForEach-Object { Split-Path -Leaf $_ })
        $renderArgs = @{
            BaseSnapshot = $snapshots[0]
            MergedDirs   = $merged
            InputNames   = $inputNames
        }
        if ($script:HasTitle) { $renderArgs['Title'] = $Title }
        $outputText = New-MergedHtml @renderArgs

        $fullOut = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
        $outDir = Split-Path -Parent $fullOut
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($fullOut, $outputText, $utf8NoBom)

        # --- verify the result by re-parsing it --------------------------------
        $result = ConvertFrom-Snapshot -Path $fullOut

        $expectedPaths = New-CSHashtable
        foreach ($s in $snapshots) {
            foreach ($e in $s.Dirs) { $expectedPaths[(Get-EntryPath $e)] = $true }
        }
        $actualPaths = New-CSHashtable
        foreach ($e in $result.Dirs) { $actualPaths[(Get-EntryPath $e)] = $true }

        $missing = @()
        foreach ($k in @($expectedPaths.Keys)) { if (-not $actualPaths.ContainsKey($k)) { $missing += $k } }
        $extra = @()
        foreach ($k in @($actualPaths.Keys)) { if (-not $expectedPaths.ContainsKey($k)) { $extra += $k } }
        if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
            throw ('verification failed: folder set mismatch (missing: {0}, unexpected: {1})' -f `
                (($missing | Select-Object -First 3) -join ', '), (($extra | Select-Object -First 3) -join ', '))
        }

        $sumDirs = 0
        $sumFiles = 0
        foreach ($s in $snapshots) { $sumDirs += $s.NumDirs; $sumFiles += $s.NumFiles }
        $dupMerged = $sumDirs - $result.NumDirs

        Write-Output ('Merged {0} snapshots (Snap2HTML 2.0-2.14 data format) into {1}' -f $snapshots.Count, $OutputFile)
        Write-Output ('  Folders: {0} -> {1} ({2} root/duplicate merged)' -f `
            (($snapshots | ForEach-Object { $_.NumDirs }) -join ' + '), $result.NumDirs, $dupMerged)
        Write-Output ('  Files:   {0} -> {1}' -f `
            (($snapshots | ForEach-Object { $_.NumFiles }) -join ' + '), $result.NumFiles)
        Write-Output ('  Total:   {0}' -f (Get-HumanSize $result.TotalBytes))
        Write-Output ('  Output verified OK (all {0} folders reachable, references and counters consistent).' -f $result.NumDirs)
    }
    else {
        # ---------------- V2 (Snap2HTML 2.5+) ----------------
        $snapshots = @()
        foreach ($r in $read) {
            $snapshots += @(ConvertFrom-SnapshotV2 -Path $r.Path -Text $r.Text)
        }

        # Apply the requested title to every root before merging, so the root
        # metadata and the folded root already agree on it.
        if ($script:HasTitle) {
            foreach ($s in $snapshots) {
                foreach ($e in $s.Entries) {
                    if ($e.Parent -eq -1) {
                        Set-V2MetaString -Entry $e -Key 'title' -Value $Title -Path $s.Path
                    }
                }
            }
        }

        if ($FlattenRoot) {
            $firstRoot = $null
            foreach ($e in $snapshots[0].Entries) {
                if ($e.Parent -eq -1) { $firstRoot = $e; break }
            }
            if ($script:HasTitle) { $label = $Title } else { $label = [string]$firstRoot.Name }
            $snapshots = @(Merge-V2RootFolders -Snapshots $snapshots -Label $label)
        }

        # For roots that also exist in the first snapshot, the link setup
        # and title should agree; otherwise keep the first snapshot's.
        $baseRootMeta = @{}
        foreach ($e in $snapshots[0].Entries) {
            if ($e.Parent -eq -1) { $baseRootMeta[[string]$e.MetaObj.sourceDir] = $e.MetaObj }
        }
        for ($i = 1; $i -lt $snapshots.Count; $i++) {
            foreach ($e in $snapshots[$i].Entries) {
                if ($e.Parent -ne -1) { continue }
                $m0 = $baseRootMeta[[string]$e.MetaObj.sourceDir]
                if ($null -eq $m0) { continue }
                if ([string]$e.MetaObj.linkRoot -ne [string]$m0.linkRoot) {
                    [Console]::Error::WriteLine(
                        ('NOTE: {0}: link root ''{1}'' differs from the first snapshot''s ''{2}''; keeping the first' -f `
                            $snapshots[$i].Path, $e.MetaObj.linkRoot, $m0.linkRoot))
                }
                if ([string]$e.MetaObj.title -ne [string]$m0.title) {
                    [Console]::Error::WriteLine(
                        ('NOTE: {0}: title differs from the first snapshot; keeping ''{1}''' -f `
                            $snapshots[$i].Path, $m0.title))
                }
            }
        }

        $mergedResult = Merge-SnapshotsV2 -Snapshots $snapshots -KeepOrder:$KeepOrder

        $inputNames = @($InputFiles | ForEach-Object { Split-Path -Leaf $_ })
        $renderArgs = @{
            BaseSnapshot = $snapshots[0]
            Entries      = $mergedResult.Entries
            Info         = $mergedResult.Info
            InputNames   = $inputNames
        }
        if ($script:HasTitle) { $renderArgs['Title'] = $Title }
        $outputText = New-MergedHtmlV2 @renderArgs

        $fullOut = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
        $outDir = Split-Path -Parent $fullOut
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $utf8 = [System.Text.UTF8Encoding]::new($read[0].HasBom)   # preserve a BOM if the base had one
        [System.IO.File]::WriteAllText($fullOut, $outputText, $utf8)

        # --- verify the result by re-parsing it --------------------------------
        $readBack = Read-SnapshotFile -Path $fullOut
        $result = ConvertFrom-SnapshotV2 -Path $fullOut -Text $readBack.Text
        Test-V2Output -Result $result -Snapshots $snapshots

        Write-Output ('Merged {0} snapshots (Snap2HTML 2.5+ data format) into {1}' -f $snapshots.Count, $OutputFile)
        if ($mergedResult.Info.NumRoots -eq 1) {
            Write-Output ('  Root:    {0}' -f $mergedResult.Info.RootPaths[0])
        }
        else {
            Write-Output ('  Roots:   {0} (multi-root snapshot)' -f ($mergedResult.Info.RootPaths -join ', '))
        }
        Write-Output ('  Folders: {0} -> {1}' -f `
            (($snapshots | ForEach-Object { $_.NumDirs }) -join ' + '), $result.NumDirs)
        Write-Output ('  Files:   {0} -> {1}' -f `
            (($snapshots | ForEach-Object { $_.NumFiles }) -join ' + '), $result.NumFiles)
        Write-Output ('  Total:   {0}' -f (Get-CSharpFileSize -Bytes $result.TotalBytes))
        Write-Output ('  Output verified OK (all {0} folders reachable, references and counters consistent).' -f $result.NumDirs)
    }
}
catch {
    [Console]::Error::WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
