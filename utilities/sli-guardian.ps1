#!/usr/bin/env pwsh
# This script is designed to be run in a PowerShell environment.

# Name: SLI Guardian
# Version: 6.0.1
# Date: 2025-10-16
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# License: CC-BY-ND 4.0 International

<#
.SYNOPSIS
	Applies overlay images to street-level imagery

.DESCRIPTION
	This script applies an overlay to images, designed for use with pedestrian-perspective 
	street-level imagery from devices like GoPro Max cameras. It processes images in 
	parallel batches for optimal performance, copying input images to an output directory, 
	applying the specified overlay, and preserving EXIF metadata from the original files.
	
	The script supports various image formats and includes validation for overlay 
	compatibility, progress reporting, and comprehensive error handling.

.PARAMETER InputDir
	Path to the directory containing input images to process

.PARAMETER OutputDir
	Path to the directory where processed images will be saved

.PARAMETER Overlay
	Path to the PNG overlay file to apply to all images

.PARAMETER MaxParallel
	Maximum number of parallel processing jobs

.PARAMETER BatchSize
	Number of images to process in each batch
	Default: 50

.PARAMETER JpegQuality
	JPEG compression quality (1-100) for JPEG output files
	Default: 70

.PARAMETER SkipExif
	Skip copying EXIF metadata from original files

.EXAMPLE
	.\sli-guardian.ps1 -inputDir ".\input" -outputDir ".\output" -overlay ".\overlay.png"
	
	Processes images from .\input directory using default settings

.EXAMPLE
	.\sli-guardian.ps1 -inputDir "C:\TCAT GoPro\ingest\2025-07-25\101\1" -outputDir "C:\TCAT GoPro\export\2025-07-25\101\1" -overlay "C:\TCAT GoPro\overlay\tcat-purple.png" -jpegQuality 85
	
	Processes images with custom parallel processing and quality settings

.NOTES
	Prerequisites:
	- ImageMagick must be installed and available in PATH
	- ExifTool must be installed and available in PATH (unless -skipExif is used)
	
	Supported image formats:
	- Input: .jpg, .jpeg, .png, .gif, .bmp, .tiff, .tif
	- Overlay: .png only
	
	The script performs these operations:
	1. Validates all inputs and prerequisites
	2. Copies input images to output directory
	3. Validates overlay dimensions match image dimensions
	4. Applies overlay to images in parallel batches
	5. Preserves EXIF metadata from original files (unless -skipExif)
	6. Provides detailed progress reporting and error handling
	
	JPEG handling:
	- JPEG files are processed with quality settings
	- Extensions are normalized to lowercase .jpg
	- Non-JPEG files are processed without quality settings
	
	Exit codes:
	- 0: All images processed successfully
	- 1: No images processed (validation errors or no input images)
	- 2: Some images failed processing (partial success)

.LINK
	https://github.com/TaskarCenterAtUW/tdei-tools
#>

param(
	[Parameter(Mandatory = $true)]
	[string]$inputDir,
	
	[Parameter(Mandatory = $true)]
	[string]$outputDir,
	
	[Parameter(Mandatory = $true)]
	[string]$overlay,
	
	[Parameter(Mandatory = $false)]
	[int]$maxParallel = [Math]::Min(16, [Math]::Max(4, [int]$env:NUMBER_OF_PROCESSORS)),
	
	[Parameter(Mandatory = $false)]
	[int]$batchSize = 50,
	
	[Parameter(Mandatory = $false)]
	[ValidateRange(1, 100)]
	[int]$jpegQuality = 90,
	
	[Parameter(Mandatory = $false)]
	[switch]$skipExif
)

# Pre-defined image extensions for filtering
$script:ImageExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif')
$script:JpegExtensions = @('.jpg', '.jpeg')

Write-Host "SLI Guardian v6.0.0" -ForegroundColor Cyan
Write-Host "Max Parallel Jobs: $maxParallel | Batch Size: $batchSize | JPEG Quality: $jpegQuality" -ForegroundColor Cyan

# Step 1: Validation
Write-Host "`nValidating inputs..." -ForegroundColor Yellow

$validationErrors = @()

