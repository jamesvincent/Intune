<#
.SYNOPSIS
  Configure Desktop Wallpaper and Lockscreen image for all users with logging.

.DESCRIPTION
  Copies branding material down to the local device and iterates through every user profile on a Windows system
  setting the Desktop Wallpaper and Lockscreen image, and logs all actions to the Intune log directory.

.EXAMPLE 
  .\Set-DesktopBranding.ps1 -Location "Vini" -WallpaperImg "DesktopWallpaper.jpg" -LockscreenImg "LockImg.png" -Style "Stretch"

  !! IMPORTANT!! If using Intune, the Install Command is recommended to be as follows, to ensure that the WOW6432NODE is not referenced;
  %SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File .\Set-DesktopBranding.ps1 -Location "Vini"

.PARAMETER LOCATION
  This variable sets the landing zone under $env:ProgramData, this would be your company name or "EUC" or similar.

.PARAMETER WALLPAPERIMG
  This is the filename of the Desktop Wallpaper image that is saved into .\Wallpaper\

.PARAMETER LOCKSCREENIMG
  This is the filename of the Lockscreen Image image that is saved into .\Lockscreen\

.PARAMETER STYLE
  This is the Wallpaper style. Fill is default if not referenced.

.PARAMETER TILE
  If -Tile is referenced during the runtime, the Wallpaper will be configured to Tile. Probably not required in this day and age.

.LOG LOCATION
  $env:ProgramData\Microsoft\IntuneManagementExtension\Logs\App-Install-DesktopBranding.log
  Logging to this location allows the use of Collect Diagnostics within Intune to gather the log file.

.NOTES
  A Theme file is also copied to the relevant directory on the device if included. The use and assignment of Theme is not automated with this script.
  Creation of a Theme file needs to occur outside of this process.

.AUTHOR
  James Vincent
  October 2025
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location,
    [string]$WallpaperImg = "wallpaper.jpg",
    [string]$LockscreenImg = "lockscreen.jpg",
    [ValidateSet('Fill','Fit','Stretch','Center','Span')]
    [string]$Style = "Fill",
    [switch]$Tile
)

# === GLOBAL VARIABLES ===
$script:FullLocation   = Join-Path -Path $env:ProgramData -ChildPath "$($Location)"
$script:WallpaperPath  = Join-Path $FullLocation "Wallpaper\$WallpaperImg"
$script:LockscreenPath = Join-Path $FullLocation "Lockscreen\$LockscreenImg"
$script:StyleVals      = $null
$script:LogFile        = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\App-Install-DesktopBranding.log"

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

# ==================== FUNCTIONS ====================

function Assert-Admin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Script must be run as Administrator." "ERROR"
        throw "This script must be run from an elevated PowerShell session."
    }
    Write-Log "Confirmed running with Administrator privileges."
}

function Get-StyleValues {
    param([string]$Style,[switch]$TileSwitch)
    $map = @{
        'Center'  = @{ WallpaperStyle = 0;  TileWallpaper = 0 }
        'Stretch' = @{ WallpaperStyle = 2;  TileWallpaper = 0 }
        'Fit'     = @{ WallpaperStyle = 6;  TileWallpaper = 0 }
        'Fill'    = @{ WallpaperStyle = 10; TileWallpaper = 0 }
        'Span'    = @{ WallpaperStyle = 22; TileWallpaper = 0 }
    }
    $vals = $map[$Style].Clone()
    if ($TileSwitch) { $vals.TileWallpaper = 1 }
    Write-Log "Style set to '$Style' (WallpaperStyle=$($vals.WallpaperStyle), Tile=$($vals.TileWallpaper))."
    return $vals
}

function Get-TargetProfiles {
    Write-Log "Enumerating user profiles..."
    $profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    Get-ChildItem $profileListKey | ForEach-Object {
        $sid = $_.PSChildName
        $profilePath = (Get-ItemProperty -Path $_.PsPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath) { return }

        $name = Split-Path $profilePath -Leaf
        $excludeNames = @('Default','Default User','All Users','Public','defaultuser0')
        if ($excludeNames -contains $name) { return }
        if ($sid -match '^S-1-5-(18|19|20)') { return }

        if (Test-Path $profilePath) {
            Write-Log "Found user profile: $name ($sid)"
            [PSCustomObject]@{
                SID         = $sid
                ProfilePath = $profilePath
            }
        }
    }
}

function Copy-BrandingMaterial {
    Write-Log "Ensuring branding materials exist at $FullLocation..."
    if (-Not (Test-Path $FullLocation)) {
        Write-Log "Specified location not found: $FullLocation. Creating it..." "WARN"
        New-Item -ItemType Directory -Path $FullLocation -Force | Out-Null
    }

    $dirs = @("$FullLocation\Wallpaper", "$FullLocation\Lockscreen", "$FullLocation\Theme")
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Log "Created directory: $d"
        }
    }

    foreach ($ext in 'jpeg','jpg','png','bmp','gif') {
        xcopy ".\Wallpaper\*.$ext" "$FullLocation\Wallpaper\" /Y /I | Out-Null
        xcopy ".\Lockscreen\*.$ext" "$FullLocation\Lockscreen\" /Y /I | Out-Null
    }
    xcopy ".\Theme\*.theme" "$FullLocation\Theme\" /Y /I | Out-Null

    Write-Log "Branding materials copied successfully."
}

