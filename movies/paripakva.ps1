# =====================================================
# ================= Configuration ====================
# =====================================================

param(
    [string]$SourceFolder			= "C:\wamp64-3.3.7\www\movies_template\paripakva",
    [string]$MySqlExe				= "C:\wamp64-3.3.7\bin\mysql\mysql9.1.0\bin\mysql.exe",
    [string]$MySqlHost				= "localhost",
    [string]$MySqlUser				= "root",
    [string]$MySqlPass				= "",
    [string]$MySqlDB				= "movies",
    [string]$TableName				= "paripakva",
    [bool]$DryRun					= $false,
    [bool]$DropTable				= $true,
	[bool]$AllowDuplicateHash_Num	= $true,
    [string]$SqlFileFilter			= "paripakva.sql",
    [string[]]$ExcludeFiles			= @('movies_00_0000.sql'),
    [int]$BatchSize					= 500,
    [string[]]$HashFields			= @("FORMATTEDTITLE","YEAR","DIRECTOR","URL")  # fields used for duplicate hash
)

# =====================================================
# =============== Encoding Setup =====================
# =====================================================

$InputEncoding  = [Text.Encoding]::GetEncoding("ISO-8859-1")
$OutputEncoding = [Text.Encoding]::UTF8

$Config = @{
    SourceFolder			= $SourceFolder
    MySqlExe				= $MySqlExe
    MySqlHost				= $MySqlHost
    MySqlUser				= $MySqlUser
    MySqlPass				= $MySqlPass
    MySqlDB					= $MySqlDB
    TableName				= $TableName
    DryRun					= $DryRun
    DropTable				= $DropTable
	AllowDuplicateHash_Num	= $AllowDuplicateHash_Num
    InputEncoding			= $InputEncoding
    OutputEncoding			= $OutputEncoding
    SqlFileFilter			= $SqlFileFilter
    ExcludeFiles			= $ExcludeFiles
    BatchSize				= $BatchSize
    HashFields				= $HashFields
}

# =====================================================
# ================= PowerShell Check =================
# =====================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "PowerShell 7+ required." -ForegroundColor Red
    exit
}

chcp 65001 | Out-Null
$OutputEncoding = $Config.OutputEncoding

# =====================================================
# =============== Log File Setup =====================
# =====================================================
function Get-TimestampedFile($baseName, $folder, $ext) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $counter = 0
    do {
        $fileName = "$baseName`_$timestamp"
        if ($counter -gt 0) { $fileName += "_$counter" }
        $fileName += $ext
        $fullPath = Join-Path $folder $fileName
        $counter++
    } while (Test-Path $fullPath)
    return $fullPath
}

$Config.LogFile       = Get-TimestampedFile "import_log" $Config.SourceFolder ".txt"
$Config.DuplicateFile = Get-TimestampedFile "duplicates_log" $Config.SourceFolder ".txt"

# Function to keep only last N versions
function Cleanup-OldFiles($folder, $baseName, $ext, $keep = 3) {
    $files = Get-ChildItem $folder -Filter "$baseName*$ext" | Sort-Object LastWriteTime -Descending
    if ($files.Count -le $keep) { return }
    $files[$keep..($files.Count-1)] | Remove-Item -Force
}

# =====================================================
# ================= Helper Functions =================
# =====================================================
function NormalizeLine($line) {
    $line.Normalize([Text.NormalizationForm]::FormC)
}

function Get-ElapsedSeconds($start) {
    ((Get-Date) - $start).TotalSeconds
}

