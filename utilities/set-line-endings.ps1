<#
.SYNOPSIS
    Converts line endings in files to LF or CRLF.

.DESCRIPTION
    Updates the line endings in one or more files to use either LF (Unix-style)
    or CRLF (Windows-style) line endings.

.PARAMETER Path
    Path to a file or directory to process.

.PARAMETER Recurse
    When Path is a directory, recursively process all files in subdirectories.

.PARAMETER lf
    Use LF (Unix-style) line endings.

.PARAMETER crlf
    Use CRLF (Windows-style) line endings.

.EXAMPLE
    .\set-line-endings.ps1 myfile.txt -lf
    Converts myfile.txt to use LF line endings.

.EXAMPLE
    .\set-line-endings.ps1 .\src -Recurse -crlf
    Converts all files in the src directory and subdirectories to use CRLF line endings.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Any })]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$lf,

    [Parameter(Mandatory = $false)]
    [switch]$crlf
)

# Validate that exactly one ending type is specified
if (-not $lf -and -not $crlf) {
    throw "You must specify either -lf or -crlf"
}

if ($lf -and $crlf) {
    throw "You cannot specify both -lf and -crlf"
}

# Determine the ending type
$EndingType = if ($lf) { 'lf' } else { 'crlf' }

function Convert-LineEndings {
    param(
        [string]$FilePath,
        [string]$Ending
    )

    try {
        # Read the file as a single string preserving line breaks
        $content = Get-Content -Path $FilePath -Raw

        if ($null -eq $content) {
            Write-Verbose "Skipping empty file: $FilePath"
            return
        }

        # Normalize to LF first (remove all CR characters)
        $normalized = $content -replace "`r`n", "`n" -replace "`r", "`n"

        # Apply the desired line ending
        if ($Ending -eq 'crlf') {
            $converted = $normalized -replace "`n", "`r`n"
        } else {
            $converted = $normalized
        }

        # Only write if content changed
        if ($content -ne $converted) {
            # Write without adding extra newline at end
            [System.IO.File]::WriteAllText($FilePath, $converted)
            Write-Host "Converted: $FilePath" -ForegroundColor Green
        } else {
            Write-Verbose "No change needed: $FilePath"
        }
    } catch {
        Write-Warning "Failed to process $FilePath : $_"
    }
}

# Main script logic
$item = Get-Item -Path $Path

if ($item.PSIsContainer) {
    # It's a directory
    $files = if ($Recurse) {
        Get-ChildItem -Path $Path -File -Recurse
    } else {
        Get-ChildItem -Path $Path -File
    }

    if ($files.Count -eq 0) {
        Write-Host "No files found in the specified path." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Processing $($files.Count) file(s)..." -ForegroundColor Cyan

    foreach ($file in $files) {
        Convert-LineEndings -FilePath $file.FullName -Ending $EndingType
    }
} else {
    # It's a file
    Write-Host "Processing single file..." -ForegroundColor Cyan
    Convert-LineEndings -FilePath $item.FullName -Ending $EndingType
}

Write-Host "Done." -ForegroundColor Cyan