if (-not (Test-Path -Path $inputDir -PathType Container)) {
	$validationErrors += "Input directory '$inputDir' does not exist."
}
if (-not (Test-Path -Path $overlay -PathType Leaf)) {
	$validationErrors += "Overlay file '$overlay' does not exist."
}
elseif ([System.IO.Path]::GetExtension($overlay).ToLower() -ne '.png') {
	$validationErrors += "Overlay file must be in PNG format."
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
	# Check for existing images in output directory
	$existingCount = @(Get-ChildItem -Path $outputDir -File | Where-Object { $_.Extension.ToLower() -in $script:ImageExtensions }).Count
	if ($existingCount -gt 0) {
		Write-Host "ERROR: Output directory contains $existingCount existing image(s)." -ForegroundColor Red
		exit 1
	}
}

Write-Host "Validation complete." -ForegroundColor Green

# Step 2: Get image inventory
Write-Host "`nScanning for images..." -ForegroundColor Yellow
$inputImages = @(Get-ChildItem -Path $inputDir -File | Where-Object { $_.Extension.ToLower() -in $script:ImageExtensions })

if ($inputImages.Count -eq 0) {
	Write-Host "No images found in input directory." -ForegroundColor Yellow
	Write-Host "Supported formats: .jpg, .jpeg, .png, .gif, .bmp, .tiff, .tif" -ForegroundColor Yellow
	exit 0
}

Write-Host "Found $($inputImages.Count) images to process." -ForegroundColor Green

# Step 3: Copy input images to output directory
Write-Host "`nCopying images to output directory..." -ForegroundColor Yellow

$counter = 0
# Calculate progress reporting interval
$progressInterval = [Math]::Max(10, [Math]::Min(100, [Math]::Floor($inputImages.Count / 10)))
foreach ($image in $inputImages) {
	Copy-Item -Path $image.FullName -Destination $outputDir -Force
	$counter++
	if ($counter % $progressInterval -eq 0) {
		Write-Host "  Copied: $counter / $($inputImages.Count)" -ForegroundColor Gray
	}
}

Write-Host "File copying complete." -ForegroundColor Green

# Step 4: Get copied images and validate overlay dimensions
Write-Host "`nValidating overlay compatibility..." -ForegroundColor Yellow
$outputImages = @(Get-ChildItem -Path $outputDir -File | Where-Object { $_.Extension.ToLower() -in $script:ImageExtensions })

if ($outputImages.Count -gt 0) {
	# Use first image to validate dimensions
	$firstImage = $outputImages[0]
	$imageSize = & magick identify -format "%wx%h" "$($firstImage.FullName)" 2>&1
	$overlaySize = & magick identify -format "%wx%h" "$overlay" 2>&1
	
	if ($imageSize -ne $overlaySize) {
		Write-Host "ERROR: Overlay dimensions ($overlaySize) do not match image dimensions ($imageSize)" -ForegroundColor Red
		exit 1
	}
	Write-Host "Overlay dimensions validated: $overlaySize" -ForegroundColor Green
}

# Step 5: Process images in batches
Write-Host "`nProcessing $($inputImages.Count) images to add overlay..." -ForegroundColor Yellow
Write-Host "Parallel jobs: $maxParallel | Batch size: $batchSize" -ForegroundColor Yellow
$totalProcessed = 0
$totalFailed = 0
$startTime = Get-Date

