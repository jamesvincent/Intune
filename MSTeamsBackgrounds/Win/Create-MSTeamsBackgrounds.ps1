<#
.SYNOPSIS
    Script to generate Teams background files and Intune Win32App

.PREREQUISITES
    Requires ResizeImage PowerShell Module: https://github.com/RonildoSouza/ResizeImageModulePS
    Requires IntuneWinAppUtil.exe to generate .intunewin

    Both will be downloaded if missing.

.DESCRIPTION
    Run this script on a build/test device to generate the source for Intune
    Deploy in bulk using Intune, specify User context for the App
    When no parameter is supplied with the script, the script runs in unattended install mode
    Use -RemoveImages to remove Microsoft Teams background images previously deployed by this package

.EXAMPLE
    # Install
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Deploy-MSTeamsBackgrounds.ps1

.EXAMPLE
    # Uninstall
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Deploy-MSTeamsBackgrounds.ps1 -RemoveImages

.VERSION
    2.00 - May 2026

.AUTHOR
    James Vincent
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ImageLocation,

    [Parameter(Mandatory = $false)]
    [string]$ImageName
)

# Prompt for ImageLocation if not supplied as a parameter
if ([string]::IsNullOrWhiteSpace($ImageLocation)) {
    $ImageLocation = Read-Host "Enter the path to your collection of backgrounds (.jpg or .png format)"
}

# Prompt for ImageName if not supplied as a parameter
if ([string]::IsNullOrWhiteSpace($ImageName)) {
    $ImageName = Read-Host "Enter a description for the images. The same description will be used for all images"
}

# Validate ImageName
if ([string]::IsNullOrWhiteSpace($ImageName)) {
    Write-Error "No image description entered, unable to proceed."
    exit 1
}

# Validate ImageLocation
if (!(Test-Path -Path $ImageLocation -PathType Container)) {
    Write-Error "Input path does not exist, unable to proceed."
    exit 1
}

# Normalise ImageLocation to avoid double backslashes in generated paths
$ImageLocation = (Resolve-Path -Path $ImageLocation).Path

# Define output location
$outputPath = Join-Path -Path $ImageLocation -ChildPath "Intune"

# Check to see if the ResizeImageModule is present, if not, install it
if (!(Get-InstalledModule -Name ResizeImageModule -ErrorAction SilentlyContinue)) {
    Write-Host "ResizeImageModule not installed, installing..." -ForegroundColor Yellow
    Install-Module -Name ResizeImageModule -Scope CurrentUser -Force
    Write-Host "Import Module ResizeImageModule"
    Import-Module ResizeImageModule
}
else {
    if (!(Get-Module -Name ResizeImageModule)) {
        Write-Host "Import ResizeImageModule"
        Import-Module ResizeImageModule
    }
    else {
        Write-Host "ResizeImageModule already imported"
    }
}

$ScriptContent = @'
<#
.SYNOPSIS
    Installs or removes Microsoft Teams background images.

.DESCRIPTION
    When no parameter is supplied, the script runs install mode unattended.
    Use -RemoveImages to remove Microsoft Teams background images previously deployed by this package.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Deploy-MSTeamsBackgrounds.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Deploy-MSTeamsBackgrounds.ps1 -RemoveImages

.AUTHOR
    James Vincent
    May 2026
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [switch]$RemoveImages,

    [Parameter(Mandatory = $false)]
    [string]$ImageName
)

$LogDirectory = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogDirectory "App-Install-MSTeamsBackgrounds.log"

if (!(Test-Path -Path $LogDirectory -PathType Container)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] [$Level] $Message"

    Add-Content -Path $LogFile -Value $LogEntry

    if ($Level -eq "ERROR") {
        Write-Error $Message
    }
    else {
        Write-Output $Message
    }
}

Write-Log "Script started."
Write-Log "Running as user: $env:USERNAME"

$TargetPath = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"
Write-Log "Target path: $TargetPath"

