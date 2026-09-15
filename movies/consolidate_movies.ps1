Set-PSDebug -Trace 0

$dirPath = "D:\entertainment\collecting\snap2html_directory_listing"

$currentTimestamp = Get-Date -Format g

$timestampSearchString       = "INSERT_TIMESTAMP_HERE"
$movieSearchTitleSearchString = "INSERT_MOVIE_SEARCH_FILE_TITLE_HERE"
$movieDetailsSearchString     = "INSERT_MOVIE_DETAILS_HERE"
$totalFileCountSearchString   = "INSERT_TOTAL_NUMBER_OF_FILES_HERE"
$totalFolderCountSearchString = "INSERT_TOTAL_FOLDER_COUNT_HERE"
$totalFileSizeSearchString    = "INSERT_TOTAL_FILE_SIZE_HERE"

$movieSearchTitle = "Movies:1 - 19999"

$movieSearchTemplateFile = Join-Path $dirPath "search_movies_template.html"
$movieSearchFinalFile    = Join-Path $dirPath "search_movies.html"

# Remove existing output file if present
if (Test-Path $movieSearchFinalFile) {
    Remove-Item $movieSearchFinalFile -Force
}

# Letters to process
$letters = 'I','J','K','L','M','N'

# Totals
$totalMovies = 0
$totalFolders = 0
$totalSize = [bigint]0

# Holds all movie detail lines
$movieDetails = [System.Collections.Generic.List[string]]::new()

