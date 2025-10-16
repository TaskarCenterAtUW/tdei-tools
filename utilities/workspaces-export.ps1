#!/usr/bin/env pwsh
# This script is designed to be run in a PowerShell environment.

# Name: Workspaces Export Script
# Version: 2.0.1
# Date: 2025-10-16
# License: CC-BY-ND 4.0 International
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington

<#
.SYNOPSIS
	Exports data directly from a Workspaces database to an OSM file

.DESCRIPTION
	This script uses the Workspaces API to export a complete dataset from a 
	specified Workspace environment. It retrieves the bounding box for the 
	workspace and downloads all data, in .osm format.

.PARAMETER WorkspaceEnv
	The environment of the Workspace ('dev', 'stage', or 'prod')

.PARAMETER ApiKey
	Your API key from the corresponding TDEI Portal

.PARAMETER WorkspaceId
	The numeric ID of the Workspace to export

.PARAMETER OutputFileName
	The name of the output OSM file (must end with '.osm')

.EXAMPLE
	# Interactive usage with prompts:
	.\workspaces-export.ps1
	# Environment: stage
	# API Key: [api-key]
	# Workspace ID: 351
	# Output file: export-stage-351-20250917-01.osm
	
	Exports all data from Workspace 351 in the stage environment to the specified file.

.NOTES
	Prerequisites:
	- Valid TDEI Portal API key for the target environment
	- Access permissions to the specified Workspace
	- Sufficient disk space for the export file
	
	API Key locations:
	- Dev: https://portal-dev.tdei.us/
	- Stage: https://portal-stage.tdei.us/
	- Prod: https://portal.tdei.us/
	
	The script will:
	- Validate all input parameters
	- Retrieve the Workspace's bounding box
	- Download the complete dataset as OSM XML
	
	Recommended file naming convention: export-{env}-{workspace_id}-{date}-{counter}.osm

.LINK
	https://github.com/TaskarCenterAtUW/tdei-tools
#>

# Ask for and validate inputs
Write-Host "Workspaces Export Script v2.0.0"
Write-Host "Step 1 - Enter the Environment of the dataset you wish to export, in the format 'dev', 'stage', or 'prod'"
Write-Host "Example - If your Workspace URL is 'https://workspaces-stage.sidewalks.washington.edu/workspace/351/settings' enter 'stage'"
$workspaceEnv = Read-Host

if ($workspaceEnv -notin @('dev', 'stage', 'prod')) {
	Write-Host "Invalid Environment. Please enter 'dev', 'stage', or 'prod'." -ForegroundColor Red
	exit
}

Write-Host "Step 2 - Enter your API key from the corresponding TDEI Portal, in the format 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
Write-Host "This is labeled 'My API Key' on https://portal-dev.tdei.us/, https://portal-stage.tdei.us/, or https://portal.tdei.us/"
$secureApiKey = Read-Host -AsSecureString

Write-Host "Step 3 - Enter the Workspace number, in the format '123'"
Write-Host "Example - If your Workspace URL is 'https://workspaces-stage.sidewalks.washington.edu/workspace/351/settings' enter '351'"
$workspaceId = Read-Host

if (-not $workspaceId -or $workspaceId -notmatch '^\d+$') {
	Write-Host "Invalid Workspace ID. Please enter the numeric Workspace ID." -ForegroundColor Red
	exit
}

Write-Host "Step 4 - Enter the name of the output file, in the format 'filename.osm'"
Write-Host "It is recommended to include the Workspace number in the file name, such as 'export-prod-45-20250521.osm'"
$outputFileName = Read-Host

if (-not $outputFileName -or $outputFileName -notmatch '\.osm$') {
	Write-Host "Invalid output file name. Please enter a name ending with '.osm'." -ForegroundColor Red
	exit
}

# Convert the secure string API key to a regular string
$apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
	[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiKey)
)

# Set the environment postfix based on the entered Workspace Environment
if ($workspaceEnv -eq 'dev') {
	$envPostfix = '-dev'
}
if ($workspaceEnv -eq 'stage') {
	$envPostfix = '-stage'
}
if ($workspaceEnv -eq 'prod') {
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
}
catch {
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
}
catch {
	Write-Host "Error exporting data: $($_.Exception.Message)" -ForegroundColor Red
	exit
}
