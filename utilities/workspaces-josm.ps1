#!/usr/bin/env pwsh
# Name: Workspaces JOSM Settings Script
# Version: 3.0.0
# Date: 2026-09-18
# License: CC-BY-ND 4.0 International
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington

<#
.SYNOPSIS
    Retrieves JOSM configuration settings for editing data in Workspaces

.DESCRIPTION
    This script uses the TDEI API to authenticate and retrieve the settings
    needed to configure JOSM to connect to a workspace.

    All environments use the workspace ID as the JOSM username, the token as
    the password, and a server URL with no workspace ID in it.

.PARAMETER WorkspaceEnv
    The environment of the Workspace ('dev', 'stage', or 'prod')

.PARAMETER Username
    Your TDEI username for authentication

.PARAMETER Password
    Your TDEI password for authentication

.PARAMETER WorkspaceId
    The numeric ID of the workspace you want to edit

.EXAMPLE
    # Interactive usage with prompts:
    .\workspaces-josm.ps1
    # Environment: stage
    # Username: your-username
    # Password: [your-password]
    # Workspace ID: 351

    Returns JOSM configuration for editing workspace 351 in the stage environment

.NOTES
    Prerequisites:
    - Valid TDEI account credentials
    - Access to the specified Workspace
    - JOSM editor installed for actual editing

    The script will output:
    - OSM Server URL for JOSM configuration
    - The JOSM username to enter
    - The access token, copied to your clipboard rather than printed

    The access token is copied to the clipboard. Tokens expire about 24 hours
    after they are issued; re-run this script to get a new one.

    Environment URLs:
    - dev: workspaces-dev.sidewalks.washington.edu
    - stage: workspaces-stage.sidewalks.washington.edu
    - prod: workspaces.sidewalks.washington.edu

.LINK
    https://github.com/TaskarCenterAtUW/tdei-tools
#>

Write-Host "Workspaces JOSM Settings Script v3.0.2" -ForegroundColor DarkBlue
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

$passwordBstr = [System.IntPtr]::Zero
try {
    $passwordBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $password = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBstr)
} catch {
    Write-Host "Error processing password." -ForegroundColor Red
    exit 1
} finally {
    if ($passwordBstr -ne [System.IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr)
    }
    $securePassword = $null
}

switch ($workspaceEnv) {
    'dev' {
        $osmHost = 'osm.workspaces-dev.sidewalks.washington.edu'
        $tdeiApiHost = 'api-dev.tdei.us'
    }
    'stage' {
        $osmHost = 'osm.workspaces-stage.sidewalks.washington.edu'
        $tdeiApiHost = 'api-stage.tdei.us'
    }
    'prod' {
        $osmHost = 'osm.workspaces.sidewalks.washington.edu'
        $tdeiApiHost = 'api.tdei.us'
    }
}

Write-Host ""
Write-Host "Authenticating with the TDEI API at $tdeiApiHost..." -ForegroundColor DarkGray
try {
    $authBody = @{
        'username' = $username
        'password' = $password
    } | ConvertTo-Json

    $response = Invoke-WebRequest -Uri "https://$tdeiApiHost/api/v1/authenticate" -Method 'POST' -ContentType 'application/json' -Body $authBody -ErrorAction Stop

    $responseObject = $response.Content | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace([string]$responseObject.access_token)) {
        Write-Host "Authentication succeeded but no access token was returned." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "Error retrieving authentication key: $($_.Exception.Message)" -ForegroundColor Red
    if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
        Write-Host "HTTP Status Code: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
    }
    exit 1
} finally {
    $password = $null
    $authBody = $null
}

$accessToken = [string]$responseObject.access_token

if (($accessToken -split '\.').Count -ne 3) {
    Write-Host "The token returned does not look like a complete JWT (expected three dot-separated parts)." -ForegroundColor Red
    Write-Host "Length: $($accessToken.Length) characters." -ForegroundColor Red
    exit 1
}

$tokenExpiry = $null
try {
    $payload = ($accessToken -split '\.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    $claims = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
    if ($claims.exp) {
        $tokenExpiry = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).LocalDateTime
    }
} catch {
    $tokenExpiry = $null
}

$clipboardOk = $false
try {
    Set-Clipboard -Value $accessToken -ErrorAction Stop
    $clipboardOk = $true
} catch {
    $clipboardOk = $false
}

Write-Host ""
Write-Host "Success! Enter the following in JOSM to enable editing Workspace $workspaceId in ${workspaceEnv}:" -ForegroundColor Blue
Write-Host ""

Write-Host "OSM Server URL:" -ForegroundColor Yellow
Write-Host "https://$osmHost/api"
Write-Host ""
Write-Host "OSM username:" -ForegroundColor Yellow
Write-Host $workspaceId
Write-Host ""
Write-Host "OSM password (Access Token):" -ForegroundColor Yellow

if ($clipboardOk) {
    Write-Host "  [copied to your clipboard - paste it with Ctrl+V, or Cmd+V on macOS]" -ForegroundColor Cyan
} else {
    Write-Host "  [could not reach the clipboard, so the token is printed below]" -ForegroundColor Red
    Write-Host ""
    Write-Host $accessToken
}

Write-Host ""
Write-Host "Set Authentication to 'Basic' in JOSM's OSM Server preferences." -ForegroundColor DarkGray

if ($tokenExpiry) {
    Write-Host "This token expires $($tokenExpiry.ToString('yyyy-MM-dd HH:mm')). Re-run this script for a new one." -ForegroundColor DarkGray
} else {
    Write-Host "Tokens expire about 24 hours after they are issued. Re-run this script for a new one." -ForegroundColor DarkGray
}

Write-Host ""

$accessToken = $null
$responseObject = $null

Read-Host -Prompt "Press <Enter> to exit"
