# Name: GTFS-to-TDEI Converter Script
# Version: 3.0.0
# Description: This script takes a GTFS archive, processes it to convert stops.txt to stops.geojson, and zips the result into an archive ready for upload to TDEI.
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-09-09
# License: CC-BY-ND 4.0 International

<#
.SYNOPSIS
    Converts GTFS stops.txt to TDEI-compatible GeoJSON format.

.DESCRIPTION
    This script takes a GTFS archive, extracts the stops.txt file, converts it to 
    OpenSidewalks-compatible GeoJSON format, and packages it as a ZIP file ready 
    for upload to the TDEI (Transportation Data Exchange Initiative).

    The script validates the input GTFS data, ensures required fields are present,
    and validates coordinate values before conversion.

.PARAMETER InputZip
    Path to the GTFS ZIP archive containing stops.txt file.
    This parameter is mandatory.

.PARAMETER OutputDir
    Directory where the output stops.zip file will be created.
    If not specified, uses the current working directory.
    The directory will be created if it doesn't exist.

.EXAMPLE
    .\gtfs-to-tdei-converter.ps1 -InputZip "C:\data\gtfs.zip"
    
    Converts the GTFS archive and saves stops.zip in the current directory.

.EXAMPLE
    .\gtfs-to-tdei-converter.ps1 -InputZip "C:\data\gtfs.zip" -OutputDir "C:\output"
    
    Converts the GTFS archive and saves stops.zip in the specified output directory.

.EXAMPLE
    Get-Help .\gtfs-to-tdei-converter.ps1 -Detailed
    
    Shows detailed help including parameter descriptions and examples.

.NOTES
    Required GTFS fields: stop_id, stop_lat, stop_lon
    Output format: OpenSidewalks 0.2 schema compatible GeoJSON
    
    The script will validate:
    - Input ZIP file exists and contains stops.txt
    - Required GTFS fields are present
    - Latitude and longitude values are valid

.LINK
    https://github.com/TaskarCenterAtUW/tdei-tools
#>

# This script is designed to be run in a PowerShell environment.

param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the GTFS zip archive")]
    [string]$InputZip,
    
    [Parameter(Mandatory = $false, HelpMessage = "Output directory for the converted file")]
    [string]$OutputDir = (Get-Location)
)

# Constants
$OPENSIDEWALKS_SCHEMA_URL = 'https://sidewalks.washington.edu/opensidewalks/0.2/schema.json'
$REQUIRED_GTFS_FIELDS = @('stop_id', 'stop_lat', 'stop_lon')
$OUTPUT_GEOJSON_FILENAME = 'stops.geojson'
$OUTPUT_ZIP_FILENAME = 'stops.zip'
$GTFS_STOPS_FILENAME = 'stops.txt'

Write-Host "GTFS-to-TDEI Converter Script v3.0.0" -ForegroundColor DarkBlue
Write-Host ""

# Check if input ZIP exists
if (-not (Test-Path $InputZip)) {
    Write-Error "Input ZIP file not found: $InputZip"
    exit 1
}

# Validate and create output directory if needed
if (-not (Test-Path $OutputDir)) {
    try {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        Write-Host "Created output directory: $OutputDir" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Could not create output directory: $OutputDir"
        exit 4
    }
}

# Create temp directory
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
$zip = $null

try {
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    # Extract stops.txt from ZIP
    $stopsPath = Join-Path $tempDir $GTFS_STOPS_FILENAME
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($InputZip)
    $stopsEntry = $zip.Entries | Where-Object { $_.Name -eq $GTFS_STOPS_FILENAME }

    if (-not $stopsEntry) {
        throw "$GTFS_STOPS_FILENAME not found in ZIP archive"
    }

    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($stopsEntry, $stopsPath, $true)
    $zip.Dispose()
    $zip = $null

    # Read the CSV file
    $stops = Import-Csv $stopsPath
    
    # Validate required GTFS fields
    if ($stops.Count -eq 0) {
        throw "$GTFS_STOPS_FILENAME is empty or invalid"
    }
    
    $firstStop = $stops[0]
    $missingFields = $REQUIRED_GTFS_FIELDS | Where-Object { -not $firstStop.PSObject.Properties.Name.Contains($_) }
    
    if ($missingFields.Count -gt 0) {
        throw "Missing required GTFS fields in ${GTFS_STOPS_FILENAME}: $($missingFields -join ', ')"
    }
}
catch {
    Write-Error "Error processing ZIP file: $($_.Exception.Message)"
    if ($zip) { $zip.Dispose() }
    if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
    exit 2
}

# Create GeoJSON structure
$geojson = @{
    '$schema'       = $OPENSIDEWALKS_SCHEMA_URL
    'type'          = 'FeatureCollection'
    'features'      = @()
    'dataTimestamp' = (Get-Date).ToString('o')  # ISO 8601 timestamp
    'dataSource'    = @{
        'name'      = "GTFS $GTFS_STOPS_FILENAME from " + [System.IO.Path]::GetFileName($InputZip)
        'timestamp' = (Get-Item $InputZip).LastWriteTime.ToString('o')
    }
}

# Initialize counter for generating numeric IDs
$idCounter = 1

# Initialize output file paths
$geojsonPath = Join-Path $OutputDir $OUTPUT_GEOJSON_FILENAME
$zipPath = Join-Path $OutputDir $OUTPUT_ZIP_FILENAME

# Process each stop
try {
    foreach ($stop in $stops) {
        # Validate coordinates
        $lat = 0.0
        $lon = 0.0
        
        if (-not [double]::TryParse($stop.stop_lat, [ref]$lat) -or $lat -lt -90 -or $lat -gt 90) {
            throw "Invalid latitude for stop $($stop.stop_id): $($stop.stop_lat). Must be between -90 and 90."
        }
        
        if (-not [double]::TryParse($stop.stop_lon, [ref]$lon) -or $lon -lt -180 -or $lon -gt 180) {
            throw "Invalid longitude for stop $($stop.stop_id): $($stop.stop_lon). Must be between -180 and 180."
        }
        
        # Create feature object following OpenSidewalks schema for CustomPoint
        $feature = @{
            type       = 'Feature'
            geometry   = @{
                type        = 'Point'
                coordinates = @($lon, $lat)
            }
            properties = @{
                # Add required _id field using sequential counter
                '_id' = $idCounter++
            }
        }

        # Add all GTFS properties with ext: prefix
        $stop.PSObject.Properties | ForEach-Object {
            $feature.properties["ext:$($_.Name)"] = $_.Value
        }

        # Add feature to collection
        $geojson.features += $feature
    }

    # Convert to JSON and save
    $geojson | ConvertTo-Json -Depth 10 | Set-Content $geojsonPath

    # Create ZIP archive
    if (Test-Path $zipPath) {
        Remove-Item $zipPath
    }
    Compress-Archive -Path $geojsonPath -DestinationPath $zipPath
    Remove-Item $geojsonPath  # Clean up the temporary GeoJSON file

}
catch {
    Write-Error "Error processing stops or creating output: $($_.Exception.Message)"
    # Clean up any partial files
    if (Test-Path $geojsonPath) { Remove-Item $geojsonPath -ErrorAction SilentlyContinue }
    if (Test-Path $zipPath) { Remove-Item $zipPath -ErrorAction SilentlyContinue }
    exit 3
}
finally {
    # Always clean up temp directory
    if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
}

Write-Host "Success! Created $zipPath - ready for upload to TDEI."  -ForegroundColor Blue

# Prevent the PowerShell window from closing automatically
Read-Host -Prompt "Press <Enter> to exit"
