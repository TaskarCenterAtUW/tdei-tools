BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot 'set-line-endings.ps1'
    
    # Create temporary test directory
    $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "set-line-endings-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
}

AfterAll {
    # Cleanup test directory
    if (Test-Path $script:testRoot) {
        Remove-Item -Path $script:testRoot -Recurse -Force
    }
}

Describe "set-line-endings.ps1" {
    
    Context "Single file conversion" {
        It "converts CRLF file to LF" {
            # Create a file with CRLF
            $testFile = Join-Path $script:testRoot "test-crlf.txt"
            "line1`r`nline2`r`nline3" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            # Run the script
            & $scriptPath $testFile -lf
            
            # Read and verify
            $content = [System.IO.File]::ReadAllText($testFile)
            $content | Should -Be "line1`nline2`nline3"
            $content | Should -Not -Match "`r"
        }
        
        It "converts LF file to CRLF" {
            # Create a file with LF
            $testFile = Join-Path $script:testRoot "test-lf.txt"
            "line1`nline2`nline3" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            # Run the script
            & $scriptPath $testFile -crlf
            
            # Read and verify
            $content = [System.IO.File]::ReadAllText($testFile)
            $content | Should -Be "line1`r`nline2`r`nline3"
            $content | Should -Match "`r`n"
        }
        
        It "handles mixed line endings (converts to target)" {
            # Create a file with mixed CRLF and LF
            $testFile = Join-Path $script:testRoot "test-mixed.txt"
            "line1`r`nline2`nline3`r`n" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            # Run the script to convert to LF
            & $scriptPath $testFile -lf
            
            # Read and verify - all should be LF
            $content = [System.IO.File]::ReadAllText($testFile)
            $content | Should -Match "^line1`nline2`nline3`n$"
            $content -split "`n" | ForEach-Object { $_ | Should -Not -Match "`r" }
        }
        
        It "does not modify files that already have the target ending" {
            # Create a file with LF
            $testFile = Join-Path $script:testRoot "test-unchanged.txt"
            "line1`nline2`nline3" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            # Get initial write time
            $originalTime = (Get-Item $testFile).LastWriteTime
            Start-Sleep -Milliseconds 10
            
            # Run the script with -lf (file already has LF)
            & $scriptPath $testFile -lf
            
            # Verify file wasn't rewritten
            $newTime = (Get-Item $testFile).LastWriteTime
            $newTime | Should -Be $originalTime
        }
    }
    
    Context "Directory conversion" {
        It "converts all files in a directory (non-recursive)" {
            # Create test files
            $subDir = Join-Path $script:testRoot "subdir"
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
            
            "file1`r`ntest" | Out-File -FilePath (Join-Path $script:testRoot "file1.txt") -NoNewline -Encoding UTF8
            "file2`r`ntest" | Out-File -FilePath (Join-Path $script:testRoot "file2.txt") -NoNewline -Encoding UTF8
            "nested`r`ntest" | Out-File -FilePath (Join-Path $subDir "nested.txt") -NoNewline -Encoding UTF8
            
            # Run the script
            & $script:scriptPath $script:testRoot -lf
            
            # Verify files in root are converted
            (Get-Content -Path (Join-Path $script:testRoot "file1.txt") -Raw) | Should -Not -Match "`r"
            (Get-Content -Path (Join-Path $script:testRoot "file2.txt") -Raw) | Should -Not -Match "`r"
            
            # Verify nested file is NOT converted (no -Recurse)
            (Get-Content -Path (Join-Path $subDir "nested.txt") -Raw) | Should -Match "`r"
        }
        
        It "converts all files recursively with -Recurse flag" {
            # Create nested structure
            $subDir = Join-Path $script:testRoot "recursive-test"
            $nestedDir = Join-Path $subDir "nested"
            New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
            
            "root`r`ntest" | Out-File -FilePath (Join-Path $subDir "root.txt") -NoNewline -Encoding UTF8
            "nested`r`ntest" | Out-File -FilePath (Join-Path $nestedDir "nested.txt") -NoNewline -Encoding UTF8
            
            # Run the script with -Recurse
            & $script:scriptPath $subDir -Recurse -lf
            
            # Verify both files are converted
            (Get-Content -Path (Join-Path $subDir "root.txt") -Raw) | Should -Not -Match "`r"
            (Get-Content -Path (Join-Path $nestedDir "nested.txt") -Raw) | Should -Not -Match "`r"
        }
    }
    
    Context "Parameter validation" {
        It "throws error when neither -lf nor -crlf is specified" {
            $testFile = Join-Path $script:testRoot "test-param.txt"
            "test" | Out-File -FilePath $testFile -Encoding UTF8
            
            { & $script:scriptPath $testFile } | Should -Throw "*must specify either -lf or -crlf*"
        }
        
        It "throws error when both -lf and -crlf are specified" {
            $testFile = Join-Path $script:testRoot "test-param2.txt"
            "test" | Out-File -FilePath $testFile -Encoding UTF8
            
            { & $script:scriptPath $testFile -lf -crlf } | Should -Throw "*cannot specify both -lf and -crlf*"
        }
        
        It "throws error when path does not exist" {
            $nonExistentPath = Join-Path $script:testRoot "does-not-exist.txt"
            
            { & $script:scriptPath $nonExistentPath -lf } | Should -Throw
        }
    }
    
    Context "Edge cases" {
        It "handles empty files" {
            $emptyFile = Join-Path $script:testRoot "empty.txt"
            New-Item -ItemType File -Path $emptyFile -Force | Out-Null
            
            # Should not throw
            { & $script:scriptPath $emptyFile -lf } | Should -Not -Throw
            
            # File should still be empty
            (Get-Item $emptyFile).Length | Should -Be 0
        }
        
        It "handles files with only newlines" {
            $newlineFile = Join-Path $script:testRoot "newlines.txt"
            "`r`n`r`n" | Out-File -FilePath $newlineFile -NoNewline -Encoding UTF8
            
            & $script:scriptPath $newlineFile -lf
            
            $content = [System.IO.File]::ReadAllText($newlineFile)
            $content | Should -Be "`n`n"
        }
        
        It "preserves file without trailing newline" {
            $noTrailingFile = Join-Path $script:testRoot "no-trailing.txt"
            "line1`r`nline2" | Out-File -FilePath $noTrailingFile -NoNewline -Encoding UTF8
            
            & $script:scriptPath $noTrailingFile -lf
            
            $content = [System.IO.File]::ReadAllText($noTrailingFile)
            $content | Should -Be "line1`nline2"
            $content[-1] | Should -Not -Be "`n"
        }
    }
}
