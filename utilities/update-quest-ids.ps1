# Name: Quest ID Update Script
# Version: 1.1
# Description: This script updates the "quest_id" and "question_id" values in a GoInfoGame quest definition file.
# Author: Amy Bordenave, Taskar Center for Accessible Technology, University of Washington
# Date: 2025-07-31
# License: CC-BY-ND 4.0 International

Write-Host "Quest ID Update Script v1.1"
Write-Host "CAUTION: This assumes that new quests have been added with very high temporary IDs, such as 999, and may not work as expected otherwise!"
Write-Host "CAUTION: This directly updates the existing file - make sure you have backups!"
Write-Host "Enter the full path to the quest definition file, without quotes:"
$jsonPath = Read-Host

# Validate file path
if (-Not (Test-Path $jsonPath)) {
    Write-Error "File not found: $jsonPath"
    exit
}

# Read and parse the JSON file
# Note the workaround approach of joining on newlines instead of using the -Raw flag, which is not available in older versions of PowerShell
try {
    $json = (Get-Content -Path $jsonPath) -join "`n" | ConvertFrom-Json
    Write-Host "Debug: JSON structure loaded successfully."
}
catch {
    Write-Error "Failed to read or parse JSON: $($_.Exception.Message)"
    exit
}

# Assign new quest_ids and build a mapping from old to new
$oldToNewId = @{}
$newId = 1
foreach ($section in $json) {
    if ($section.quests) {
        Write-Host "Debug: Found quests in section."
        foreach ($quest in $section.quests) {
            Write-Host "Debug: Processing quest with ID $($quest.quest_id)."
            $oldToNewId[$quest.quest_id] = $newId
            $quest.quest_id = $newId
            $newId++
        }
    }
    else {
        Write-Host "Debug: No quests found in section."
    }
}

# Update all question_id references in quest_answer_dependency
foreach ($section in $json) {
    if ($section.quests) {
        foreach ($quest in $section.quests) {
            if ($quest.PSObject.Properties.Name -contains "quest_answer_dependency" -and $quest.quest_answer_dependency) {
                $dep = $quest.quest_answer_dependency
                if ($dep.PSObject.Properties.Name -contains "question_id") {
                    $oldId = $dep.question_id
                    if ($oldToNewId.ContainsKey($oldId)) {
                        Write-Host "Debug: Updating dependency for question ID $oldId -> $($oldToNewId[$oldId])."
                        $dep.question_id = $oldToNewId[$oldId]
                    }
                }
            }
        }
    }
}

# Write the updated JSON back to the file
try {
    $updatedJson = $json | ConvertTo-Json -Depth 100
    Write-Host "Debug: JSON serialized successfully."
    $updatedJson | Set-Content $jsonPath -Encoding utf8
    Write-Host "Success: Updated JSON written to $jsonPath"
}
catch {
    Write-Error "Failed to write JSON: $($_.Exception.Message)"
}

Read-Host -Prompt "Press Enter to exit"
