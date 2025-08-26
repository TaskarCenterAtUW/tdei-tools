# Name: SLI Guardian
# Version: 2.0
# Description: This script applies an overlay to images, designed for use with pedestrian-perspective street-level imagery from a GoPro Max
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-08-26
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
#   .\sli-guardian.ps1 -inputDir ".\input" -outputDir ".\output" -logo ".\logo.png" -maxParallel 3 -batchSize 100
#   .\sli-guardian.ps1 -inputDir "C:\TCAT GoPro\ingest\2025-07-25\101\1" -outputDir "C:\TCAT GoPro\export\2025-07-25\101\1" -logo "C:\TCAT GoPro\overlay\tcat-block-purple.png" -maxParallel 3 -batchSize 100

param(
    [Parameter(Mandatory = $true)]
    [string]$inputDir,
    
    [Parameter(Mandatory = $true)]
    [string]$outputDir,
    
    [Parameter(Mandatory = $true)]
    [string]$logo,
    
    [Parameter(Mandatory = $false)]
    [int]$maxParallel = [Math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS - 1),
    
    [Parameter(Mandatory = $false)]
    [int]$batchSize = 100,
    
    [Parameter(Mandatory = $false)]
    [switch]$skipExif
)

# Function to check if a file is an image
function Test-ImageFile {
    param([string]$Path)
    $imageExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif')
    $extension = [System.IO.Path]::GetExtension($Path).ToLower()
    return $imageExtensions -contains $extension
}

# Batch copy function
function Copy-ImagesOptimized {
    param(
        [string]$Source,
        [string]$Destination,
        [array]$InputImages
    )
    
    Write-Host "Copying..." -ForegroundColor Yellow
    
    # Use robocopy with multiple threads for copying
    $robocopyArgs = @(
        $Source
        $Destination
        "*.jpg", "*.jpeg", "*.png", "*.gif", "*.bmp", "*.tiff", "*.tif"
        "/MT:8"      # Multi-threaded (8 threads)
        "/R:1"       # Retry once on failure
        "/W:1"       # Wait 1 second between retries
        "/NDL"       # No directory listing
        "/NP"        # No progress indicator
    )
    
    try {
        $result = & robocopy @robocopyArgs 2>&1
        # Robocopy returns 0-7 for various success states, >8 for errors
        if ($LASTEXITCODE -gt 8) {
            throw "Robocopy failed with exit code: $LASTEXITCODE"
        }
        return $true
    }
    catch {
        Write-Host "Robocopy failed, falling back to PowerShell copy..." -ForegroundColor Yellow
        return $false
    }
}

Write-Host "SLI Guardian v2.0" -ForegroundColor Cyan
Write-Host "Max Parallel Jobs: $maxParallel | Batch Size: $batchSize" -ForegroundColor Cyan

# Step 1: Validation
Write-Host "`nValidating inputs..." -ForegroundColor Yellow

$validationErrors = @()

if (-not (Test-Path -Path $inputDir -PathType Container)) {
    $validationErrors += "Input directory '$inputDir' does not exist."
}

if (-not (Test-Path -Path $logo -PathType Leaf)) {
    $validationErrors += "Logo file '$logo' does not exist."
}
elseif ([System.IO.Path]::GetExtension($logo).ToLower() -ne '.png') {
    $validationErrors += "Logo file must be in PNG format."
}

# Check tools availability
try { $null = Get-Command magick -ErrorAction Stop }
catch { $validationErrors += "ImageMagick is not installed or not in PATH." }

if (-not $skipExif) {
    try { $null = Get-Command exiftool -ErrorAction Stop }
    catch { $validationErrors += "ExifTool is not installed or not in PATH. Use -skipExif to bypass." }
}