# =====================================================
# ================= Parse SQL Line ===================
# =====================================================
function ParseInsertLine {
    param ($line, $Columns)

    if ($line -notmatch "^INSERT INTO .*?\s*\(.+?\)\s*VALUES\s*\(.+\);$") { return $null }

    $vals = [regex]::Split(
        ($line -replace '^.+?VALUES\s*\(|\);$',''),
        ",(?=(?:[^']*'[^']*')*[^']*$)"
    )

    if ($vals.Count -ne $Columns.Count) { return $null }

    $row = @{ }
    for ($i=0; $i -lt $Columns.Count; $i++) {
        $v = $vals[$i].Trim()
        if ($v -eq "NULL") { $v = $null }
        elseif ($v.StartsWith("'")) {
			$v = $v.Substring(1,$v.Length-2)
			$v = $v.Replace("''","'")
			$v = $v.Replace("\\","\")
        }
        $row[$Columns[$i]] = $v
    }
    return $row
}

# =====================================================
# ================= MySQL Checks =====================
# =====================================================
function Test-MySqlServer {
    param($Exe, $MySqlHost, $User, $Pass)
    try {
        $cmd = "$Exe -h $MySqlHost -u $User"
        if ($Pass) { $cmd += " -p$Pass" }
        $cmd += ' -e "SELECT 1;"'
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -NoNewWindow -Wait -PassThru `
            -RedirectStandardError "$env:TEMP\mysql_test_err.txt" `
            -RedirectStandardOutput "$env:TEMP\mysql_test_out.txt"
        return ($proc.ExitCode -eq 0)
    } catch { return $false }
}

function Test-MySqlDatabase {
    param($Exe, $MySqlHost, $User, $Pass, $DB)
    try {
        $cmd = "$Exe -h $MySqlHost -u $User"
        if ($Pass) { $cmd += " -p$Pass" }
        $cmd += " -e `"USE $DB;`""
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -NoNewWindow -Wait -PassThru `
            -RedirectStandardError "$env:TEMP\mysql_db_err.txt" `
            -RedirectStandardOutput "$env:TEMP\mysql_db_out.txt"
        return ($proc.ExitCode -eq 0)
    } catch { return $false }
}

if (-not $Config.DryRun -and -not (Test-MySqlServer $Config.MySqlExe $Config.MySqlHost $Config.MySqlUser $Config.MySqlPass)) {
    Write-Host "MySQL server not reachable." -ForegroundColor Red
    exit
}

if (-not $Config.DryRun -and -not (Test-MySqlDatabase $Config.MySqlExe $Config.MySqlHost $Config.MySqlUser $Config.MySqlPass $Config.MySqlDB)) {
    Write-Host "Database '$($Config.MySqlDB)' not found. Creating..." -ForegroundColor Yellow
    $createCmd = "$($Config.MySqlExe) -h $($Config.MySqlHost) -u $($Config.MySqlUser)"
    if ($Config.MySqlPass) { $createCmd += " -p$($Config.MySqlPass)" }
    $createCmd += " -e `"CREATE DATABASE $($Config.MySqlDB) CHARACTER SET utf8mb4;`""
    cmd.exe /c $createCmd
    if ($LASTEXITCODE -ne 0) { Write-Host "Failed to create database." -ForegroundColor Red; exit }
}

# =====================================================
# ================= Locate SQL Files =================
# =====================================================
$sqlFiles = Get-ChildItem $Config.SourceFolder -Filter $Config.SqlFileFilter |
            Where-Object { $Config.ExcludeFiles -notcontains $_.Name } |
            Sort-Object Name

if (-not $sqlFiles) {
    Write-Host "No SQL files found." -ForegroundColor Yellow
    exit
}

# =====================================================
# =============== Detect Columns ====================
# =====================================================
$firstInsert = Get-Content $sqlFiles[0].FullName -Encoding $Config.InputEncoding |
               Where-Object { $_ -match "INSERT INTO" } |
               Select-Object -First 1

if (-not $firstInsert) {
    Write-Host "No valid INSERT statement found in first SQL file. Cannot detect columns." -ForegroundColor Red
    exit
}

$Columns = ($firstInsert -replace '^.+?\(|\)\s*VALUES.+$','') -split '\s*,\s*'

# =====================================================
# =============== MySQL Connection ===================
# =====================================================
Add-Type -Path "C:\Program Files (x86)\MySQL\MySQL Connector NET 9.5\MySql.Data.dll"
$conn = New-Object MySql.Data.MySqlClient.MySqlConnection(
    "server=$($Config.MySqlHost);uid=$($Config.MySqlUser);database=$($Config.MySqlDB);charset=utf8mb4;pwd=$($Config.MySqlPass)"
)
try { $conn.Open() } catch { Write-Host "MySQL connection failed: $_" -ForegroundColor Red; exit }
$tx = $conn.BeginTransaction()

# =====================================================
# ================= Database Setup ===================
# =====================================================
if ($Config.DryRun) { return }

$tableName = $Config.TableName

# Helper function to execute SQL
function Invoke-Sql {
    param($Connection, $Sql)

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.ExecuteNonQuery() | Out-Null
}

# Drop table if requested
if ($Config.DropTable) {
    Invoke-Sql $conn "DROP TABLE IF EXISTS $tableName;"
}

# Predefine type groups (faster than recreating arrays in switch)
$intColumns      = @("YEAR","LENGTH","VIDEOBITRATE","AUDIOBITRATE","DISKS","NBEXTRAS","COLORTAG")
$dateColumns     = @("DATEADDED","DATEWATCHED")
$floatColumns    = @("USERRATING","RATING")
$varcharColumns  = @("CATEGORY")

$defs = foreach ($c in $Columns) {

    switch ($c) {

        "NUM" {
            "$c INT NOT NULL PRIMARY KEY"
            continue
        }

        { $intColumns -contains $_ } {
            "$c INT"
            continue
        }

        { $dateColumns -contains $_ } {
            "$c DATE"
            continue
        }

        { $floatColumns -contains $_ } {
            "$c FLOAT"
            continue
        }

        { $varcharColumns -contains $_ } {
            "$c VARCHAR(255)"
            continue
        }

        default {
            "$c TEXT CHARACTER SET utf8mb4"
        }
    }
}

# RECORDHASH definition
$defs += if ($Config.AllowDuplicateHash_Num) {
    "RECORDHASH CHAR(64) NOT NULL"
} else {
    "RECORDHASH CHAR(64) NOT NULL UNIQUE"
}

# Create table
Invoke-Sql $conn @"
CREATE TABLE IF NOT EXISTS $tableName (
    $($defs -join ",")
) ENGINE=InnoDB;
"@

# Indexes (using table variable consistently)
Invoke-Sql $conn "CREATE INDEX idx_recordhash_num ON $tableName (RECORDHASH, NUM);"
Invoke-Sql $conn "ALTER TABLE $tableName ADD FULLTEXT INDEX ft_search (ORIGINALTITLE, FORMATTEDTITLE, DIRECTOR, ACTORS, DESCRIPTION, COUNTRY);"
Invoke-Sql $conn "CREATE INDEX idx_year ON $tableName (YEAR);"
Invoke-Sql $conn "CREATE INDEX idx_category ON $tableName (CATEGORY);"
Invoke-Sql $conn "CREATE INDEX idx_rating ON $tableName (RATING);"

# ===============================================================================
# ================= Duplicate Detection - Allow Insert and logging ==============
# ===============================================================================
# Detection and logging of duplicates
function Process-Duplicate($row, $hash, $file, $lineNo) {
    $global:duplicates++
    $existing = $existingRecords[$hash]
    $diffs = @()
    foreach ($f in $Config.HashFields) {
        if (($row[$f] -ne $null) -and ($row[$f] -ne $existing[$f])) {
            $diffs += "${f}:'$($row[$f])'->'$($existing[$f])'"
        }
    }
    $diffStr = if ($diffs.Count -gt 0) { " | Diff: " + ($diffs -join ', ') } else { "" }
    $dupLine = "DUPLICATE -> File:$($file.Name) Line:$lineNo NUM:$($row.NUM) Title:'$($row.FORMATTEDTITLE)' Year:$($row.YEAR)$diffStr Hash:$hash"
    
    # Log duplicate record details
    $dupLine | Out-File $Config.DuplicateFile -Append -Encoding $Config.OutputEncoding
    
	
	# Insert the duplicate record based on the config value: AllowDuplicateHash_Num
	if ($Config.AllowDuplicateHash_Num) {
		$row.RECORDHASH = $hash
		$existingHashes[$hash] = $true
		$existingRecords[$hash] = @{}
		foreach ($f in $Config.HashFields) { $existingRecords[$hash][$f] = $row[$f] }

		InsertBatch @($row)  # Insert duplicate record
	}
}

# ========================================================================================
# ================= Duplicate Detection - Disallow Insert but allow logging ==============
# ========================================================================================
$existingHashes = @{}
$existingRecords = @{}
$checkCmd = $conn.CreateCommand()
$checkCmd.CommandText = "SELECT * FROM $($Config.TableName);"
$reader = $checkCmd.ExecuteReader()
while ($reader.Read()) {
    $hash = $reader["RECORDHASH"].ToString().ToLower()
    $existingHashes[$hash] = $true
    $existingRecords[$hash] = @{ }
    foreach ($f in $Config.HashFields) { $existingRecords[$hash][$f] = $reader[$f] }
}
$reader.Close()

function Get-RecordHash($v) {
    $s = @()
    foreach ($f in $Config.HashFields) {
        if ($v[$f] -ne $null) { $s += $v[$f].Trim().ToLower() } else { $s += "" }
    }
    $str = $s -join '|'
    $sha = [Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($str)))).Replace('-','').ToLower()
}