if ($RemoveImages) {

    Write-Log "RemoveImages mode selected."

    if (!(Test-Path -Path $TargetPath -PathType Container)) {
        Write-Log "Teams background upload path does not exist. Nothing to remove."
        exit 0
    }

    $DetectionFiles = Get-ChildItem -Path $TargetPath -Filter "*.detection" -File -ErrorAction SilentlyContinue

    if (!$DetectionFiles) {
        Write-Log "No detection files found. Nothing to remove."
        exit 0
    }

    $RemovedImageCount = 0
    $RemovedDetectionCount = 0

    foreach ($DetectionFile in $DetectionFiles) {

        Write-Log "Processing detection file: $($DetectionFile.FullName)"

        $ImageFileNames = Get-Content -Path $DetectionFile.FullName -ErrorAction SilentlyContinue |
            Where-Object {
                $_ -match '\.jpg$'
            }

        foreach ($ImageFileName in $ImageFileNames) {

            $ImagePath = Join-Path -Path $TargetPath -ChildPath $ImageFileName

            if (Test-Path -Path $ImagePath -PathType Leaf) {
                Write-Log "Removing image file: $ImagePath"

                try {
                    Remove-Item -Path $ImagePath -Force -ErrorAction Stop
                    $RemovedImageCount++
                }
                catch {
                    Write-Log "Failed to remove image file: $ImagePath. $($_.Exception.Message)" "WARN"
                }
            }
            else {
                Write-Log "Image file listed in detection file was not found: $ImagePath" "WARN"
            }
        }

        try {
            Write-Log "Removing detection file: $($DetectionFile.FullName)"
            Remove-Item -Path $DetectionFile.FullName -Force -ErrorAction Stop
            $RemovedDetectionCount++
        }
        catch {
            Write-Log "Failed to remove detection file: $($DetectionFile.FullName). $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "RemoveImages completed. Image files removed: $RemovedImageCount. Detection files removed: $RemovedDetectionCount."
    exit 0
}

Write-Log "No parameter provided. Install mode selected."

if (!(Test-Path -Path $TargetPath -PathType Container)) {
    Write-Log "Target path does not exist. Creating folder."
    New-Item -Path $TargetPath -ItemType Directory -Force | Out-Null
}

try {
    Write-Log "Copying JPG files to Teams background upload folder."
    Copy-Item -Path ".\*.jpg" -Destination $TargetPath -Force -ErrorAction Stop

    Write-Log "Copying detection files to Teams background upload folder."
    Copy-Item -Path ".\*.detection" -Destination $TargetPath -Force -ErrorAction Stop
}
catch {
    Write-Log "Failed to copy Teams background or detection files. $($_.Exception.Message)" "ERROR"
    exit 1
}

$DetectionFiles = Get-ChildItem -Path $TargetPath -Filter "*.detection" -File -ErrorAction SilentlyContinue

if ($DetectionFiles) {

    $InstallDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "Appending install timestamp to detection files."

    foreach ($DetectionFile in $DetectionFiles) {
        Write-Log "Updating detection file: $($DetectionFile.FullName)"

        Add-Content -Path $DetectionFile.FullName -Value ""
        Add-Content -Path $DetectionFile.FullName -Value "Installed: $InstallDateTime"
    }
}
else {
    Write-Log "No detection files found to update." "WARN"
}

Write-Log "Install completed successfully."
exit 0

'@
# Convert PNG files to JPG before resizing
$pngFiles = Get-ChildItem -Path $ImageLocation -Filter "*.png" -File -ErrorAction SilentlyContinue

if ($pngFiles) {

    Write-Host "PNG files detected. Converting to JPG..." -ForegroundColor Cyan

    Add-Type -AssemblyName System.Drawing

    foreach ($pngFile in $pngFiles) {

        $jpgOutput = Join-Path -Path $ImageLocation -ChildPath "$($pngFile.BaseName).jpg"

        Write-Host "Converting PNG to JPG - $($pngFile.Name)" -ForegroundColor Cyan

        $image = [System.Drawing.Image]::FromFile($pngFile.FullName)

        try {

            $bitmap = New-Object System.Drawing.Bitmap $image.Width, $image.Height
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

            $graphics.Clear([System.Drawing.Color]::White)
            $graphics.DrawImage($image, 0, 0, $image.Width, $image.Height)

            $bitmap.Save($jpgOutput, [System.Drawing.Imaging.ImageFormat]::Jpeg)

        }
        finally {

            if ($graphics) { $graphics.Dispose() }
            if ($bitmap) { $bitmap.Dispose() }
            if ($image) { $image.Dispose() }

        }
    }
}

# Remove non-JPG image files after conversion
Write-Host "Removing non-JPG image files..." -ForegroundColor Yellow

$NonJpgFiles = Get-ChildItem `
    -Path $ImageLocation `
    -File `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.Extension -in @(".png", ".bmp", ".gif", ".webp", ".tiff")
}

foreach ($File in $NonJpgFiles) {

    try {

        Write-Host "Removing file - $($File.Name)" -ForegroundColor Yellow

        Remove-Item `
            -Path $File.FullName `
            -Force `
            -ErrorAction Stop

    }
    catch {

        Write-Warning "Failed to remove $($File.Name). $($_.Exception.Message)"

    }
}

# Check for JPG files
$jpgFiles = Get-ChildItem -Path $ImageLocation -Filter "*.jpg" -File -ErrorAction SilentlyContinue

if (!$jpgFiles) {
    Write-Error "No JPG files found in $ImageLocation, unable to proceed."
    exit 1
}

Write-Output "JPG files found in $ImageLocation"

# Create output folder
if (!(Test-Path -Path $outputPath)) {
    Write-Output "Creating output location $outputPath"
    New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
}

# Create Teams friendly backgrounds
Write-Output "Creating Teams friendly backgrounds"

$CreatedFiles = @()

