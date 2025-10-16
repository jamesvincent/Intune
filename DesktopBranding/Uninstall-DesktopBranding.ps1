<#
.SYNOPSIS
  Removes custom Desktop Wallpaper and Lockscreen images, and tidies the registry entries for all users, with logging.

.DESCRIPTION
  Reverses the effects of the "Set-DesktopBranding.ps1" script.
  - Deletes copied Wallpaper and Lockscreen files from ProgramData.
  - Removes related registry policy entries.
  - Resets Wallpaper to Windows default.
  - Logs all actions and errors to a file.

.PARAMETER LOCATION
  The same location folder name used in the installation script (under ProgramData).

.EXAMPLE
  .\Uninstall-DesktopBranding.ps1 -Location "Vini"

.AUTHOR
  James Vincent
  October 2025  
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location
)

# Combine $env:ProgramData with the provided $Location
$FullLocation = Join-Path -Path $env:ProgramData -ChildPath $Location

# Define LogFile location
$script:LogFile = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\App-Uninstall-DesktopBranding.log"

# Ensure log directory exists
$logDir = Split-Path $LogFile
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# ==================== LOGGING ====================
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$timestamp] [$Level] $Message"

    # Write to console and file
    switch ($Level) {
        "INFO"  { Write-Host $logLine -ForegroundColor Gray }
        "WARN"  { Write-Warning $Message }
        "ERROR" { Write-Error $Message }
    }

    try {
        Add-Content -Path $script:LogFile -Value $logLine
    } catch {
        Write-Host "Failed to write to log file: $($_.Exception.Message)"
    }
}

function Assert-Admin {
    Write-Log "Checking for administrator privileges..." "INFO"
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script must be run as Administrator." "ERROR"
        throw "This script must be run from an elevated PowerShell session (Run as Administrator)."
    }
    Write-Log "Administrator check passed."
}

function Remove-SystemPolicies {
    Write-Log "Removing system-wide personalisation policies..."
    $basePaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    )
    foreach ($b in $basePaths) {
        if (Test-Path $b) {
            Write-Log "Deleting: $b"
            Remove-Item -Path $b -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-BrandingMaterial {
    Write-Log "Checking contents of $FullLocation for removable branding folders..."

    if (Test-Path $FullLocation) {
        # Define allowed folder names
        $AllowedFolders = @("Lockscreen", "Theme", "Wallpaper")

        # Get all subfolders in $FullLocation
        $SubFolders = Get-ChildItem -Path $FullLocation -Directory -ErrorAction SilentlyContinue

        foreach ($Folder in $SubFolders) {
            if ($AllowedFolders -contains $Folder.Name) {
                Write-Log "Removing folder: $($Folder.FullName)"
                Remove-Item -Path $Folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Deleted: $($Folder.FullName)"
            } else {
                Write-Log "Skipped: $($Folder.FullName) (not in allowed list)" "INFO"
            }
        }
    } else {
        Write-Log "No files found at $FullLocation" "INFO"
    }
}
function Set-DefaultDesktopBackground {
    Write-Log "Configuring Wallpaper"
    $wallpaperPath = "$env:SystemRoot\Web\Wallpaper\Windows\img0.jpg"

    try {
        $policyKey = "Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
        if (-not (Test-Path $policyKey)) {
            New-Item -Path "Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion" -Name "PersonalizationCSP" -Force | Out-Null
            Write-Host "$policyKey not found, Registry location created."
        }
        if (Test-Path $policyKey) {
            New-ItemProperty -Path $policyKey -Name 'DesktopImagePath' -Value $WallpaperPath -PropertyType String -Force | Out-Null
            Write-Log "DesktopImagePath written to $policyKey."
            New-ItemProperty -Path $policyKey -Name 'DesktopImageUrl' -Value $WallpaperPath -PropertyType String -Force | Out-Null
            Write-Log "DesktopImageUrl written to $policyKey."
            New-ItemProperty -Path $policyKey -Name 'DesktopImageStatus' -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Log "DesktopImageStatus written to $policyKey."
        } else {
            Write-Host "$policyKey not found, Registry location created."
            Write-Log "$policyKey not found: $($_.Exception.Message)" "ERROR"
        }
        Write-Log "Default Wallpaper has been applied"
    } catch {
        Write-Log "Error configuring Wallpaper: $($_.Exception.Message)" "ERROR"
    }
}


# --- MAIN ---
try {
    Assert-Admin
    Write-Log "Starting cleanup of wallpaper, lock screen, and Spotlight policies..."
    Remove-SystemPolicies
    Remove-BrandingMaterial
    Write-Log "Cleanup complete. Default Windows settings will apply at next logon."
    Set-DefaultDesktopBackground
    Write-Log "Restored default Wallpaper."
    rundll32.exe user32.dll,UpdatePerUserSystemParameters
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    Write-Log "Closing log."
}