# =====================================================
# ================= Batch Insert =====================
# =====================================================
function InsertBatch($rows) {
    if (-not $rows -or $Config.DryRun) { return }

    $cols = $Columns + "RECORDHASH"
    $cmd = $conn.CreateCommand()
    $cmd.Transaction = $tx
    $valuesList = @()

    for ($i=0; $i -lt $rows.Count; $i++) {
        $paramNames = @()
        foreach ($c in $cols) {
            $paramName = "@${c}_$i"
            $paramNames += $paramName
            $value = $rows[$i][$c]
            if ($null -eq $value) { $value = [DBNull]::Value }
            $cmd.Parameters.AddWithValue($paramName, $value) | Out-Null
        }
        $valuesList += "(" + ($paramNames -join ',') + ")"
    }

    $columnList = ($cols -join ',')
    $cmd.CommandText = "INSERT INTO $($Config.TableName) ($columnList) VALUES " + ($valuesList -join ',')
    $global:committedRecords += $cmd.ExecuteNonQuery()
}

# =====================================================
# ================= Import Loop ======================
# =====================================================
$totalRecords = 0
$global:duplicates   = 0
$currentFile  = 0
$globalStart  = Get-Date
$global:committedRecords = 0

foreach ($file in $sqlFiles) {
    $currentFile++
    $reader = [IO.StreamReader]::new($file.FullName,$Config.InputEncoding)
    $batch  = @()
    $lineNo = 0
    $fileSize = (Get-Item $file.FullName).Length
    $bytesRead = 0

    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        $lineNo++
        $bytesRead += ($Config.InputEncoding.GetByteCount($line) + 2) # approx newline
        $row = ParseInsertLine (NormalizeLine $line) $Columns
        if (-not $row) { continue }

        $hash = Get-RecordHash $row
        $totalRecords++

		# Handle duplicate records
		if ($existingHashes.ContainsKey($hash)) {
			Process-Duplicate $row $hash $file $lineNo
			continue
		}

        $row.RECORDHASH = $hash
        $existingHashes[$hash] = $true
        $existingRecords[$hash] = @{ }
        foreach ($f in $Config.HashFields) { $existingRecords[$hash][$f] = $row[$f] }

        $batch += $row
        if ($batch.Count -ge $Config.BatchSize) { InsertBatch $batch; $batch=@() }

        $percentFile = [math]::Round(($bytesRead/$fileSize)*100,0)
        Write-Progress -Activity "Processing file $($file.Name)" -Status "$lineNo lines processed" -PercentComplete $percentFile -Id 1
    }

    InsertBatch $batch
    $reader.Close()

    $percentTotal = [math]::Round(($currentFile / $sqlFiles.Count)*100,0)
    Write-Progress -Activity "Overall Progress" -Status "File $currentFile / $($sqlFiles.Count) processed" -PercentComplete $percentTotal -Id 0
}