foreach ($image in $jpgFiles) {

    $guid = New-Guid

    $BackgroundFileName = "$guid$ImageName.jpg"
    $ThumbnailFileName = "$guid$ImageName`_thumb.jpg"

    $BackgroundOutputFile = Join-Path -Path $outputPath -ChildPath $BackgroundFileName
    $ThumbnailOutputFile = Join-Path -Path $outputPath -ChildPath $ThumbnailFileName

    Write-Host "Creating Background - $BackgroundFileName"

    Resize-Image `
        -InputFile $image.FullName `
        -Width 1920 `
        -Height 1080 `
        -ProportionalResize $true `
        -OutputFile $BackgroundOutputFile

    $CreatedFiles += $BackgroundFileName

    Write-Host "Creating Thumbnail - $ThumbnailFileName"

    Resize-Image `
        -InputFile $image.FullName `
        -Width 220 `
        -Height 158 `
        -ProportionalResize $true `
        -OutputFile $ThumbnailOutputFile

    $CreatedFiles += $ThumbnailFileName
}

# Create detection file containing generated filenames
$SafeImageName = $ImageName -replace '[^a-zA-Z0-9-_]', '_'
$DetectionFileName = "$SafeImageName.detection"
$DetectionFile = Join-Path -Path $outputPath -ChildPath $DetectionFileName

Write-Output "Creating detection file - $DetectionFile"

$CreatedFiles | Out-File `
    -FilePath $DetectionFile `
    -Encoding UTF8 `
    -Force

# Create Intune detection method script
$DetectionMethodScriptName = "Detect-MSTeamsBackgrounds.ps1"
$DetectionMethodScriptPath = Join-Path -Path $outputPath -ChildPath $DetectionMethodScriptName

$DetectionMethodScriptContent = @"
# Intune detection script for Microsoft Teams background package
# Generated by Create-MSTeamsBackgroundPackage.ps1
# James Vincent - May 2026

[CmdletBinding()]
param ()

`$TargetPath = "`$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"
`$DetectionFile = Join-Path -Path `$TargetPath -ChildPath "$DetectionFileName"

if (Test-Path -Path `$DetectionFile -PathType Leaf) {
    Write-Output "Detected: `$DetectionFile"
    exit 0
}
else {
    Write-Output "Not detected: `$DetectionFile"
    exit 1
}
"@

Write-Output "Creating Intune detection method script: $DetectionMethodScriptPath"

$DetectionMethodScriptContent | Out-File `
    -FilePath $DetectionMethodScriptPath `
    -Encoding UTF8 `
    -Force

# Creating Intune Win32App File
$IntuneWinUtil = Join-Path -Path $ImageLocation -ChildPath "IntuneWinAppUtil.exe"
$SourceFolder = $outputPath
$SetupFile = "Deploy-MSTeamsBackgrounds.ps1"
$OutputFolder = $outputPath

# Create deployment script
$ScriptPath = Join-Path -Path $outputPath -ChildPath "Deploy-MSTeamsBackgrounds.ps1"
$ScriptContent | Out-File -FilePath $ScriptPath -Encoding UTF8 -Force

# Check if IntuneWinAppUtil.exe exists
if (!(Test-Path -Path $IntuneWinUtil -PathType Leaf)) {

    Write-Output "IntuneWinAppUtil.exe not found - Downloading"

    $Url = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/refs/heads/master/IntuneWinAppUtil.exe"
    $Destination = Join-Path -Path $ImageLocation -ChildPath "IntuneWinAppUtil.exe"

    Invoke-WebRequest -Uri $Url -OutFile $Destination

    Start-Sleep 5
}

Write-Output "Creating Intune Win32App for Deployment"

Start-Process `
    -FilePath $IntuneWinUtil `
    -ArgumentList "-c `"$SourceFolder`" -s `"$SetupFile`" -o `"$OutputFolder`" -q" `
    -NoNewWindow `
    -Wait

# Validate output
$IntuneWinFile = Join-Path -Path $OutputFolder -ChildPath "Deploy-MSTeamsBackgrounds.intunewin"

if (Test-Path -Path $IntuneWinFile -PathType Leaf) {

    Write-Output ""
    Write-Output "Intunewin file generated successfully at $OutputFolder, now create your Intune application in the Intune console"
    Write-Output ""
    Write-Output "Install command:"
    Write-Output "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Deploy-MSTeamsBackgrounds.ps1"
    Write-Output ""
    Write-Output "Uninstall command:"
    Write-Output "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Deploy-MSTeamsBackgrounds.ps1 -RemoveImages"
    Write-Output ""
#    Write-Output "Standalone execution of Deploy-MSTeamsBackgrounds.ps1 examples:"
#    Write-Output "  .\Deploy-MSTeamsBackgrounds.ps1"
#    Write-Output "  .\Deploy-MSTeamsBackgrounds.ps1 -RemoveImages"
#    Write-Output "  .\Deploy-MSTeamsBackgrounds.ps1 -RemoveImages -ImageName 'SummerCampaign'"
#    Write-Output ""
#    Write-Output "Intune detection file created:"
#    Write-Output "$DetectionFile"
#    Write-Output ""
#    Write-Output "Intune detection method script created:"
#    Write-Output "$DetectionMethodScriptPath"
#    Write-Output ""
    Write-Output "Use the following file as the Intune Win32 app custom detection script:"
    Write-Output "$DetectionMethodScriptName"

    exit 0
}
else {

    Write-Error "An error occurred generating the IntuneWin package."
    exit 1
}
