# Name: SLI Guardian
# Version: 1.0
# Description: This script applies an overlay to images, designed for use with pedestrian-perspective street-level imagery from a GoPro Max
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-08-20
# License: CC-BY-ND 4.0 International
#
# This script is designed to be run in a PowerShell environment.
# Prerequisites: ImageMagick and ExifTool must be installed and in PATH
#
# Usage:
#   .\sli-guardian.ps1 -inputDir <input_directory> -outputDir <output_directory> -logo <logo_file>
#
# Examples:
#   .\sli-guardian.ps1
#   .\sli-guardian.ps1 -inputDir ".\input" -outputDir ".\output" -logo ".\logo.png"
#   .\sli-guardian.ps1 -inputDir "C:\TCAT GoPro\ingest\2025-07-25\100GOPRO" -outputDir "C:\TCAT GoPro\export\2025-07-25\100GOPRO" -logo "C:\TCAT GoPro\logo.png"

param(
    [Parameter(Mandatory = $true)]
    [string]$inputDir,
    
    [Parameter(Mandatory = $true)]
    [string]$outputDir,
    
    [Parameter(Mandatory = $true)]
    [string]$logo
)

# Initialize counter for processed images
$processedCounter = 0

# Function to check if a file is an image
function Test-ImageFile {
    param([string]$Path)
    $imageExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif')
    $extension = [System.IO.Path]::GetExtension($Path).ToLower()
    return $imageExtensions -contains $extension
}

# Step 1: Check if input directory exists
Write-Host "Checking input directory..." -ForegroundColor Yellow
if (-not (Test-Path -Path $inputDir -PathType Container)) {
    Write-Host "ERROR: Input directory '$inputDir' does not exist." -ForegroundColor Red
    exit 1
}
Write-Host "Input directory verified: $inputDir" -ForegroundColor Green

# Step 2: Check if output directory exists and handle accordingly
Write-Host "Checking output directory..." -ForegroundColor Yellow
if (Test-Path -Path $outputDir -PathType Container) {
    # Output directory exists - check for existing images
    $existingImages = Get-ChildItem -Path $outputDir -File | Where-Object { Test-ImageFile $_.FullName }
    
    if ($existingImages.Count -gt 0) {
        Write-Host "ERROR: Output directory '$outputDir' already contains $($existingImages.Count) image(s)." -ForegroundColor Red
        Write-Host "Please specify an empty directory or a non-existent directory." -ForegroundColor Red
        exit 1
    }
    Write-Host "Output directory exists and is empty of images." -ForegroundColor Green
}
else {
    # Create output directory if it doesn't exist
    try {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        Write-Host "Output directory created: $outputDir" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Failed to create output directory '$outputDir'. Error: $_" -ForegroundColor Red
        exit 1
    }
}

# Step 3: Check if logo file exists and is PNG format
Write-Host "Checking logo file..." -ForegroundColor Yellow
if (-not (Test-Path -Path $logo -PathType Leaf)) {
    Write-Host "ERROR: Logo file '$logo' does not exist." -ForegroundColor Red
    exit 1
}

# Check if logo is a PNG file
if ([System.IO.Path]::GetExtension($logo).ToLower() -ne '.png') {
    Write-Host "ERROR: Logo file must be in PNG format. Provided file: '$logo'" -ForegroundColor Red
    exit 1
}
Write-Host "Logo file verified: $logo" -ForegroundColor Green

# Step 4: Check for required tools
Write-Host "`nChecking for required tools..." -ForegroundColor Yellow

# Check for ImageMagick
try {
    $null = Get-Command magick -ErrorAction Stop
    Write-Host "ImageMagick found." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: ImageMagick is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Please install ImageMagick: winget install ImageMagick.Q16-HDRI" -ForegroundColor Yellow
    exit 1
}

# Check for ExifTool
try {
    $null = Get-Command exiftool -ErrorAction Stop
    Write-Host "ExifTool found." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: ExifTool is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Please install ExifTool from: https://exiftool.org/" -ForegroundColor Yellow
    exit 1
}

# Step 5: Get all images from input directory
Write-Host "`nScanning for images in input directory..." -ForegroundColor Yellow
$inputImages = Get-ChildItem -Path $inputDir -File | Where-Object { Test-ImageFile $_.FullName }

