# Script: Get-WinGetDefaultStateSize.ps1
# Purpose: Reports the total size of the WinGet defaultState folder.
# Response to Microsoft outage/issue: IT1168328 - 9th October 2025.
# James Vincent

# Define the target folder path
$targetFolder = Join-Path $env:WinDir "Temp\WinGet\defaultState"

# Define the size threshold (2000 MB)
$thresholdBytes = 2000MB

# Verify that the folder exists
if (Test-Path $targetFolder) {
    # Get all files and sum their lengths
    $folderSizeBytes = (Get-ChildItem -Path $targetFolder -Recurse -ErrorAction SilentlyContinue | 
        Where-Object { -not $_.PSIsContainer } | 
        Measure-Object -Property Length -Sum).Sum

    # Convert bytes to a human-readable size
    if ($folderSizeBytes -ge 1GB) {
        $folderSize = "{0:N2} GB" -f ($folderSizeBytes / 1GB)
    } elseif ($folderSizeBytes -ge 1MB) {
        $folderSize = "{0:N2} MB" -f ($folderSizeBytes / 1MB)
    } elseif ($folderSizeBytes -ge 1KB) {
        $folderSize = "{0:N2} KB" -f ($folderSizeBytes / 1KB)
    } else {
        $folderSize = "$folderSizeBytes bytes"
    }

    Write-Host "Folder: $targetFolder"
    Write-Host "Total Size: $folderSize"

    # Check if size exceeds threshold
    if ($folderSizeBytes -gt $thresholdBytes) {
        Write-Host "ERROR: Folder size exceeds $thresholdBytes limit." -ForegroundColor Red
        Write-Output "Large: $folderSize"
        exit 1
    } else {
        Write-Host "Folder size is within acceptable limits." -ForegroundColor Green
        Write-Output "OK: $folderSize"
        exit 0
    }

} else {
    Write-Output "Not exist: WinGet folder does not exist."
    exit 0
}
