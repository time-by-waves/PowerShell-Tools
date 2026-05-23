#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module "$PSScriptRoot\file-duplication.psm1" -Force
}

# ── Get-StagedPath ────────────────────────────────────────────────────────────

Describe 'Get-StagedPath' {
    It 'converts a drive-letter path: C:\Foo\file.txt → <staging>\C\Foo\file.txt' {
        InModuleScope 'file-duplication' {
            $result = Get-StagedPath -OriginalPath 'C:\Foo\file.txt' -StagingRoot 'D:\Staging'
            $result | Should -Be 'D:\Staging\C\Foo\file.txt'
        }
    }

    It 'converts a UNC path: \\server\share\file → <staging>\UNC\server\share\file' {
        InModuleScope 'file-duplication' {
            $result = Get-StagedPath -OriginalPath '\\server\share\file.txt' -StagingRoot 'D:\Staging'
            $result | Should -Be 'D:\Staging\UNC\server\share\file.txt'
        }
    }
}

# ── Get-DuplicateCandidateFile ────────────────────────────────────────────────

Describe 'Get-DuplicateCandidateFile' {
    BeforeAll {
        # Regular files
        $null = New-Item -ItemType Directory -Path 'TestDrive:\scan\sub' -Force
        Set-Content -Path 'TestDrive:\scan\file1.txt'     -Value 'alpha' -NoNewline -Encoding UTF8
        Set-Content -Path 'TestDrive:\scan\sub\file2.txt' -Value 'beta'  -NoNewline -Encoding UTF8

        # Excluded folder
        $null = New-Item -ItemType Directory -Path 'TestDrive:\scan\.git' -Force
        Set-Content -Path 'TestDrive:\scan\.git\config'   -Value 'git'   -NoNewline -Encoding UTF8
    }

    It 'finds all eligible files under the root' {
        $result = @(Get-DuplicateCandidateFile -Path 'TestDrive:\scan' -ExcludeFolder '.git')
        $result.Count | Should -Be 2
    }

    It 'does not include files inside an excluded folder' {
        $result = @(Get-DuplicateCandidateFile -Path 'TestDrive:\scan' -ExcludeFolder '.git')
        $result.FullName | Should -Not -Contain { $_ -like '*\.git\*' }
    }

    It 'warns and does not throw for a non-existent path' {
        { Get-DuplicateCandidateFile -Path 'Z:\DoesNotExist93847' -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'returns FileInfo objects' {
        $result = @(Get-DuplicateCandidateFile -Path 'TestDrive:\scan' -ExcludeFolder '.git')
        $result[0] | Should -BeOfType [System.IO.FileInfo]
    }
}

# ── Confirm-FileDuplicate ─────────────────────────────────────────────────────

Describe 'Confirm-FileDuplicate' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path 'TestDrive:\dupes' -Force
        Set-Content -Path 'TestDrive:\dupes\dup_a.txt'  -Value 'identical content' -NoNewline -Encoding UTF8
        Set-Content -Path 'TestDrive:\dupes\dup_b.txt'  -Value 'identical content' -NoNewline -Encoding UTF8
        Set-Content -Path 'TestDrive:\dupes\unique.txt' -Value 'something else'    -NoNewline -Encoding UTF8
    }

    It 'emits exactly one pair for two identical files' {
        $result = @(Get-ChildItem 'TestDrive:\dupes' -File | Confirm-FileDuplicate)
        $result.Count | Should -Be 1
    }

    It 'emitted pair has the correct shape and Status = Pending' {
        $pair = Get-ChildItem 'TestDrive:\dupes' -File | Confirm-FileDuplicate | Select-Object -First 1
        $pair.Hash       | Should -Not -BeNullOrEmpty
        $pair.Status     | Should -Be 'Pending'
        $pair.StagedPath | Should -BeNullOrEmpty
        $pair.FileA_Path | Should -Not -BeNullOrEmpty
        $pair.FileB_Path | Should -Not -BeNullOrEmpty
    }

    It 'both paths in the pair point to the identical files' {
        $pair = Get-ChildItem 'TestDrive:\dupes' -File | Confirm-FileDuplicate | Select-Object -First 1
        $names = @(Split-Path $pair.FileA_Path -Leaf; Split-Path $pair.FileB_Path -Leaf)
        $names | Should -Contain 'dup_a.txt'
        $names | Should -Contain 'dup_b.txt'
    }

    It 'does not emit a pair when no two files share content' {
        $result = @(
            Get-ChildItem 'TestDrive:\dupes' -File |
                Where-Object Name -ne 'dup_b.txt' |
                Confirm-FileDuplicate
        )
        $result.Count | Should -Be 0
    }

    It 'FileA_SizeMB and FileB_SizeMB are numeric' {
        $pair = Get-ChildItem 'TestDrive:\dupes' -File | Confirm-FileDuplicate | Select-Object -First 1
        $pair.FileA_SizeMB | Should -BeOfType [double]
        $pair.FileB_SizeMB | Should -BeOfType [double]
    }
}

