<#
.SYNOPSIS
    Consolidates two or more Snap2HTML snapshot files (of the same root folder)
    into a single snapshot.

.DESCRIPTION
    Snap2HTML (http://www.rlvision.com) generates self-contained HTML snapshots
    of a folder tree. The snapshot data lives in a JavaScript array `dirs`
    where every element is itself an array:

        [ "dirpath*0*modified date",          # item 0 (forward slashes)
          "filename*size*modified date",      # one item per file directly inside
          ...
          <int: total size of the files above>,
          "id1*id2*..."                       # indices (into dirs) of subfolders,
        ]                                    # "" when there are none

    Index 0 is always the snapshot's root folder; every other folder is
    referenced exactly once by its parent. Header stats are derived from the
    data: folder count == dirs.length, file count == sum(len-3), total size ==
    sum of the size fields.

    This script merges snapshots of the SAME root folder:

      * folders of subsequent snapshots are appended, with every subfolder
        reference id remapped to the new indices
      * the root entry (and any folder that exists in more than one snapshot)
        is merged: file lists are unioned (by name), sizes summed, subfolder
        references unioned
      * header stats (N files in M folders, total size) are recomputed
      * subfolder reference lists are sorted by folder name (case-insensitive)
        so the tree view shows a natural A-Z listing, matching Snap2HTML's own
        output order (disable with -KeepOrder)
      * the first input file is used as the template: everything outside the
        data block and the counters is preserved byte-for-byte (plus a
        "<!-- Merged from ... -->" provenance comment)
      * every input is validated and the output is re-parsed and verified
        before the script reports success

    This is a port of merge_snap2html.py and produces byte-identical output.

    Works with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    PS> .\merge_snap2html.ps1 shows\shows-A_R.html shows\shows-S_Z.html -OutputFile shows\shows-A_Z.html

    Merges the two snapshots into shows\shows-A_Z.html.

.EXAMPLE
    PS> .\merge_snap2html.ps1 a.html b.html c.html -KeepOrder -o all.html

    Merges three snapshots, keeping raw snapshot order in folder listings.

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
    [switch]$KeepOrder
)

$ErrorActionPreference = 'Stop'

$script:MarkerStart = 'Array.prototype.p = Array.prototype.push;'
$script:MarkerEnd   = 'delete(Array.prototype.p)'

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

# ---------------------------------------------------------------------------
# Parsing
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
    # Parse one Snap2HTML file, validating its data structure and header stats.
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

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function New-MergedHtml {
    # Produce the output HTML from the base file's text and the merged data.
    param(
        [Parameter(Mandatory = $true)]$BaseSnapshot,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$MergedDirs,
        [Parameter(Mandatory = $true)][string[]]$InputNames
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

    # --- 3. add a provenance comment next to the original one --------------
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
# Main
# ---------------------------------------------------------------------------

try {
    if ($null -eq $InputFiles -or $InputFiles.Count -lt 2) {
        throw 'at least two input files are required'
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
    $outputText = New-MergedHtml -BaseSnapshot $snapshots[0] -MergedDirs $merged -InputNames $inputNames

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

    Write-Output ('Merged {0} snapshots into {1}' -f $snapshots.Count, $OutputFile)
    Write-Output ('  Folders: {0} -> {1} ({2} root/duplicate merged)' -f `
        (($snapshots | ForEach-Object { $_.NumDirs }) -join ' + '), $result.NumDirs, $dupMerged)
    Write-Output ('  Files:   {0} -> {1}' -f `
        (($snapshots | ForEach-Object { $_.NumFiles }) -join ' + '), $result.NumFiles)
    Write-Output ('  Total:   {0}' -f (Get-HumanSize $result.TotalBytes))
    Write-Output ('  Output verified OK (all {0} folders reachable, references and counters consistent).' -f $result.NumDirs)
}
catch {
    [Console]::Error::WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
