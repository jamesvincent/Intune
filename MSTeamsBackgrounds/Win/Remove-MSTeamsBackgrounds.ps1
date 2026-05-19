# Remove-MSTeamsBackgrounds.ps1
# Removes Teams background files containing the supplied $IMAGENAME text
# If DELETEALL is entered, all custom background files are removed
# James Vincent - May 2026

# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-TeamsBackgrounds.ps1 -ImageName "SummerCampaign2026"
#   powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-TeamsBackgrounds.ps1 -ImageName "DELETEALL"
#
# If no parameter is supplied, the script prompts interactively allowing for it to be used within Intune, and as a standalone.


param (
    [string]$ImageName
)

$TargetPath = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"

# Prompt user if parameter not supplied
if ([string]::IsNullOrWhiteSpace($ImageName)) {
    $ImageName = Read-Host "Enter the image description used during install, or enter DELETEALL to remove all Teams background images"
}

# Validate input
if ([string]::IsNullOrWhiteSpace($ImageName)) {
    Write-Error "No image description entered. Exiting."
    exit 1
}

# Validate target path
if (!(Test-Path -Path $TargetPath -PathType Container)) {
    Write-Output "Teams background upload path does not exist. Nothing to remove."
    exit 0
}

# DELETEALL option
if ($ImageName -eq "DELETEALL") {

    Write-Output "DELETEALL entered. Removing all JPG files from Teams background uploads folder."

    Get-ChildItem `
        -Path $TargetPath `
        -Filter "*.jpg" `
        -File `
        -ErrorAction SilentlyContinue |
    Remove-Item `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Output "All Teams background JPG files removed."
    exit 0
}

# Remove matching files
Write-Output "Removing Teams background files containing: $ImageName"

$FilesToRemove = Get-ChildItem `
    -Path $TargetPath `
    -Filter "*.jpg" `
    -File `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.Name -like "*$ImageName*"
}

if (!$FilesToRemove) {
    Write-Output "No files found containing '$ImageName'. Nothing to remove."
    exit 0
}

$FilesToRemove | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Output "Removed $($FilesToRemove.Count) Teams background file(s) containing '$ImageName'."

exit 0