#Requires -Version 7.0

Set-StrictMode -Version Latest

#region ── Private helpers ────────────────────────────────────────────────────

function Get-StagedPath {
    param([string]$OriginalPath, [string]$StagingRoot)
    # C:\Foo\file.txt  → <staging>\C\Foo\file.txt
    # \\server\share\f → <staging>\UNC\server\share\f
    $relative = if ($OriginalPath -match '^\\\\') {
        $OriginalPath -replace '^\\\\', 'UNC\'
    } else {
        $OriginalPath -replace '^([A-Za-z]):\\', '$1\'
    }
    Join-Path $StagingRoot $relative
}

function Get-PartialFileHash {
    [OutputType([string])]
    param([string]$Path, [int]$ByteCount = 65536)
    try {
        $fs  = [System.IO.File]::OpenRead($Path)
        $buf = [byte[]]::new([Math]::Min($ByteCount, $fs.Length))
        [void]$fs.Read($buf, 0, $buf.Length)
        $fs.Close()
        [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash($buf)
        ) -replace '-'
    } catch {
        Write-Verbose "Partial hash skipped ($Path): $_"
        $null
    }
}

#endregion

#region ── Public functions ───────────────────────────────────────────────────

function Get-DuplicateCandidateFile {
    <#
    .SYNOPSIS Scans root paths and emits FileInfo objects for all eligible files.
    .DESCRIPTION
        Uses a queue-based traversal to avoid following junction points or reparse
        points that would cause infinite recursion. Skips symlinks, hard links, and
        any folder name listed in ExcludeFolder.
    .PARAMETER Path
        One or more root paths to scan. Accepts drive roots, folders, or UNC paths.
    .PARAMETER ExcludeFolder
        Folder names to skip during traversal (matched on folder name, not full path).
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string[]] $Path,
        [string[]] $ExcludeFolder = @('.git', 'node_modules', '.vs')
    )

    for ($r = 0; $r -lt $Path.Count; $r++) {
        $root = $Path[$r]
        Write-Progress -Activity 'Scanning' -Status $root `
            -PercentComplete ([int](($r / $Path.Count) * 100))

        if (-not (Test-Path -LiteralPath $root)) {
            Write-Warning "Path not found, skipping: $root"
            continue
        }

        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($root)

        while ($queue.Count -gt 0) {
            $dir = $queue.Dequeue()

            # Emit eligible files in this directory
            Get-ChildItem -LiteralPath $dir -Force -File -ErrorAction SilentlyContinue |
                Where-Object {
                    -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                    $_.LinkType -notin @('SymbolicLink', 'HardLink')
                }

            # Enqueue subdirectories — skip junctions and excluded names
            Get-ChildItem -LiteralPath $dir -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object {
                    -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                    $_.Name -notin $ExcludeFolder
                } | ForEach-Object { $queue.Enqueue($_.FullName) }
        }
    }

    Write-Progress -Activity 'Scanning' -Completed
}

function Confirm-FileDuplicate {
    <#
    .SYNOPSIS Accepts FileInfo objects from the pipeline and emits verified duplicate pairs.
    .DESCRIPTION
        Groups files by exact byte size, then eliminates non-matches with a 64 KB partial
        hash before computing a full hash — keeping expensive full-file reads to a minimum.
        Only confirmed matching pairs are emitted; false positives are discarded silently.
    .PARAMETER File
        FileInfo objects to evaluate, typically piped from Get-DuplicateCandidateFile.
    .PARAMETER Algorithm
        Hash algorithm used for full verification: SHA256 (default), MD5, or SHA1.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][System.IO.FileInfo] $File,
        [ValidateSet('SHA256', 'MD5', 'SHA1')][string] $Algorithm = 'SHA256'
    )
    begin {
        $allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    }
    process {
        $allFiles.Add($File)
    }
    end {
        $sizeGroups = $allFiles | Group-Object Length | Where-Object { $_.Count -gt 1 }
        $total = @($sizeGroups).Count
        $done  = 0

        foreach ($group in $sizeGroups) {
            $done++
            $sizeMB = [math]::Round([long]$group.Name / 1MB, 1)
            Write-Progress -Activity 'Verifying duplicates' `
                -Status "Group $done / $total  ($sizeMB MB each  ·  $($group.Count) candidates)" `
                -PercentComplete ([int](($done / $total) * 100))

            $files = $group.Group

            # Phase 1 — partial hash eliminates most non-matches with minimal I/O
            $partialMap = @{}
            foreach ($f in $files) {
                $h = Get-PartialFileHash -Path $f.FullName
                if ($h) { $partialMap[$f.FullName] = $h }
            }

            $partialGroups = $files |
                Where-Object  { $partialMap.ContainsKey($_.FullName) } |
                Group-Object  { $partialMap[$_.FullName] } |
                Where-Object  { $_.Count -gt 1 }

            # Phase 2 — full hash only within partial-hash sub-groups
            foreach ($pg in $partialGroups) {
                $candidates = $pg.Group
                $hashMap    = @{}

                foreach ($f in $candidates) {
                    try {
                        $hashMap[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm $Algorithm).Hash
                    } catch {
                        Write-Verbose "Full hash failed ($($f.FullName)): $_"
                    }
                }

                for ($i = 0; $i -lt $candidates.Count; $i++) {
                    for ($j = $i + 1; $j -lt $candidates.Count; $j++) {
                        $a  = $candidates[$i]
                        $b  = $candidates[$j]
                        $ha = $hashMap[$a.FullName]
                        $hb = $hashMap[$b.FullName]

                        if ($ha -and $hb -and $ha -eq $hb) {
                            [PSCustomObject]@{
                                FileA_Path     = $a.FullName
                                FileA_SizeMB   = [math]::Round($a.Length / 1MB, 2)
                                FileA_Modified = $a.LastWriteTime
                                FileB_Path     = $b.FullName
                                FileB_SizeMB   = [math]::Round($b.Length / 1MB, 2)
                                FileB_Modified = $b.LastWriteTime
                                Hash           = $ha
                                ScannedAt      = [datetime]::UtcNow
                                Status         = 'Pending'
                                StagedPath     = $null
                                StagedAt       = $null
                            }
                        }
                    }
                }
            }
        }

        Write-Progress -Activity 'Verifying duplicates' -Completed
    }
}

function Move-FileToStaging {
    <#
    .SYNOPSIS Moves a file to the staging root, preserving its original directory structure.
    .DESCRIPTION
        Drive letters become top-level folders under the staging root
        (C:\Foo\file.txt → <StagingRoot>\C\Foo\file.txt).
        UNC paths land under UNC\ (\\server\share\file → <StagingRoot>\UNC\server\share\file).
        Supports -WhatIf. Returns the destination path on success, or $null if skipped.
    .PARAMETER Path
        The source file path to move.
    .PARAMETER StagingRoot
        Destination root under which the original directory structure is recreated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $StagingRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Source no longer exists, skipping: $Path"
        return $null
    }

    $dest    = Get-StagedPath -OriginalPath $Path -StagingRoot $StagingRoot
    $destDir = Split-Path $dest -Parent

    if ($PSCmdlet.ShouldProcess($Path, "Move to staging at $dest")) {
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Move-Item -LiteralPath $Path -Destination $dest -Force
        Write-Verbose "Staged: $Path → $dest"
        return $dest
    }
    return $null
}

function Export-DuplicateReport {
    <#
    .SYNOPSIS Saves duplicate pairs to a JSON report and a companion CSV.
    .DESCRIPTION
        JSON is the canonical record — it preserves Status and StagedPath for re-runs.
        CSV is a flat human-readable view suitable for Excel or manual triage.
    .PARAMETER Pair
        Duplicate pair objects to export, typically piped from Confirm-FileDuplicate.
    .PARAMETER Path
        Destination path for the JSON report. A companion CSV is written at the same
        location with a .csv extension.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][PSCustomObject] $Pair,
        [Parameter(Mandatory)][string] $Path
    )
    begin   { $pairs = [System.Collections.Generic.List[PSCustomObject]]::new() }
    process { $pairs.Add($Pair) }
    end {
        [ordered]@{
            GeneratedAt   = [datetime]::UtcNow.ToString('o')
            PairCount     = $pairs.Count
            RecoverableMB = [math]::Round(($pairs | Measure-Object FileA_SizeMB -Sum).Sum, 2)
            Pairs         = $pairs
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8

        $csvPath = [System.IO.Path]::ChangeExtension($Path, '.csv')
        $pairs | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

        Write-Verbose "Saved: $Path  +  $csvPath"
    }
}

function Import-DuplicateReport {
    <#
    .SYNOPSIS Loads a JSON report and emits the stored duplicate pairs to the pipeline.
    .PARAMETER Path
        Path to a JSON report previously written by Export-DuplicateReport.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Report not found: $Path" }

    $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Write-Verbose "Loaded report from $($report.GeneratedAt) — $($report.PairCount) pairs"
    $report.Pairs
}

function Show-DuplicateReport {
    <#
    .SYNOPSIS Displays a summary and the top duplicate pairs sorted by recoverable size.
    .DESCRIPTION
        Shows the top $TopN pairs (default 25) by file size. For the full list, open the
        companion CSV. Pairs are labelled Keep/Duplicate to reflect staging intent.
    .PARAMETER Pair
        Duplicate pair objects to display, typically piped from Import-DuplicateReport or
        Confirm-FileDuplicate.
    .PARAMETER ReportPath
        When provided, the companion CSV path is shown in the report footer.
    .PARAMETER TopN
        Maximum number of pairs to display in the table. Defaults to 25.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][PSCustomObject] $Pair,
        [string] $ReportPath,
        [int]    $TopN = 25
    )
    begin   { $all = [System.Collections.Generic.List[PSCustomObject]]::new() }
    process { $all.Add($Pair) }
    end {
        $pending     = @($all | Where-Object { $_.Status -eq 'Pending' })
        $staged      = @($all | Where-Object { $_.Status -eq 'Staged' })
        $recoverMB   = [math]::Round(($all | Measure-Object FileA_SizeMB -Sum).Sum, 2)

        Write-Host ''
        Write-Host 'Duplicate File Report' -ForegroundColor Cyan
        Write-Host ('─' * 72) -ForegroundColor DarkGray
        Write-Host ("  Total pairs    : {0}"    -f $all.Count)
        Write-Host ("  Pending review : {0}"    -f $pending.Count)
        Write-Host ("  Staged         : {0}"    -f $staged.Count)
        Write-Host ("  Recoverable    : {0} MB" -f $recoverMB)
        if ($ReportPath) {
            Write-Host ("  Full list CSV  : {0}" -f ([System.IO.Path]::ChangeExtension($ReportPath, '.csv'))) `
                -ForegroundColor DarkGray
        }
        Write-Host ('─' * 72) -ForegroundColor DarkGray

        $all | Sort-Object FileA_SizeMB -Descending | Select-Object -First $TopN |
            Select-Object `
                @{ n = 'Keep';         e = { Split-Path $_.FileA_Path -Leaf } },
                FileA_SizeMB,
                @{ n = 'Keep (dir)';   e = { Split-Path $_.FileA_Path -Parent } },
                @{ n = 'Duplicate';    e = { Split-Path $_.FileB_Path -Leaf } },
                @{ n = 'Dup (dir)';    e = { Split-Path $_.FileB_Path -Parent } },
                Status,
                StagedPath |
            Format-Table -AutoSize -Wrap

        if ($all.Count -gt $TopN) {
            Write-Host ("  … and {0} more pair(s) — open the CSV for the full list." -f ($all.Count - $TopN)) `
                -ForegroundColor DarkGray
        }
    }
}