if (-not $Config.DryRun) { $tx.Commit(); $conn.Close() }

# =====================================================
# ================= Summary ==========================
# =====================================================
$elapsed = Get-ElapsedSeconds $globalStart

$summary = @"
============== allmovies.ps1: Import completed $(Get-Date) ==============
Files processed          : $currentFile
Total records parsed     : $totalRecords
Records committed        : $global:committedRecords
Duplicates logged        : $duplicates
Duplicate log file       : $($Config.DuplicateFile)
Hash fields              : $($Config.HashFields -join ' | ')
Time taken               : {0:N2} sec
Dry-run mode             : $($Config.DryRun)
Drop table before import : $($Config.DropTable)
Input charset            : latin1 (ISO-8859-1)
Output charset           : utf8
SQL file filter          : $($Config.SqlFileFilter)
Excluded files           : $($Config.ExcludeFiles -join ', ')
Database table           : $($Config.TableName)
=========================================================
"@ -f $elapsed

$summary | Out-File $Config.LogFile -Append -Encoding $Config.OutputEncoding
Write-Host $summary -ForegroundColor Green

# =====================================================
# =============== Cleanup Old Logs ===================
# =====================================================
Cleanup-OldFiles $Config.SourceFolder "import_log" ".txt" 1
Cleanup-OldFiles $Config.SourceFolder "duplicates_log" ".txt" 1