function Set-DesktopBackground {
    param([string]$HiveRoot)
    Write-Log "Configuring wallpaper and lock screen for hive: $HiveRoot"

    try {
        $desktopKey = "Registry::$HiveRoot\Control Panel\Desktop"
        if (-not (Test-Path $desktopKey)) {
            New-Item -Path "Registry::$HiveRoot\Control Panel" -Name "Desktop" -Force | Out-Null
            Write-Log "$desktopKey not found, Registry location created."
        }

        New-ItemProperty -Path $desktopKey -Name 'Wallpaper' -Value $WallpaperPath -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $desktopKey -Name 'WallpaperStyle' -Value $StyleVals.WallpaperStyle -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $desktopKey -Name 'TileWallpaper' -Value $StyleVals.TileWallpaper -PropertyType String -Force | Out-Null
        Write-Log "Wallpaper written to $desktopKey."
        Write-Log "WallpaperStyle $($StyleVals.WallpaperStyle) written to $desktopKey."
        Write-Log "TileWallpaper $($StyleVals.TileWallpaper) written to $desktopKey."

        Write-Log "Desktop Wallpaper and applied for hive $HiveRoot."
    } catch {
        Write-Log "Error configuring hive $($HiveRoot): $($_.Exception.Message)" "ERROR"
    }
}

function Set-Lockscreen {
    Write-Log "Configuring Lockscreen for the device."

    try {
        $policyKey = "Registry::HKLM\Software\Policies\Microsoft\Windows\Personalization"
        if (-not (Test-Path $policyKey)) {
            New-Item -Path "Registry::HKLM\Software\Policies\Microsoft\Windows" -Name "Personalization" -Force | Out-Null
            Write-Log "$policyKey not found, Registry location created."
        }
        New-ItemProperty -Path $policyKey -Name 'LockScreenImage' -Value $LockscreenPath -PropertyType String -Force | Out-Null
        Write-Log "LockScreenImage written to $policyKey."

        $policyKey1 = "Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
        if (-not (Test-Path $policyKey1)) {
            New-Item -Path "Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion" -Name "PersonalizationCSP" -Force | Out-Null
            Write-Host "$policyKey1 not found, Registry location created."
        }
        if (Test-Path $policyKey1) {
            New-ItemProperty -Path $policyKey1 -Name 'LockScreenImagePath' -Value $LockscreenPath -PropertyType String -Force | Out-Null
            Write-Log "LockScreenImagePath written to $policyKey1."
            New-ItemProperty -Path $policyKey1 -Name 'LockScreenImageUrl' -Value $LockscreenPath -PropertyType String -Force | Out-Null
            Write-Log "LockScreenImageUrl written to $policyKey1.."
            New-ItemProperty -Path $policyKey1 -Name 'LockScreenImageStatus' -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Log "LockScreenImageStatus written to $policyKey1."
        } else {
            Write-Host "$policyKey1 not found, Registry location created."
            Write-Log "$policyKey1 not found: $($_.Exception.Message)" "ERROR"
        }
        Write-Log "Lockscreen has been applied"
    } catch {
        Write-Log "Error configuring Lockscreen: $($_.Exception.Message)" "ERROR"
    }
}

function Update-AllProfiles {
    Write-Log "Starting to update all user profiles..."
    $profiles = Get-TargetProfiles
    foreach ($p in $profiles) {
        $sid = $p.SID
        $profileNtuser = Join-Path $p.ProfilePath 'NTUSER.DAT'
        $loadedHive = "HKEY_USERS\$sid"
        $tempHive   = "HKEY_USERS\Temp_$($sid.Replace('-','_'))"

        try {
            if (Test-Path "Registry::$loadedHive") {
                Write-Log "Profile $sid hive is loaded; applying settings."
                Set-DesktopBackground -HiveRoot $loadedHive
            }
            elseif (Test-Path $profileNtuser) {
                Write-Log "Temporarily loading hive for profile $sid."
                & reg.exe load "$tempHive" "$profileNtuser" | Out-Null
                try {
                    Set-DesktopBackground -HiveRoot $tempHive
                }
                finally {
                    & reg.exe unload "$tempHive" | Out-Null
                    Write-Log "Unloaded temporary hive for $sid."
                }
            }
        }
        catch {
            Write-Log "Error updating profile $($sid): $($_.Exception.Message)" "ERROR"
        }
    }
}

# ==================== MAIN ====================
try {
    Write-Log "=== Script started ==="
    Assert-Admin
    Copy-BrandingMaterial
    $script:StyleVals = Get-StyleValues -Style $Style -TileSwitch:$Tile

    Write-Log "Applying Wallpaper and Lockscreen settings..."
    Set-Lockscreen
    Update-AllProfiles
    RUNDLL32.EXE user32.dll, UpdatePerUserSystemParameters ,1 ,True
    Write-Log "Completed applying settings. They will take effect at next logon."
    Write-Log "=== Script completed successfully ==="
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}