foreach ($letter in $letters)
{
    $movieFile = Join-Path $dirPath "Movies_$letter.html"

    if (-not (Test-Path $movieFile))
    {
        Write-Host "Skipping missing file: $movieFile"
        continue
    }

    Write-Host "Processing Movies_$letter.html"

    # Read file once
    $content = Get-Content $movieFile -Raw

    #
    # Extract movie detail lines
    #
    $movieLines =
        ($content -split "`r?`n") |
        Where-Object { $_ -match "D\.p\(\[`"$letter" } |
        Select-Object -Skip 1

    foreach ($line in $movieLines) {
        $movieDetails.Add($line)
    }

    #
    # Extract number of files
    #
    if ($content -match 'var\s+numberOfFiles\s*=\s*(\d+)')
    {
        $movieCount = [int]$Matches[1]
        $totalMovies += $movieCount

        Write-Host "  Files   : $movieCount"
    }

    #
    # Extract folder count
    #
    # Example source text:
    # "...123 files in 45 folders..."
    #
    if ($content -match '(\d+)\s+files\s+in\s+(\d+)\s+folder')
    {
        $folderCount = [int]$Matches[2] - 1
        $totalFolders += $folderCount

        Write-Host "  Folders : $folderCount"
    }

    #
    # Extract movie size
    #
    # Keeping logic similar to original code.
    # Adjust regex if your HTML format changes.
    #
    if ($content -match 'app_header_stats.*?<span[^>]*>(\d+)</span>')
    {
        $movieSize = [bigint]$Matches[1]
        $totalSize += $movieSize

        Write-Host "  Size    : $movieSize"
    }
}

#
# Combine movie detail records
#
$finalMovieDetailsSearchString = $movieDetails -join "`r`n"

#
# Summary
#
Write-Host ""
Write-Host "Timestamp : $currentTimestamp"
Write-Host "Title     : $movieSearchTitle"
Write-Host "Files     : $totalMovies"
Write-Host "Folders   : $totalFolders"
Write-Host "Size      : $totalSize"

#
# Load template once
#
$template = Get-Content $movieSearchTemplateFile -Raw

#
# Replace placeholders
#
$template = $template.Replace(
    $timestampSearchString,
    [string]$currentTimestamp
)

$template = $template.Replace(
    $movieSearchTitleSearchString,
    $movieSearchTitle
)

$template = $template.Replace(
    $movieDetailsSearchString,
    $finalMovieDetailsSearchString
)

$template = $template.Replace(
    $totalFileCountSearchString,
    [string]$totalMovies
)

$template = $template.Replace(
    $totalFolderCountSearchString,
    [string]$totalFolders
)

$template = $template.Replace(
    $totalFileSizeSearchString,
    [string]$totalSize
)

#
# Write output once
#
Set-Content -Path $movieSearchFinalFile -Value $template -Encoding UTF8

Write-Host ""
Write-Host "Created: $movieSearchFinalFile"

<# Set-PSDebug -Trace 0;

$dirPath = "D:\entertainment\collecting\snap2html_directory_listing\"

$iMoviesFile = $dirPath + "Movies_I.html"
$jMoviesFile = $dirPath + "Movies_J.html"
$kMoviesFile = $dirPath + "Movies_K.html"
$lMoviesFile = $dirPath + "Movies_L.html"
$mMoviesFile = $dirPath + "Movies_M.html"
$nMoviesFile = $dirPath + "Movies_N.html"


$currentTimestamp = Get-Date -Format g
$timestampSearchString = "INSERT_TIMESTAMP_HERE"
$movieSearchTitleSearchString = "INSERT_MOVIE_SEARCH_FILE_TITLE_HERE"
$movieSearchTitle = "Movies:1 - 19999"
$movieDetailsSearchString = "INSERT_MOVIE_DETAILS_HERE"
$totalFileCountSearchString = "INSERT_TOTAL_NUMBER_OF_FILES_HERE"
$totalFolderCountSearchString = "INSERT_TOTAL_FOLDER_COUNT_HERE"
$totalFileSizeSearchString = "INSERT_TOTAL_FILE_SIZE_HERE"

$movieSearchTemplateFile = $dirPath + "search_movies_template.html"
$movieSearchFinalFile = $dirPath + "search_movies.html"

if (Test-Path $movieSearchFinalFile) 
{
  Remove-Item $movieSearchFinalFile
}

if (Test-Path $movieSearchTemplateFile) 
{
  Copy-Item $movieSearchTemplateFile -Destination $movieSearchFinalFile
}

$iMovie_count = 0
$iFolder_Count= 0
$iMovie_size = 0
$iMovies = ""
if (Test-Path $iMoviesFile) 
{
	$iMovies = (Get-Content -path $iMoviesFile | Where-Object { $_ -match "D.p\(\[`"[I]" } | select -Skip 1) -join "`r`n"
	#$iMovies = (Get-Content -path $dirPath + "Movies_I.html" | Where-Object { $_ -match "D.p\(\[`"[I]" } | select -Skip 1) -join "`r`n"

	
	$found = (Get-Content -path $iMoviesFile) -match 'var numberOfFiles = (\d+)'
	if ($found) {
		$iMovie_count = ($found -split("= ")).Split(';')[1]
	}
	$iMovie_count
	$found = ""
	
	$found = (Get-Content -path $iMoviesFile) -match 'div class="app_header_stats">(\d+)'

    if ($found) {
        $iFolder_Count = (($found -split("files in "))[1].split(" folder")[0]) - 1
    }
	if ($found) {
		$iMovie_size = (($found -split("/span"))[0].split(">")[2]).Split("<")[0]
	}
	$iMovie_size
}

$jMovie_count = 0
$jFolder_Count= 0
$jMovie_size = 0
$jMovies = ""
if (Test-Path $jMoviesFile) 
{
	$jMovies = (Get-Content -path $jMoviesFile | Where-Object { $_ -match "D.p\(\[`"[J]" } | select -Skip 1) -join "`r`n"
	#$jMovies = (Get-Content -path $dirPath + "Movies_J.html" | Where-Object { $_ -match "D.p\(\[`"[J]" } | select -Skip 1) -join "`r`n"
	
	$found = (Get-Content -path $jMoviesFile) -match 'var numberOfFiles = (\d+)'
	if ($found) {
		$jMovie_count = ($found -split("= ")).Split(';')[1]
	}
	$jMovie_count
	$found = ""
	
	$found = (Get-Content -path $jMoviesFile) -match 'div class="app_header_stats">(\d+)'

    if ($found) {
        $jFolder_Count = (($found -split("files in "))[1].split(" folder")[0]) - 1
    }
	if ($found) {
		$jMovie_size = (($found -split("/span"))[0].split(">")[2]).Split("<")[0]
	}
	$jMovie_size
}

$kMovie_count = 0
$kFolder_Count= 0
$kMovie_size = 0
$kMovies = ""
if (Test-Path $kMoviesFile) 
{
	$kMovies = (Get-Content -path $kMoviesFile | Where-Object { $_ -match "D.p\(\[`"[K]" } | select -Skip 1) -join "`r`n"
	#$kMovies = (Get-Content -path $dirPath + "Movies_K.html" | Where-Object { $_ -match "D.p\(\[`"[K]" } | select -Skip 1) -join "`r`n"
	
	$found = (Get-Content -path $kMoviesFile) -match 'var numberOfFiles = (\d+)'
	if ($found) {
		$kMovie_count = ($found -split("= ")).Split(';')[1]
	}
	$kMovie_count
	$found = ""
	
	$found = (Get-Content -path $kMoviesFile) -match 'div class="app_header_stats">(\d+)'

    if ($found) {
        $kFolder_Count = (($found -split("files in "))[1].split(" folder")[0]) - 1
    }
	if ($found) {
		$kMovie_size = (($found -split("/span"))[0].split(">")[2]).Split("<")[0]
	}
	$kMovie_size
}

$lMovie_count = 0
$lFolder_Count= 0
$lMovie_size = 0
$lMovies = ""
if (Test-Path $lMoviesFile) 
{
	$lMovies = (Get-Content -path $lMoviesFile | Where-Object { $_ -match "D.p\(\[`"[L]" } | select -Skip 1) -join "`r`n"
	#$lMovies = (Get-Content -path $dirPath + "Movies_L.html" | Where-Object { $_ -match "D.p\(\[`"[L]" } | select -Skip 1) -join "`r`n"
	
	$found = (Get-Content -path $lMoviesFile) -match 'var numberOfFiles = (\d+)'
	if ($found) {
		$lMovie_count = ($found -split("= ")).Split(';')[1]
	}
	$lMovie_count
	$found = ""
	
	$found = (Get-Content -path $lMoviesFile) -match 'div class="app_header_stats">(\d+)'

    if ($found) {
		$lFolder_Count = (($found -split("files in "))[1].split(" folder")[0]) - 1
	}

	if ($found) {
		$lMovie_size = (($found -split("/span"))[0].split(">")[2]).Split("<")[0]
	}
	$lMovie_size
}

$mMovie_count = 0
$mFolder_Count= 0
$mMovie_size = 0
$mMovies = ""
if (Test-Path $mMoviesFile) 
{
	$mMovies = (Get-Content -path $mMoviesFile | Where-Object { $_ -match "D.p\(\[`"[M]" } | select -Skip 1) -join "`r`n"
	#$mMovies = (Get-Content -path $dirPath + "Movies_M.html" | Where-Object { $_ -match "D.p\(\[`"[M]" } | select -Skip 1) -join "`r`n"

	
	$found = (Get-Content -path $mMoviesFile) -match 'var numberOfFiles = (\d+)'
	if ($found) {
		$mMovie_count = ($found -split("= ")).Split(';')[1]
	}
	$mMovie_count
	$found = ""
	
	$found = (Get-Content -path $mMoviesFile) -match 'div class="app_header_stats">(\d+)'

    if ($found) {
        $mFolder_Count = (($found -split("files in "))[1].split(" folder")[0]) - 1
    }
	if ($found) {
		$mMovie_size = (($found -split("/span"))[0].split(">")[2]).Split("<")[0]
	}
	$mMovie_size
}


$nMovie_count = 0
$nFolder_Count= 0
$nMovie_size = 0
$nMovies = ""
if (Test-Path $nMoviesFile) 
{
	$nMovies = (Get-Content -path $nMoviesFile | Where-Object { $_ -match "D.p\(\[`"[N]" } | select -Skip 1) -join "`r`n"
	#$mMovies = (Get-Content -path $dirPath + "Movies_N.html" | Where-Object { $_ -match "D.p\(\[`"[N]" } | select -Skip 1) -join "`r`n"

	
	$found = (Get-Content -path $nMoviesFile) -match 'var numberOfFiles = (\d+)'
	if ($found) {
		$nMovie_count = ($found -split("= ")).Split(';')[1]
	}
	$nMovie_count
	$found = ""
	
	$found = (Get-Content -path $nMoviesFile) -match 'div class="app_header_stats">(\d+)'

    if ($found) {
        $nFolder_Count = (($found -split("files in "))[1].split(" folder")[0]) - 1
    }
	if ($found) {
		$nMovie_size = (($found -split("/span"))[0].split(">")[2]).Split("<")[0]
	}
	$nMovie_size
}

$finalMovieDetailsSearchString = -join $iMovies, $jMovies, $kMovies, $lMovies, $mMovies, $nMovies -join "`r`n"

$finalMoviesCount = [int]$iMovie_count + [int]$jMovie_count + [int]$kMovie_count + [int]$lMovie_count + [int]$mMovie_count + [int]$nMovie_count
$finalFolderCount = [int]$iFolder_Count + [int]$jFolder_Count + [int]$kFolder_Count + [int]$lFolder_Count + [int]$mFolder_Count + [int]$nFolder_Count
$finalMoviesSize = [bigint]$iMovie_size + [bigint]$jMovie_size + [bigint]$kMovie_size + [bigint]$lMovie_size + [bigint]$mMovie_size + [bigint]$nMovie_size

$currentTimestamp
$movieSearchTitle
#$movieDetailsSearchString
$finalMoviesCount
$finalFolderCount
$finalMoviesSize


#$moviesTemplate = (Get-Content $movieSearchTemplateFile | Where-Object { $_ -notmatch "D.p\(\[`"[IJKLMN]" }) -join "`r`n"
$moviesTemplate = Get-Content $movieSearchTemplateFile
$moviesTemplate = $moviesTemplate.replace($timestampSearchString,$currentTimestamp)
$moviesTemplate = $moviesTemplate.replace($movieSearchTitleSearchString,$movieSearchTitle)
$moviesTemplate = $moviesTemplate.replace($movieDetailsSearchString,$finalMovieDetailsSearchString)
$moviesTemplate = $moviesTemplate.replace($totalFileCountSearchString,$finalMoviesCount)
$moviesTemplate = $moviesTemplate.replace($totalFolderCountSearchString,$finalFolderCount)
$moviesTemplate = $moviesTemplate.replace($totalFileSizeSearchString,$finalMoviesSize)
$moviesTemplate | Out-File -filepath $movieSearchFinalFile
#$movieSearchFinalFile = (Get-Content $dirPath + "temp.html" | Foreach-Object { $_;if ($_ -match "D.p\(\[`"[Movies]") { $a;$b;$c;$d;$e } })

#exit #>