function Invoke-DuplicateScan {
    <#
    .SYNOPSIS Orchestrates scanning, verification, staging, and report output.
    .DESCRIPTION
        First run: scans provided paths and writes a JSON + CSV report.
        Subsequent runs: use -FromReport to skip the scan and work from the saved report.
        Use -Stage to move the duplicate (FileB) from each pending pair to the staging area.
        The original file (FileA) is never touched. No files are deleted.
    .PARAMETER Path
        One or more root paths to scan. Accepts drive roots, folders, or UNC paths.
    .PARAMETER StagingRoot
        Destination root for staged duplicates. Required when -Stage is used.
        Original directory structure is preserved beneath this root.
    .PARAMETER ReportPath
        Path for the JSON report. Defaults to .\duplicate-report.json.
        A companion CSV is written at the same location with a .csv extension.
    .PARAMETER FromReport
        Load a previously saved report instead of performing a new scan.
    .PARAMETER Stage
        Move the lower-priority file from each pending pair to the staging area.
        Requires -StagingRoot. Supports -WhatIf.
    .PARAMETER ExcludeFolder
        Folder names to skip during traversal (matched on folder name, not full path).
    .PARAMETER Algorithm
        Hash algorithm used for full verification: SHA256 (default), MD5, or SHA1.
    .EXAMPLE
        # Full scan across two drives, stage duplicates
        Invoke-DuplicateScan -Path 'C:\', 'D:\' -StagingRoot 'E:\Staging' -Stage

        # Preview staging without moving anything
        Invoke-DuplicateScan -Path 'C:\', 'D:\' -StagingRoot 'E:\Staging' -Stage -WhatIf

        # Reload a previous report and display it without re-scanning
        Invoke-DuplicateScan -FromReport -ReportPath '.\duplicate-report.json'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]] $Path,
        [string]   $StagingRoot,
        [string]   $ReportPath    = '.\duplicate-report.json',
        [switch]   $FromReport,
        [switch]   $Stage,
        [string[]] $ExcludeFolder = @('.git', 'node_modules', '.vs'),
        [ValidateSet('SHA256', 'MD5', 'SHA1')]
        [string]   $Algorithm     = 'SHA256'
    )

    if ($Stage -and -not $StagingRoot) {
        throw '-StagingRoot is required when using -Stage.'
    }

    # ── Load or scan ──────────────────────────────────────────────────────────
    $pairs = if ($FromReport) {
        Write-Host "Loading report: $ReportPath" -ForegroundColor Cyan
        @(Import-DuplicateReport -Path $ReportPath)
    } else {
        Write-Host "Scanning $($Path.Count) path(s)..." -ForegroundColor Cyan
        $found = @(
            Get-DuplicateCandidateFile -Path $Path -ExcludeFolder $ExcludeFolder |
            Confirm-FileDuplicate -Algorithm $Algorithm
        )
        $found | Export-DuplicateReport -Path $ReportPath
        $csvPath = [System.IO.Path]::ChangeExtension($ReportPath, '.csv')
        Write-Host "Found $($found.Count) duplicate pair(s). Report: $ReportPath  |  $csvPath" `
            -ForegroundColor DarkCyan
        $found
    }

    # ── Stage pending duplicates ──────────────────────────────────────────────
    if ($Stage) {
        $pending = @($pairs | Where-Object { $_.Status -eq 'Pending' })
        Write-Host "Staging $($pending.Count) pending pair(s) to $StagingRoot..." -ForegroundColor Cyan
        $stagedCount = 0

        for ($s = 0; $s -lt $pending.Count; $s++) {
            $pair = $pending[$s]
            Write-Progress -Activity 'Staging' -Status (Split-Path $pair.FileB_Path -Leaf) `
                -PercentComplete ([int](($s / $pending.Count) * 100))

            $dest = Move-FileToStaging -Path $pair.FileB_Path -StagingRoot $StagingRoot
            if ($dest) {
                $pair.StagedPath = $dest
                $pair.StagedAt   = [datetime]::UtcNow.ToString('o')
                $pair.Status     = 'Staged'
                $stagedCount++
            }
        }

        Write-Progress -Activity 'Staging' -Completed

        if ($stagedCount -gt 0) {
            $pairs | Export-DuplicateReport -Path $ReportPath
            Write-Host "Staged $stagedCount file(s). Report updated." -ForegroundColor DarkCyan
        }
    }

    # ── Display ───────────────────────────────────────────────────────────────
    $pairs | Show-DuplicateReport -ReportPath $ReportPath
}

#endregion

Export-ModuleMember -Function @(
    'Get-DuplicateCandidateFile'
    'Confirm-FileDuplicate'
    'Move-FileToStaging'
    'Export-DuplicateReport'
    'Import-DuplicateReport'
    'Show-DuplicateReport'
    'Invoke-DuplicateScan'
)