if ($validationErrors.Count -gt 0) {
    Write-Host "VALIDATION ERRORS:" -ForegroundColor Red
    $validationErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

# Create output directory if needed
if (-not (Test-Path -Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}
else {
    # Check for existing images
    $existingCount = (Get-ChildItem -Path $outputDir -File -Include "*.jpg", "*.jpeg", "*.png", "*.gif", "*.bmp", "*.tiff", "*.tif" | Measure-Object).Count
    if ($existingCount -gt 0) {
        Write-Host "ERROR: Output directory contains $existingCount existing image(s)." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Validation complete." -ForegroundColor Green

# Step 2: Get image inventory
Write-Host "`nScanning for images..." -ForegroundColor Yellow
$inputImages = Get-ChildItem -Path $inputDir -File | Where-Object { Test-ImageFile $_.FullName }

if ($inputImages.Count -eq 0) {
    Write-Host "No images found in input directory." -ForegroundColor Yellow
    Write-Host "Supported formats: .jpg, .jpeg, .png, .gif, .bmp, .tiff, .tif" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($inputImages.Count) images to process." -ForegroundColor Green

# Step 3: Copying
Write-Host "`nCopying images to output directory..." -ForegroundColor Yellow

# Try robocopy first for better performance on large file sets
$copySuccess = Copy-ImagesOptimized -Source $inputDir -Destination $outputDir -InputImages $inputImages

if (-not $copySuccess) {
    # Fallback to PowerShell copy with progress tracking
    $counter = 0
    foreach ($image in $inputImages) {
        Copy-Item -Path $image.FullName -Destination $outputDir -Force
        $counter++
        if ($counter % 100 -eq 0) {
            Write-Host "  Copied: $counter / $($inputImages.Count)" -ForegroundColor Gray
        }
    }
}

Write-Host "File copying complete." -ForegroundColor Green

# Step 4: Pre-validate logo dimensions against first image
Write-Host "`nValidating logo compatibility..." -ForegroundColor Yellow
$firstImage = Get-ChildItem -Path $outputDir -File | Where-Object { Test-ImageFile $_.FullName } | Select-Object -First 1
if ($firstImage) {
    $imageSize = & magick identify -format "%wx%h" $firstImage.FullName 2>&1
    $logoSize = & magick identify -format "%wx%h" $logo 2>&1
    
    if ($imageSize -ne $logoSize) {
        Write-Host "ERROR: Logo dimensions ($logoSize) don't match image dimensions ($imageSize)" -ForegroundColor Red
        exit 1
    }
    Write-Host "Logo dimensions validated: $logoSize" -ForegroundColor Green
}

# Step 5: Process images in batches
Write-Host "`nProcessing $($inputImages.Count) images with logo overlay..." -ForegroundColor Yellow
Write-Host "Parallel jobs: $maxParallel | Batch size: $batchSize" -ForegroundColor Yellow

$outputImages = Get-ChildItem -Path $outputDir -File | Where-Object { Test-ImageFile $_.FullName }
$totalProcessed = 0
$totalFailed = 0
$startTime = Get-Date

# Process in batches to manage memory and provide progress updates
for ($i = 0; $i -lt $outputImages.Count; $i += $batchSize) {
    $batch = $outputImages[$i..[Math]::Min($i + $batchSize - 1, $outputImages.Count - 1)]
    $batchNum = [Math]::Floor($i / $batchSize) + 1
    $totalBatches = [Math]::Ceiling($outputImages.Count / $batchSize)
    
    Write-Host "`nProcessing batch $batchNum of $totalBatches ($($batch.Count) images)..." -ForegroundColor Cyan
    
    # Process current batch in parallel
    $results = $batch | ForEach-Object -ThrottleLimit $maxParallel -Parallel {
        $image = $_
        $inputDir = $using:inputDir
        $outputDir = $using:outputDir
        $logo = $using:logo
        $skipExif = $using:skipExif
        
        try {
            $imagePath = $image.FullName
            $imageBaseName = [System.IO.Path]::GetFileNameWithoutExtension($image.Name)
            $originalExtension = [System.IO.Path]::GetExtension($image.Name)
            $originalImage = Join-Path -Path $inputDir -ChildPath $image.Name
            
            if ($originalExtension.ToLower() -in @('.jpg', '.jpeg')) {
                # For JPEG: PNG temp -> overlay -> final JPEG
                $tempPng = Join-Path -Path $outputDir -ChildPath "$imageBaseName-temp.png"
                $finalOutput = Join-Path -Path $outputDir -ChildPath "$imageBaseName.jpg"
                
                # Convert to PNG
                $null = & magick "$imagePath" "$tempPng" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "PNG conversion failed" }
                
                # Apply overlay directly to temp file
                $null = & magick composite "$logo" "$tempPng" "$tempPng" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Overlay application failed" }
                
                # Convert back to JPEG
                $null = & magick "$tempPng" "$finalOutput" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "JPEG conversion failed" }
                
                # Cleanup temporary files only
                Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
                # Only remove original copied file if it's different from final output
                if ($imagePath -ne $finalOutput) {
                    Remove-Item -Path $imagePath -Force -ErrorAction SilentlyContinue
                }
                
                $processedFile = $finalOutput
            }
            else {
                # For PNG and others: direct overlay (in-place modification)
                $null = & magick composite "$logo" "$imagePath" "$imagePath" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Overlay application failed" }
                
                $processedFile = $imagePath
            }
            
            # Copy EXIF data if not skipped
            if (-not $skipExif) {
                $null = & exiftool -overwrite_original -TagsFromFile "$originalImage" "-all:all>all:all" "$processedFile" 2>&1
                # Don't fail on EXIF errors, just continue
            }
            
            return @{Success = $true; File = $image.Name }
        }
        catch {
            # Cleanup on error
            $tempFiles = @(
                (Join-Path -Path $outputDir -ChildPath "$imageBaseName-temp.png"),
                (Join-Path -Path $outputDir -ChildPath "$imageBaseName-overlay.png")
            )
            $tempFiles | ForEach-Object { 
                if (Test-Path $_) { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
            }
            
            return @{Success = $false; File = $image.Name; Error = $_.Exception.Message }
        }
    }
    
    # Process results
    $batchSuccess = ($results | Where-Object { $_.Success }).Count
    $batchFailed = ($results | Where-Object { -not $_.Success }).Count
    
    $totalProcessed += $batchSuccess
    $totalFailed += $batchFailed
    
    # Show batch progress
    $elapsed = ((Get-Date) - $startTime).TotalMinutes
    $rate = if ($elapsed -gt 0) { [Math]::Round(($totalProcessed + $totalFailed) / $elapsed, 1) } else { 0 }
    
    Write-Host "Batch $batchNum complete: $batchSuccess succeeded, $batchFailed failed" -ForegroundColor $(if ($batchFailed -eq 0) { "Green" } else { "Yellow" })
    Write-Host "Overall progress: $($totalProcessed + $totalFailed) / $($outputImages.Count) | Rate: $rate images/min" -ForegroundColor Gray
    
    # Show any errors from this batch
    $errors = $results | Where-Object { -not $_.Success }
    if ($errors.Count -gt 0 -and $errors.Count -le 5) {
        $errors | ForEach-Object { 
            Write-Host "  ERROR: $($_.File) - $($_.Error)" -ForegroundColor Red 
        }
    }
    elseif ($errors.Count -gt 5) {
        Write-Host "  $($errors.Count) errors in this batch (suppressing details)" -ForegroundColor Red
    }
}

# Final summary
$totalTime = ((Get-Date) - $startTime).TotalMinutes
$overallRate = if ($totalTime -gt 0) { [Math]::Round($inputImages.Count / $totalTime, 1) } else { 0 }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "PROCESSING COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Input Directory:        $inputDir" -ForegroundColor White
Write-Host "Output Directory:       $outputDir" -ForegroundColor White
Write-Host "Logo File:              $logo" -ForegroundColor White
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host "Total images found:     $($inputImages.Count)" -ForegroundColor White
Write-Host "Successfully processed: $totalProcessed" -ForegroundColor Green
Write-Host "Failed to process:      $totalFailed" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Red" })
Write-Host "Processing time:        $([Math]::Round($totalTime, 1)) minutes" -ForegroundColor White
Write-Host "Processing rate:        $overallRate images/minute" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

# Exit codes
if ($totalProcessed -eq 0) { exit 1 }
elseif ($totalFailed -gt 0) { exit 2 }
else { exit 0 }
