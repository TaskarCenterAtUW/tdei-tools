#!/usr/bin/env pwsh
# This script is designed to be run in a PowerShell environment.

# Name: TDEI Tools - Images Exif Data Update Script
# Version: 4.0.2
# Date: 2026-03-02
# License: CC-BY-ND 4.0 International
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington

<#
.SYNOPSIS
    Removes all metadata from PNG files and adds CC0 copyright tags

.DESCRIPTION
    This script processes PNG files in a specified directory by removing
    all existing EXIF metadata and adding standardized CC0 Public Domain
    Dedication copyright tags.

.PARAMETER Directory
    Path to the directory containing PNG files to process

.PARAMETER Recursive
    When specified, processes PNG files in the target directory and all subdirectories
    Without this flag, only processes files in the specified directory by default

.EXAMPLE
    .\update-exif.ps1
    Runs the script interactively for files in the specified directory only

.EXAMPLE
    .\update-exif.ps1 -Recursive
    Runs the script interactively for files in the specified directory and all subdirectories

.EXAMPLE
    # Interactive usage (directory only):
    # Directory: [directory-path]
    # Confirmation: y

    Processes PNG files only in [directory-path]

.EXAMPLE
    # Interactive usage (with -Recursive):
    # Directory: [directory-path]
    # Confirmation: y

    Processes PNG files in [directory-path] and all its subdirectories

.NOTES
    Prerequisites:
    - ExifTool must be installed and available in PATH
    - Directory must contain PNG files to process

    IMPORTANT WARNINGS:
    - This script permanently modifies original files
    - All existing EXIF metadata will be permanently removed
    - Ensure you have backups before running!
    - With -Recursive, ALL subdirectories will be processed

    The script performs these operations for each PNG file:
    1. Removes all existing metadata
    2. Adds IFD0:Copyright tag with CC0 dedication
    3. Adds PNG:Copyright tag with CC0 dedication
    4. Overwrites the original file

    Copyright text added:
    "CC0 Public Domain Dedication http://creativecommons.org/publicdomain/zero/1.0/"

    ExifTool installation: https://exiftool.org/install.html

.LINK
    https://github.com/TaskarCenterAtUW/tdei-tools
#>

param(
    [Parameter(Mandatory = $false, HelpMessage = "Process files in subdirectories recursively")]
    [switch]$Recursive
)

# Display script header with version and mode
$scriptMode = if ($Recursive) { "Recursive" } else { "Directory Only" }
Write-Host "TDEI Tools Images Exif Data Update Script v4.0.0 ($scriptMode)" -ForegroundColor Blue

if ($Recursive) {
    Write-Host "This script removes all metadata from PNG files in a specified directory and all of its subdirectories and adds CC0 copyright tags to each image." -ForegroundColor Cyan
} else {
    Write-Host "This script removes all metadata from PNG files in a specified directory and adds CC0 copyright tags to each image." -ForegroundColor Cyan
}

# Ask for directory choice input
$directory = Read-Host -Prompt "Enter the full path to the directory containing the PNG files"

# Check if the directory exists
if (-not (Test-Path -Path $directory)) {
    Write-Error "The specified directory cannot be accessed." -ForegroundColor Red
    exit 1
}

# Check if exiftool is installed
if (-not (Get-Command "exiftool" -ErrorAction SilentlyContinue)) {
    Write-Error "ExifTool is not installed. Please install it from https://exiftool.org/install.html" -ForegroundColor Red
    exit 1
}

# Get PNG files based on recursive flag
if ($Recursive) {
    $pngFiles = Get-ChildItem -Path $directory -Filter *.png -File -Recurse
    $scopeDescription = "in the specified directory and its subdirectories"
    $cautionText = "CAUTION: This will permanently remove all existing exif metadata from all PNGs in this folder AND ALL OF ITS SUBDIRECTORIES. Proceed? (y/n)"
} else {
    $pngFiles = Get-ChildItem -Path $directory -Filter *.png -File
    $scopeDescription = "in the specified directory"
    $cautionText = "CAUTION: This will permanently remove all existing exif metadata from all PNGs in this folder. Proceed? (y/n)"
}

# Exit if no PNG files are found
if ($pngFiles.Count -eq 0) {
    Write-Host "No PNG files found $scopeDescription." -ForegroundColor Yellow
    exit 0
}

# Display file count and prompt for confirmation
Write-Host "Found $($pngFiles.Count) PNG file(s) $scopeDescription." -ForegroundColor White
$overwrite = Read-Host -Prompt $cautionText
if ($overwrite -ne 'y') {
    Write-Host "Operation canceled." -ForegroundColor Yellow
    exit 0
}

# Remove all metadata and add the copyright tags to each PNG file
foreach ($file in $pngFiles) {
    # Print the name of the file being processed
    Write-Host "Processing file: $($file.FullName)" -ForegroundColor DarkGreen

    # Remove any/all existing exif data; Add IFD0:Copyright; Add PNG:Copyright
    exiftool -overwrite_original -all= -IFD0:Copyright="CC0 Public Domain Dedication http://creativecommons.org/publicdomain/zero/1.0/" -PNG:Copyright="CC0 Public Domain Dedication http://creativecommons.org/publicdomain/zero/1.0/" $file.FullName
}

# Provide summary information
Write-Host "Exif data updated for all PNG files $scopeDescription." -ForegroundColor DarkBlue
Write-Host "Total files processed: $($pngFiles.Count)" -ForegroundColor Cyan

# Prevent the PowerShell window from closing automatically
Read-Host -Prompt "Press <Enter> to exit"
