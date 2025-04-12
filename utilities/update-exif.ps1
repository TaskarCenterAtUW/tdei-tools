# Name: GoInfoGame Images Exif Data Update Script
# Version: 1.0
# Description: This script removes all metadata from PNG files in a specified directory and adds CC0 copyright tags to each image.
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-04-11
# License: CC-BY-ND 4.0 International

# This script is designed to be run in a PowerShell environment.

Write-Host "GoInfoGame Images Exif Data Update Script" -ForegroundColor Blue
Write-Host "This script removes all metadata from PNG files in a specified directory and adds CC0 copyright tags to each image." -ForegroundColor Cyan

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

# Get all PNG files in the specified directory
$pngFiles = Get-ChildItem -Path $directory -Filter *.png -File

# Exit if no PNG files are found
if ($pngFiles.Count -eq 0) {
    Write-Host "No PNG files found in the specified directory." -ForegroundColor Yellow
    exit 0
}

# Prompt for overwrite confirmation
$overwrite = Read-Host -Prompt "CAUTION: This will permanently remove all existing exif metadata from all PNGs in this folder. Proceed? (y/n)"
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
Write-Host "Exif data updated for all PNG files in the directory." -ForegroundColor DarkBlue
Write-Host "Total files processed: $($pngFiles.Count)" -ForegroundColor Cyan

# Prevent the PowerShell window from closing automatically
Read-Host -Prompt "Press <Enter> to exit"