# ── Move-FileToStaging ────────────────────────────────────────────────────────

Describe 'Move-FileToStaging' {
    It 'moves the file and leaves nothing at the source' {
        $null = New-Item -ItemType Directory -Path 'TestDrive:\mv\sub' -Force
        Set-Content -Path 'TestDrive:\mv\sub\file.txt' -Value 'data' -NoNewline -Encoding UTF8

        Move-FileToStaging -Path 'TestDrive:\mv\sub\file.txt' -StagingRoot 'TestDrive:\mv-stage'

        'TestDrive:\mv\sub\file.txt' | Should -Not -Exist
    }

    It 'creates exactly one file under the staging root' {
        $staged = @(Get-ChildItem 'TestDrive:\mv-stage' -Recurse -File)
        $staged.Count | Should -Be 1
    }

    It 'preserves the original filename in the staged location' {
        $staged = Get-ChildItem 'TestDrive:\mv-stage' -Recurse -File | Select-Object -First 1
        $staged.Name | Should -Be 'file.txt'
    }

    It 'does not move the file when -WhatIf is specified' {
        $null = New-Item -ItemType Directory -Path 'TestDrive:\whatif\sub' -Force
        Set-Content -Path 'TestDrive:\whatif\sub\file.txt' -Value 'data' -NoNewline -Encoding UTF8

        Move-FileToStaging -Path 'TestDrive:\whatif\sub\file.txt' `
            -StagingRoot 'TestDrive:\whatif-stage' -WhatIf

        'TestDrive:\whatif\sub\file.txt' | Should -Exist
    }

    It 'returns $null and warns when the source does not exist' {
        $result = Move-FileToStaging -Path 'TestDrive:\ghost\missing.txt' `
            -StagingRoot 'TestDrive:\ghost-stage' -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }
}

# ── Export-DuplicateReport / Import-DuplicateReport ───────────────────────────

Describe 'Export-DuplicateReport and Import-DuplicateReport' {
    BeforeAll {
        $script:reportPath = 'TestDrive:\report.json'
        $script:csvPath    = 'TestDrive:\report.csv'

        $pair = [PSCustomObject]@{
            FileA_Path     = 'C:\a\file.txt'
            FileA_SizeMB   = 2.5
            FileA_Modified = [datetime]'2024-06-01'
            FileB_Path     = 'C:\b\file.txt'
            FileB_SizeMB   = 2.5
            FileB_Modified = [datetime]'2024-06-01'
            Hash           = 'DEADBEEF'
            ScannedAt      = [datetime]::UtcNow
            Status         = 'Pending'
            StagedPath     = $null
            StagedAt       = $null
        }

        $pair | Export-DuplicateReport -Path $script:reportPath
    }

    It 'writes the JSON report file' {
        $script:reportPath | Should -Exist
    }

    It 'writes a companion CSV at the same location' {
        $script:csvPath | Should -Exist
    }

    It 'JSON contains the correct PairCount' {
        $raw = Get-Content $script:reportPath -Raw | ConvertFrom-Json
        $raw.PairCount | Should -Be 1
    }

    It 'round-trips the Hash field correctly' {
        $loaded = @(Import-DuplicateReport -Path $script:reportPath)
        $loaded[0].Hash | Should -Be 'DEADBEEF'
    }

    It 'round-trips the Status field correctly' {
        $loaded = @(Import-DuplicateReport -Path $script:reportPath)
        $loaded[0].Status | Should -Be 'Pending'
    }

    It 'round-trips both file paths correctly' {
        $loaded = @(Import-DuplicateReport -Path $script:reportPath)
        $loaded[0].FileA_Path | Should -Be 'C:\a\file.txt'
        $loaded[0].FileB_Path | Should -Be 'C:\b\file.txt'
    }

    It 'throws when the report file does not exist' {
        { Import-DuplicateReport -Path 'TestDrive:\no-such-report.json' } | Should -Throw
    }
}
