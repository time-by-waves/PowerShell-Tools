try { 
# ==========================================
# 1. CONFIGURATION
# ==========================================
Write-Host "Starting video duplicate finder..." -ForegroundColor Cyan

$videoExtensions = @(".mp4", ".m4v", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm")

$Folders = @(
'C:\Downloads'
'C:\temp'
)


# ==========================================
# 2. FIND ALL VIDEO FILES
# ==========================================
$videoFiles = @()
foreach ($folder in $folders) {
    if (Test-Path $folder) {
        $found = Get-ChildItem -Path $folder -Recurse -ErrorAction SilentlyContinue | 
            Where-Object { $_.Extension -in $videoExtensions -and -not $_.PSIsContainer }
        
        if ($found) { $videoFiles += $found }
    }
}

Write-Host "Found $($videoFiles.Count) video files." -ForegroundColor DarkCyan

# ==========================================
# 3. GENERATE SIZE-BASED PAIRS
# ==========================================
Write-Host "Grouping by size and generating pairs..." -ForegroundColor Cyan
$duplicatePairs = @()

$sizeGroups = $videoFiles | Group-Object Length | Where-Object { $_.Count -gt 1 }

foreach ($group in $sizeGroups) {
    $files = $group.Group
    
    # Loop to create every unique pair (A=B, A=C, B=C, etc.)
    for ($i = 0; $i -lt $files.Count; $i++) {
        for ($j = $i + 1; $j -lt $files.Count; $j++) {
            $fileA = $files[$i]
            $fileB = $files[$j]

            $duplicatePairs += [PSCustomObject]@{
                FileA_Path       = $fileA.FullName
                FileA_Size       = $fileA.Length
                FileA_Modified   = $fileA.LastWriteTime
                FileA_Created    = $fileA.CreationTime
                FileB_Path       = $fileB.FullName
                FileB_Size       = $fileB.Length
                FileB_Modified   = $fileB.LastWriteTime
                FileB_Created    = $fileB.CreationTime
                SizeMatch        = "Yes"
            }
        }
    }
}

Write-Host "Generated $($duplicatePairs.Count) potential pairs based on size." -ForegroundColor DarkCyan


# ==========================================
# 4. VERIFY WITH HASH (SHA256)
# ==========================================
Write-Host "Calculating hashes to verify real matches..." -ForegroundColor Cyan
$verifiedMatches = @()

foreach ($pair in $duplicatePairs) {
    $pathA = $pair.FileA_Path
    $pathB = $pair.FileB_Path

    # Skip if files were moved/deleted since the scan
    if (-not (Test-Path $pathA) -or -not (Test-Path $pathB)) { continue }

    # Calculate Hashes
    $hashA = (Get-FileHash -Path $pathA -Algorithm SHA256).Hash
    $hashB = (Get-FileHash -Path $pathB -Algorithm SHA256).Hash

    $isMatch = ($hashA -eq $hashB)

    $verifiedMatches += [PSCustomObject]@{
        # File A Info
        FileA_Path       = $pathA
        FileA_Size_MB    = [math]::Round($pair.FileA_Size / 1MB, 2)
        FileA_Modified   = $pair.FileA_Modified
        
        # File B Info
        FileB_Path       = $pathB
        FileB_Size_MB    = [math]::Round($pair.FileB_Size / 1MB, 2)
        FileB_Modified   = $pair.FileB_Modified
        
        # Verification
        HashA            = $hashA
        HashB            = $hashB
        IsRealMatch      = $isMatch
        MatchStatus      = if ($isMatch) { "VERIFIED DUPLICATE" } else { "False Positive" }
        
        # Suggested Action (Keep the Newer one)
        Action           = if ($isMatch) {
            if ($pair.FileA_Modified -gt $pair.FileB_Modified) { "Keep A (Newer)" }
            else { "Keep B (Newer)" }
        } else { "N/A" }
    }
}


# ==========================================
# 5. FINAL OUTPUT
# ==========================================
$realMatches = $verifiedMatches | Where-Object { $_.IsRealMatch }

if ($realMatches) {
    Write-Host "`nFound $($realMatches.Count) VERIFIED DUPLICATE PAIRS." -ForegroundColor Green
    
    # Display the "Fat List" of verified matches
    $realMatches | Select-Object `
        FileA_Path, 
        FileA_Modified, 
        FileB_Path, 
        FileB_Modified, 
        Action, 
        MatchStatus | Format-Table -AutoSize -Wrap

    # Optional: Export to CSV for manual review
    # $realMatches | Export-Csv -Path "C:\temp\verified_duplicates.csv" -NoTypeInformation
    Write-Host "`nTo save this list to CSV, uncomment the Export-Csv line in the script." -ForegroundColor Gray
} else {
    Write-Host "`nNo verified duplicates found." -ForegroundColor Gray
}

# $realMatches is now your final list for further processing
} catch { $eor = $_ }
