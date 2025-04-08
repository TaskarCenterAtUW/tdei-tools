# Name: Workspaces Export Script
# Version: 1.0
# Description: This script directly exports a database using the Workspaces API and saves it to a file.
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-04-07
# License: CC-BY-ND 4.0 International

# This script is designed to be run in a PowerShell environment.

# Ask for and validate inputs
$workspaceEnv = Read-Host -Prompt "Enter the Workspace Environment, in the format 'dev', 'stage', or 'prod'."

if ($workspaceEnv -notin @('dev', 'stage', 'prod')) {
  Write-Host "Invalid Workspace Environment. Please enter 'dev', 'stage', or 'prod'." -ForegroundColor Red
  exit
}

$secureApiKey = Read-Host -Prompt "Enter your Workspaces API key, in the format 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'" -AsSecureString
$workspaceId = Read-Host -Prompt "Enter the Workspace ID, in the format 'n'"

if (-not $workspaceId -or $workspaceId -notmatch '^\d+$') {
  Write-Host "Invalid Workspace ID. Please enter the numeric Workspace ID." -ForegroundColor Red
  exit
}

$outputFileName = Read-Host -Prompt "Enter the name of the output file, in the format 'filename.osm'"

if (-not $outputFileName -or $outputFileName -notmatch '\.osm$') {
  Write-Host "Invalid output file name. Please enter a name ending with '.osm'." -ForegroundColor Red
  exit
}

# Convert the secure string API key to a regular string
$apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiKey)
)

# Set the environment postfix based on the entered Workspace Environment
if ($workspaceEnv -eq 'dev'){
  $envPostfix = '-dev'
}
if ($workspaceEnv -eq 'stage'){
  $envPostfix = '-stage'
}
if ($workspaceEnv -eq 'prod'){
  $envPostfix = ''
}

# Set the headers for the API request
$headers = @{
  Authorization = $apiKey
  'X-Workspace' = $workspaceId
}

# Formulate the BBOX request URL
$bboxUrl = "https://osm.workspaces$envPostfix.sidewalks.washington.edu/api/0.6/workspaces/$workspaceId/bbox.json"

try {
  $response = Invoke-WebRequest -Uri $bboxUrl -ErrorAction Stop
  $bboxData = $response.Content | ConvertFrom-Json
} catch {
  Write-Host "Error fetching BBOX data: $($_.Exception.Message)" -ForegroundColor Red
  exit
}

# Assign values to separate variables
$minLat = $bboxData.min_lat
$minLon = $bboxData.min_lon
$maxLat = $bboxData.max_lat
$maxLon = $bboxData.max_lon

# Formulate the export request URL
$exportUrl = "https://osm.workspaces$envPostfix.sidewalks.washington.edu/api/0.6/map?bbox=$minLon,$minLat,$maxLon,$maxLat"

# Check if the output file already exists
# If it does, prompt the user to overwrite or cancel
if (Test-Path $outputFileName) {
  $overwrite = Read-Host -Prompt "File '$outputFileName' already exists. Overwrite? (y/n)"
  if ($overwrite -ne 'y') {
      Write-Host "Operation canceled." -ForegroundColor Yellow
      exit
  }
}

# Make the export request and save the response to the specified file
try {
  Invoke-WebRequest -Uri $exportUrl -Headers $headers -OutFile $outputFileName -ErrorAction Stop
} catch {
  Write-Host "Error exporting data: $($_.Exception.Message)" -ForegroundColor Red
  exit
}