# Process images in batches to manage memory and provide progress updates
for ($i = 0; $i -lt $outputImages.Count; $i += $batchSize) {
	# Calculate batch boundaries
	$endIndex = [Math]::Min($i + $batchSize - 1, $outputImages.Count - 1)
	$batch = $outputImages[$i..$endIndex]
	$batchNum = [Math]::Floor($i / $batchSize) + 1
	$totalBatches = [Math]::Ceiling($outputImages.Count / $batchSize)
	
	Write-Host "`nProcessing batch $batchNum of $totalBatches ($($batch.Count) images)..." -ForegroundColor Cyan
	
	# Process current batch in parallel
	$results = $batch | ForEach-Object -ThrottleLimit $maxParallel -Parallel {
		$image = $_
		$inputDir = $using:inputDir
		$outputDir = $using:outputDir
		$overlay = $using:overlay
		$jpegQuality = $using:jpegQuality
		$jpegExtensions = $using:JpegExtensions
		
		try {
			# Set up file paths
			$imagePath = Join-Path -Path $outputDir -ChildPath $image.Name
			$imageBaseName = [System.IO.Path]::GetFileNameWithoutExtension($image.Name)
			$originalExtension = [System.IO.Path]::GetExtension($image.Name)
			$originalImage = Join-Path -Path $inputDir -ChildPath $image.Name
			
			if ($originalExtension.ToLower() -in $jpegExtensions) {
				# For JPEG files: apply overlay with quality setting
				$magickOutput = & magick "$imagePath" "$overlay" -quality $jpegQuality -composite "$imagePath" 2>&1
				if ($LASTEXITCODE -ne 0) { throw "ImageMagick failed: $magickOutput" }
				
				# Normalize extension to lowercase .jpg if needed
				if ($originalExtension -ne '.jpg') {
					$finalOutput = Join-Path -Path $outputDir -ChildPath "$imageBaseName.jpg"
					Move-Item -Path $imagePath -Destination $finalOutput -Force
					$processedFile = $finalOutput
				}
				else {
					$processedFile = $imagePath
				}
			}
			else {
				# For non-JPEG files: apply overlay without quality setting
				$magickOutput = & magick "$imagePath" "$overlay" -composite "$imagePath" 2>&1
				if ($LASTEXITCODE -ne 0) { throw "ImageMagick failed: $magickOutput" }
				
				$processedFile = $imagePath
			}
			
			return @{Success = $true; File = $image.Name; ProcessedFile = $processedFile; OriginalFile = $originalImage }
		}
		catch {
			return @{Success = $false; File = $image.Name; Error = $_.Exception.Message }
		}
	}
	
	# Analyze batch results
	$successfulResults = $results | Where-Object { $_.Success }
	$batchSuccess = $successfulResults.Count
	$batchFailed = ($results | Where-Object { -not $_.Success }).Count
	
	# Copy EXIF data from original files to processed files
	if (-not $skipExif -and $successfulResults.Count -gt 0) {
		try {
			# Create temporary batch file for exiftool
			$batchFile = Join-Path -Path $outputDir -ChildPath "exif_batch_$batchNum.txt"
			
			# Build batch command file
			$batchContent = @()
			foreach ($result in $successfulResults) {
				$batchContent += "-TagsFromFile"
				$batchContent += $result.OriginalFile
				$batchContent += "-all:all>all:all"
				$batchContent += $result.ProcessedFile
			}
			$batchContent -join "`n" | Out-File -FilePath $batchFile -Encoding UTF8
			
			# Execute batch EXIF copy operation
			$null = & exiftool -overwrite_original -@ "$batchFile" 2>&1
			
			# Clean up temporary file
			Remove-Item -Path $batchFile -Force -ErrorAction SilentlyContinue
		}
		catch {
			# Fall back to individual EXIF operations if batch fails
			foreach ($result in $successfulResults) {
				try {
					$null = & exiftool -overwrite_original -TagsFromFile "$($result.OriginalFile)" "-all:all>all:all" "$($result.ProcessedFile)" 2>&1
				}
				catch {
					# Continue processing even if EXIF copy fails
				}
			}
		}
	}
	
	# Update totals
	$totalProcessed += $batchSuccess
	$totalFailed += $batchFailed
	
	# Calculate and display progress
	$elapsed = ((Get-Date) - $startTime).TotalMinutes
	$rate = if ($elapsed -gt 0) { [Math]::Round(($totalProcessed + $totalFailed) / $elapsed, 1) } else { 0 }
	
	Write-Host "Batch $batchNum complete: $batchSuccess succeeded, $batchFailed failed" -ForegroundColor $(if ($batchFailed -eq 0) { "Green" } else { "Yellow" })
	Write-Host "Overall progress: $($totalProcessed + $totalFailed) / $($outputImages.Count) | Rate: $rate images/min" -ForegroundColor Gray
	
	# Display any errors from this batch
	if ($batchFailed -gt 0) {
		$errors = $results | Where-Object { -not $_.Success }
		if ($errors.Count -le 5) {
			$errors | ForEach-Object { 
				Write-Host "  ERROR: $($_.File) - $($_.Error)" -ForegroundColor Red 
			}
		}
		else {
			Write-Host "  $($errors.Count) errors in this batch (suppressing details)" -ForegroundColor Red
		}
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
Write-Host "Overlay File:           $overlay" -ForegroundColor White
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
