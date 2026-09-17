#!/usr/bin/env pwsh
# This script is designed to be run in a PowerShell environment.

# Name: Workspaces JOSM Settings Script
# Version: 3.0.0
# Date: 2026-09-17
# License: CC-BY-ND 4.0 International
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington

<#
.SYNOPSIS
    Retrieves JOSM configuration settings for editing data in Workspaces

.DESCRIPTION
    This script uses the TDEI API to authenticate and retrieve the settings
    needed to edit a Workspace in JOSM.

    Where the access token goes differs by environment, because the OSM proxy
    accepts two different credential layouts and they are not deployed
    everywhere yet:

      dev          Workspace ID as the JOSM username, token as the password,
                   and a server URL with no Workspace in it.

      stage, prod  Token as the JOSM username, and the Workspace named by the
                   server URL.

    The dev layout exists because a TDEI token is roughly 1.2KB and JOSM will
    not hold that in its username field -- it stores the value truncated and
    then reports an authentication failure quoting the truncated value. Its
    password field has no such limit. Until stage and prod are updated, JOSM
    cannot reliably edit Workspaces in those environments; see the warning the
    script prints.

.PARAMETER WorkspaceEnv
    The environment of the Workspace ('dev', 'stage', or 'prod')

.PARAMETER Username
    Your TDEI username for authentication

.PARAMETER Password
    Your TDEI password for authentication

.PARAMETER WorkspaceId
    The numeric ID of the Workspace you want to edit

.EXAMPLE
    # Interactive usage with prompts:
    .\workspaces-josm.ps1
    # Environment: stage
    # Username: your-username
    # Password: [your-password]
    # Workspace ID: 351

    Returns JOSM configuration for editing Workspace 351 in the stage environment

.NOTES
    Prerequisites:
    - Valid TDEI account credentials
    - Access to the specified Workspace
    - JOSM editor installed for actual editing

    The script will output:
    - OSM Server URL for JOSM configuration
    - The JOSM username to enter
    - The access token, copied to your clipboard rather than printed

    The token is put on the clipboard on purpose. It is about 1.2KB of
    unbroken text, and selecting it out of a terminal is error-prone: copying
    one character short, or catching a surrounding line, produces an
    authentication failure that looks like a server problem.

    Tokens expire about 24 hours after they are issued. Re-run this script to
    get a new one; JOSM will fail to authenticate once the old one lapses.

    Environment URLs:
    - dev: workspaces-dev.sidewalks.washington.edu
    - stage: workspaces-stage.sidewalks.washington.edu
    - prod: workspaces.sidewalks.washington.edu

.LINK
    https://github.com/TaskarCenterAtUW/tdei-tools
#>

# Ask for and validate inputs
Write-Host "Workspaces JOSM Settings Script v3.0.0" -ForegroundColor DarkBlue
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
    $password = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    )
} catch {
    Write-Host "Error processing password." -ForegroundColor Red
    exit 1
} finally {
    # Clear the secure password from memory
    $securePassword = $null
}

# Set the host names based on the entered Workspace Environment.
#
# The TDEI authentication host has to match: a token minted by one environment
# is not accepted by another, so authenticating against prod and then editing
# dev fails with a 401 that looks like bad credentials. Earlier versions of this
# script always authenticated against prod.
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

# Make the authentication request
Write-Host ""
Write-Host "Authenticating with the TDEI API at $tdeiApiHost..." -ForegroundColor DarkGray
try {
    $authBody = @{
        'username' = $username
        'password' = $password
    } | ConvertTo-Json

    $response = Invoke-WebRequest -Uri "https://$tdeiApiHost/api/v1/authenticate" -Method 'POST' -ContentType 'application/json' -Body $authBody -ErrorAction Stop

    # Parse the response
    $responseObject = $response.Content | ConvertFrom-Json

    # Validate that we received an access token
    if (-not $responseObject.access_token) {
        Write-Host "Authentication succeeded but no access token was returned." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "Error retrieving authentication key: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response.StatusCode) {
        Write-Host "HTTP Status Code: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
    }
    exit 1
} finally {
    # Clear sensitive data from memory
    $password = $null
    $authBody = $null
}

$accessToken = $responseObject.access_token

# A truncated token is the failure this whole script exists to avoid, and it is
# indistinguishable from a wrong password once JOSM reports it. Check the shape
# here, where it can still be explained.
if (($accessToken -split '\.').Count -ne 3) {
    Write-Host "The token returned does not look like a complete JWT (expected three dot-separated parts)." -ForegroundColor Red
    Write-Host "Length: $($accessToken.Length) characters. Please report this rather than pasting it into JOSM." -ForegroundColor Red
    exit 1
}

# Tokens last about a day. Showing the expiry saves puzzling over an
# authentication failure that is only a lapsed token.
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
    # Decoding the expiry is a convenience; never fail the script over it.
    $tokenExpiry = $null
}

# Put the token on the clipboard instead of printing it. See the note in the
# help above: selecting 1.2KB of unbroken text out of a terminal is how this
# goes wrong, and the resulting failure looks like a server fault.
$clipboardOk = $false
try {
    Set-Clipboard -Value $accessToken -ErrorAction Stop
    $clipboardOk = $true
} catch {
    $clipboardOk = $false
}

# Display results. The two environments want the token in different fields, so
# the instructions differ rather than being generalised into something that is
# wrong on one of them.
Write-Host ""
Write-Host "Success! Enter the following in JOSM to enable editing Workspace $workspaceId in ${workspaceEnv}:" -ForegroundColor Blue
Write-Host ""

if ($workspaceEnv -eq 'dev') {
    Write-Host "OSM Server URL:" -ForegroundColor Yellow
    Write-Host "https://$osmHost/api"
    Write-Host ""
    Write-Host "OSM username:" -ForegroundColor Yellow
    Write-Host $workspaceId
    Write-Host ""
    Write-Host "OSM password (Access Token):" -ForegroundColor Yellow
} else {
    Write-Host "OSM Server URL:" -ForegroundColor Yellow
    Write-Host "https://$osmHost/workspace/$workspaceId/api"
    Write-Host ""
    Write-Host "OSM username (Access Token):" -ForegroundColor Yellow
}

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

if ($workspaceEnv -ne 'dev') {
    Write-Host ""
    Write-Host "Warning - JOSM will probably not accept this token in ${workspaceEnv}." -ForegroundColor Red
    Write-Host "  JOSM truncates its username field, and the token is about 1.2KB, so it stores only" -ForegroundColor Red
    Write-Host "  part of the value and then reports an authentication failure quoting that partial" -ForegroundColor Red
    Write-Host "  token. The fix is to carry the token in the password field instead, which is" -ForegroundColor Red
    Write-Host "  currently deployed in dev only. Other OSM clients that can hold a long username," -ForegroundColor Red
    Write-Host "  and tools using a https://TOKEN@host/... URL, are unaffected." -ForegroundColor Red
}

Write-Host ""

# Clear the token from memory now that it is on the clipboard
$accessToken = $null
$responseObject = $null

# Prevent the PowerShell window from closing automatically
Read-Host -Prompt "Press <Enter> to exit"