if ($inputImages.Count -eq 0) {
    Write-Host "WARNING: No image files found in input directory." -ForegroundColor Yellow
    Write-Host "Supported formats: .jpg, .jpeg, .png, .gif, .bmp, .tiff, .tif" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($inputImages.Count) image(s) to process." -ForegroundColor Green

# Step 6: Copy all images to output directory
Write-Host "`nCopying images to output directory..." -ForegroundColor Yellow
foreach ($image in $inputImages) {
    try {
        Copy-Item -Path $image.FullName -Destination $outputDir -Force
        Write-Host "  Copied: $($image.Name)" -ForegroundColor Gray
    }
    catch {
        Write-Host "  ERROR copying $($image.Name): $_" -ForegroundColor Red
        continue
    }
}

# Step 7: Process each image in output directory
Write-Host "`nProcessing images with logo overlay..." -ForegroundColor Yellow
$outputImages = Get-ChildItem -Path $outputDir -File | Where-Object { Test-ImageFile $_.FullName }

foreach ($image in $outputImages) {
    Write-Host "`nProcessing: $($image.Name)" -ForegroundColor Cyan
    
    try {
        $imagePath = $image.FullName
        $imageBaseName = [System.IO.Path]::GetFileNameWithoutExtension($image.Name)
        $originalExtension = [System.IO.Path]::GetExtension($image.Name)
        
        # Find corresponding original image
        $originalImage = Join-Path -Path $inputDir -ChildPath $image.Name
        
        # Temporary PNG file for processing
        $tempPng = Join-Path -Path $outputDir -ChildPath "$imageBaseName-temp.png"
        $tempOverlay = Join-Path -Path $outputDir -ChildPath "$imageBaseName-overlay.png"
        
        # Step 7a: Convert to PNG if not already
        Write-Host "  Converting to PNG for processing..." -ForegroundColor Gray
        if ($originalExtension.ToLower() -eq '.png') {
            # Already PNG, just work with it directly
            $tempPng = $imagePath
        }
        else {
            # Convert without format specifications
            Write-Host "  Converting: $imagePath to $tempPng"
            $convertOutput = & magick "$imagePath" "$tempPng" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to convert to PNG: $convertOutput"
            }
            
            # Verify the PNG was created
            if (-not (Test-Path -Path $tempPng)) {
                throw "PNG conversion failed - output file was not created"
            }
        }
        
        # Step 7b: Check dimensions and apply logo overlay
        # Get dimensions of both images
        $imageSize = & magick identify -format "%wx%h" "$tempPng" 2>&1
        $logoSize = & magick identify -format "%wx%h" "$logo" 2>&1

        if ($imageSize -ne $logoSize) {
            throw "Logo dimensions ($logoSize) do not match image dimensions ($imageSize). The logo must be exactly the same size as the target image."
        }

        Write-Host "  Applying logo overlay..." -ForegroundColor Gray
        # Composite logo directly over image with no positioning adjustments
        & magick composite "$logo" "$tempPng" "$tempOverlay" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to apply logo overlay"
        }
        
        # Step 7c: Convert back to original format if it was JPG
        if ($originalExtension.ToLower() -in @('.jpg', '.jpeg')) {
            Write-Host "  Converting back to JPEG..." -ForegroundColor Gray
            $finalOutput = Join-Path -Path $outputDir -ChildPath "$imageBaseName.jpg"
            Write-Host "  Converting: $tempOverlay to $finalOutput"
            $convertOutput = & magick "$tempOverlay" "$finalOutput" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to convert back to JPEG: $convertOutput"
            }
            
            # Remove temporary files
            if ($tempOverlay -ne $finalOutput) {
                Remove-Item -Path $tempOverlay -Force -ErrorAction SilentlyContinue
            }
            if (($tempPng -ne $imagePath) -and (Test-Path $tempPng)) {
                Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
            }
            if ($imagePath -ne $finalOutput) {
                Remove-Item -Path $imagePath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            # For PNG and other formats, use the overlay as final
            $finalOutput = $imagePath
            if ($tempOverlay -ne $finalOutput) {
                Move-Item -Path $tempOverlay -Destination $finalOutput -Force
            }
            if (($tempPng -ne $imagePath) -and (Test-Path $tempPng)) {
                Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
            }
        }
        
        # Step 7d: Copy EXIF data from original to processed image
        Write-Host "  Copying EXIF data from original..." -ForegroundColor Gray
        & exiftool -overwrite_original -TagsFromFile "$originalImage" "-all:all>all:all" "$finalOutput" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: Failed to copy some EXIF data, but image was processed" -ForegroundColor Yellow
        }
        
        # Increment success counter
        $processedCounter++
        Write-Host "  Successfully processed: $($image.Name)" -ForegroundColor Green
        
    }
    catch {
        Write-Host "  ERROR processing $($image.Name): $_" -ForegroundColor Red
        
        # Clean up temporary files on error
        if ((Test-Path $tempPng -ErrorAction SilentlyContinue) -and ($tempPng -ne $imagePath)) {
            Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $tempOverlay -ErrorAction SilentlyContinue) {
            Remove-Item -Path $tempOverlay -Force -ErrorAction SilentlyContinue
        }
        continue
    }
}

# Step 8: Output summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "PROCESSING COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Input Directory:  $inputDir" -ForegroundColor White
Write-Host "Output Directory: $outputDir" -ForegroundColor White
Write-Host "Logo File:        $logo" -ForegroundColor White
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host "Total images found:      $($inputImages.Count)" -ForegroundColor White
Write-Host "Successfully processed:  $processedCounter" -ForegroundColor Green
if (($inputImages.Count - $processedCounter) -gt 0) {
    Write-Host "Failed to process:       $($inputImages.Count - $processedCounter)" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Cyan

# Exit with appropriate code
if ($processedCounter -eq 0) {
    exit 1
}
elseif ($processedCounter -lt $inputImages.Count) {
    exit 2  # Partial success
}
else {
    exit 0  # Complete success
}
