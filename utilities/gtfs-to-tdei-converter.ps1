# Name: GTFS-to-TDEI Converter Script
# Version: 1.1
# Description: This script takes a GTFS archive, processes it to convert stops.txt to stops.geojson, and zips the result into an archive ready for upload to TDEI.
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-08-05
# License: CC-BY-ND 4.0 International

# This script is designed to be run in a PowerShell environment.

# Ask for and validate inputs
Write-Host "GTFS-to-TDEI Converter Script v1.0" -ForegroundColor DarkBlue
Write-Host ""
Write-Host "Enter the path to the GTFS zip archive:" -ForegroundColor Green
$InputZip = Read-Host

# Check if input ZIP exists
if (-not (Test-Path $InputZip)) {
    Write-Error "Input ZIP file not found: $InputZip"
    exit 1
}

# Create temp directory
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir | Out-Null

# Extract stops.txt from ZIP
$stopsPath = Join-Path $tempDir "stops.txt"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($InputZip)
$stopsEntry = $zip.Entries | Where-Object { $_.Name -eq "stops.txt" }

if (-not $stopsEntry) {
    Write-Error "stops.txt not found in ZIP archive"
    $zip.Dispose()
    Remove-Item -Path $tempDir -Recurse -Force
    exit 1
}

[System.IO.Compression.ZipFileExtensions]::ExtractToFile($stopsEntry, $stopsPath, $true)
$zip.Dispose()

# Read the CSV file
$stops = Import-Csv $stopsPath

# Create GeoJSON structure
$geojson = @{
    '$schema'       = 'https://sidewalks.washington.edu/opensidewalks/0.2/schema.json'
    'type'          = 'FeatureCollection'
    'features'      = @()
    'dataTimestamp' = (Get-Date).ToString('o')  # ISO 8601 timestamp
    'dataSource'    = @{
        'name'      = 'GTFS stops.txt from ' + [System.IO.Path]::GetFileName($InputZip)
        'timestamp' = (Get-Item $InputZip).LastWriteTime.ToString('o')
    }
}

# Initialize counter for generating numeric IDs
$idCounter = 1

# Process each stop
foreach ($stop in $stops) {
    # Get all properties and prefix them with 'ext:'
    $properties = @{}
    $stop.PSObject.Properties | ForEach-Object {
        $properties["ext:$($_.Name)"] = $_.Value
    }

    # Create feature object following OpenSidewalks schema for CustomPoint
    $feature = @{
        type       = 'Feature'
        geometry   = @{
            type        = 'Point'
            coordinates = @(
                [double]$stop.stop_lon,
                [double]$stop.stop_lat
            )
        }
        properties = @{
            # Add required _id field using sequential counter
            '_id'         = $idCounter++
            # Store original stop_id as ext:stop_id
            'ext:stop_id' = $stop.stop_id
            # Add all GTFS properties with ext: prefix
        }
    }

    # Add the ext: prefixed properties
    $stop.PSObject.Properties | ForEach-Object {
        $feature.properties["ext:$($_.Name)"] = $_.Value
    }

    # Add feature to collection
    $geojson.features += $feature
}

# Convert to JSON and save
$geojsonPath = "stops.geojson"
$zipPath = "stops.zip"
$geojson | ConvertTo-Json -Depth 10 | Set-Content $geojsonPath

# Create ZIP archive
if (Test-Path $zipPath) {
    Remove-Item $zipPath
}
Compress-Archive -Path $geojsonPath -DestinationPath $zipPath
Remove-Item $geojsonPath  # Clean up the temporary GeoJSON file

# Clean up temp directory
Remove-Item -Path $tempDir -Recurse -Force

Write-Host "Success! Created stops.zip - ready for upload to TDEI."  -ForegroundColor Blue

# Prevent the PowerShell window from closing automatically
Read-Host -Prompt "Press <Enter> to exit"
