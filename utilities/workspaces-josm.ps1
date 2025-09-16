# Name: Workspaces JOSM Settings Script
# Version: 1.0
# Description: This script uses the Workspaces API to retrieve JOSM configuration settings
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-07-29
# License: CC-BY-ND 4.0 International

# This script is designed to be run in a PowerShell environment.

# Ask for and validate inputs
Write-Host "Workspaces JOSM Settings Script v1.0" -ForegroundColor DarkBlue
Write-Host ""
Write-Host "Step 1 - Enter the Environment of the Workspace you wish to edit, in the format 'dev', 'stage', or 'prod'" -ForegroundColor Green
Write-Host "  Example - If your Workspace URL is 'https://workspaces-stage.sidewalks.washington.edu/workspace/351/settings' enter 'stage'" -ForegroundColor DarkGreen
$workspaceEnv = Read-Host

if ($workspaceEnv -notin @('dev', 'stage', 'prod')) {
  Write-Host "Invalid Environment. Please enter 'dev', 'stage', or 'prod'." -ForegroundColor Red
  exit 1
}

Write-Host "Step 2 - Enter your TDEI username:" -ForegroundColor Green
$username = Read-Host

if ([string]::IsNullOrWhiteSpace($username)) {
  Write-Host "Username cannot be empty." -ForegroundColor Red
  exit 1
}

Write-Host "Step 3 - Enter your TDEI password:" -ForegroundColor Green
$securePassword = Read-Host -AsSecureString

Write-Host "Step 4 - Enter the Workspace number, in the format '123'" -ForegroundColor Green
Write-Host "  Example - If your Workspace URL is 'https://workspaces-stage.sidewalks.washington.edu/workspace/351/settings' enter '351'" -ForegroundColor DarkGreen
$workspaceId = Read-Host

if (-not $workspaceId -or $workspaceId -notmatch '^\d+$') {
  Write-Host "Invalid Workspace ID. Please enter the numeric Workspace ID." -ForegroundColor Red
  exit 1
}

# Convert the secure string password to a regular string
try {
  $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
  )
}
catch {
  Write-Host "Error processing password." -ForegroundColor Red
  exit 1
}
finally {
  # Clear the secure password from memory
  $securePassword = $null
}

# Set the environment postfix based on the entered Workspace Environment
switch ($workspaceEnv) {
  'dev' { $envPostfix = '-dev' }
  'stage' { $envPostfix = '-stage' }
  'prod' { $envPostfix = '' }
}

# Formulate the OSM Server URL value
$osmServerUrl = "https://osm.workspaces$envPostfix.sidewalks.washington.edu/workspace/$workspaceId/api"

# Make the authentication request
Write-Host ""
Write-Host "Authenticating with TDEI API..." -ForegroundColor DarkGray
try {
  $authBody = @{
    'username' = $username
    'password' = $password
  } | ConvertTo-Json
    
  $response = Invoke-WebRequest -Uri 'https://api.tdei.us/api/v1/authenticate' -Method 'POST' -ContentType 'application/json' -Body $authBody -ErrorAction Stop
    
  # Parse the response
  $responseObject = $response.Content | ConvertFrom-Json
    
  # Validate that we received an access token
  if (-not $responseObject.access_token) {
    Write-Host "Authentication succeeded but no access token was returned." -ForegroundColor Red
    exit 1
  }
}
catch {
  Write-Host "Error retrieving authentication key: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.Exception.Response.StatusCode) {
    Write-Host "HTTP Status Code: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
  }
  exit 1
}
finally {
  # Clear sensitive data from memory
  $password = $null
  $authBody = $null
}

# Display results
Write-Host ""
Write-Host "Success! Enter the following in JOSM to enable editing Workspace $workspaceId in ${workspaceEnv}:" -ForegroundColor Blue
Write-Host ""
Write-Host "OSM Server URL:" -ForegroundColor Yellow
Write-Host $osmServerUrl
Write-Host ""
Write-Host "OSM username (Access Token):" -ForegroundColor Yellow
Write-Host $responseObject.access_token
Write-Host ""

# Prevent the PowerShell window from closing automatically
Read-Host -Prompt "Press <Enter> to exit"
