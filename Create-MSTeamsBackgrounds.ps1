# Script to generate Teams background files and Intune Win32App
# Requires ResizeImage PowerShell Module: https://github.com/RonildoSouza/ResizeImageModulePS
# Run this script on a build/test device to generate the source for Intune
# Deploy in bulk using Intune, specify User context for the App
# Use Copy-TeamsBackgrounds.ps1 as the Installation file for your Intune app
# Detect using one/some of the files deployed
# James Vincent - March 2025

# Check to see if the ResizeImageModule is present, if not, Install it
if (!(Get-InstalledModule -Name ResizeImageModule -ErrorAction SilentlyContinue )) {
    Write-Host "ResizeImageModule not installed, installing..." -ForegroundColor Yellow
    Install-Module -Name  ResizeImageModule -Scope CurrentUser -force
    Write-Host "Import Module ResizeImageModule"
    Import-Module  ResizeImageModule
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

# Define Variables
$ImageLocation = read-host "Enter the path to your collection of backgrounds (.jpg format)"
$ImageName = read-host "Enter a description for the images. The same description will be used for all images"
$outputPath = "$ImageLocation\Intune"
$ScriptContent = @'
        $TargetPath = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"
        
        # Check if the directory exists, if not, create it silently
        if (!(Test-Path -Path $TargetPath -PathType Container)) {
            New-Item -Path $TargetPath -ItemType Directory -Force | Out-Null
        }
        
        # Copy all .jpg files from the current directory to the target directory, silently and forcefully
        Copy-Item -Path ".\*.jpg" -Destination $TargetPath -Force -ErrorAction SilentlyContinue
'@

# Check to see if the supplied Image location contains jpg files, and is suitable
# If it is, create the backgrounds and Intune source file
# If it is not, exit and error
if (Test-Path -Path $ImageLocation -PathType Container) {
    $jpgFiles = Get-ChildItem -Path $ImageLocation -Filter "*.jpg" -File
    if ($jpgFiles) {
        Write-Output "JPG files found in $ImageLocation"
        if (!(Test-Path -Path $OutputPath)) {
            Write-Output "Creating output location $OutputPath"
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        # Create Teams friendly backgrounds
        Write-Output "Creating Teams friendly backgrounds"
        $images = Get-ChildItem $ImageLocation\*.jpg
        foreach($image in $images){
            $guid = New-Guid
            Write-Host "Creating Background - $guid$ImageName.jpg"
            Resize-Image -InputFile $image -Width 1920 -Height 1080 -ProportionalResize $true -OutputFile $outputPath\$guid$ImageName.jpg
            Write-Host "Creating Thumbnail - $guid$ImageName`_thumb.jpg"
            $ThumbName = "$guid$ImageName`_thumb.jpg"
            Resize-Image -InputFile $image -Width 220 -Height 158 -ProportionalResize $true -OutputFile $outputPath\$ThumbName
        } 
        # Creating Intune Win32App File
        $IntuneWinUtil = "$ImageLocation\IntuneWinAppUtil.exe"
        $SourceFolder = "$OutputPath"
        $SetupFile = "Copy-TeamsBackgrounds.ps1"
        $OutputFolder = "$OutputPath"
        # Check if IntuneWinAppUtil.exe exists
        # If it does, generate an Intunewin file
        # If it does not, download IntuneWinAppUtil.exe then generate an Intunewin file
        if (Test-Path -Path $IntuneWinUtil -PathType Leaf) {
            Write-Output "IntuneWinAppUtil.exe exists"
            $ScriptPath = "$OutputPath\Copy-TeamsBackgrounds.ps1"
            $ScriptContent | Out-File -FilePath $ScriptPath -Encoding UTF8 -Force
            Write-Output "Creating Intune Win32App for Deployment"
            Start-Process -FilePath $IntuneWinUtil -ArgumentList "-c `"$SourceFolder`" -s `"$SetupFile`" -o `"$OutputFolder`" -q" -NoNewWindow -Wait
        } else {
            Write-Output "IntuneWinAppUtil.exe not found - Downloading"
            $Url = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/refs/heads/master/IntuneWinAppUtil.exe"
            $Destination = "$ImageLocation\IntuneWinAppUtil.exe"
            Invoke-WebRequest -Uri $Url -OutFile $Destination
            Start-Sleep 5
            $ScriptPath = "$OutputPath\Copy-TeamsBackgrounds.ps1"
            $ScriptContent | Out-File -FilePath $ScriptPath -Encoding UTF8 -Force
            Write-Output "Creating Intune Win32App for Deployment"
            Start-Process -FilePath $IntuneWinUtil -ArgumentList "-c `"$SourceFolder`" -s `"$SetupFile`" -o `"$OutputFolder`" -q" -NoNewWindow -Wait
        }
    } else {
        Write-Error "No JPG files found in $ImageLocation, unable to proceed."
        exit 1
    }
} else {
    Write-Error "Input path does not exist, unable to proceed"
    exit 1
}

if (Test-Path -Path $OutputFolder\Copy-TeamsBackgrounds.intunewin -PathType Leaf) {
    Write-Output "Intunewin file generated successfully at $OutputFolder, now create your Intune Application in the Intune console"
    Write-Output "Installation command: powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File Copy-TeamsBackgrounds.ps1"
    exit 0
} else {
    Write-Error "An error occurred."
    exit 1
}