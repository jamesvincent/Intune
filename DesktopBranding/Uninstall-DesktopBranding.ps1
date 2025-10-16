<#
.SYNOPSIS
  Removes custom Desktop Wallpaper and Lockscreen images, and tidies the registry entries for all users, with logging.

.DESCRIPTION
  Reverses the effects of the "Set-DesktopBranding.ps1" script.
  - Deletes copied Wallpaper and Lockscreen files from ProgramData.
  - Removes related registry policy entries.
  - Resets user Wallpaper to Windows default.
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

function Get-TargetProfiles {
    Write-Log "Enumerating user profiles..." "INFO"
    $profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    Get-ChildItem $profileListKey | ForEach-Object {
        $sid = $_.PSChildName
        $profilePath = (Get-ItemProperty -Path $_.PsPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath) { return }

        $name = Split-Path $profilePath -Leaf
        $excludeNames = @('Default','Default User','All Users','Public','defaultuser0')
        if ($excludeNames -contains $name) { return }

        if ($sid -match '^S-1-5-(18|19|20)') { return } # system/service accounts

        if (Test-Path $profilePath) {
            Write-Log "Found profile: $name ($sid)" "INFO"
            [PSCustomObject]@{
                SID         = $sid
                ProfilePath = $profilePath
            }
        }
    }
}

function Remove-WallpaperAndLockSettings {
    param([string]$HiveRoot)
    Write-Log "Cleaning wallpaper and lock screen settings for $HiveRoot..."

    $desktopKey = "Registry::$HiveRoot\Control Panel\Desktop"
    if (Test-Path $desktopKey) {
        Write-Log "Removing Wallpaper registry properties..."
        Remove-ItemProperty -Path $desktopKey -Name 'Wallpaper' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $desktopKey -Name 'WallpaperStyle' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $desktopKey -Name 'TileWallpaper' -ErrorAction SilentlyContinue
    }

    $policyKeys = @(
        "Registry::HKLM\Software\Policies\Microsoft\Windows\Personalization",
        "Registry::HKLM\Software\Policies\Microsoft\Windows\PersonalizationCSP"
    )
    foreach ($key in $policyKeys) {
        if (Test-Path $key) {
            Write-Log "Removing policy key: $key"
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # $contentKey = "Registry::$HiveRoot\Software\Policies\Microsoft\Windows\CloudContent"
    # if (Test-Path $contentKey) {
    #     Write-Log "Removing CloudContent key to re-enable Windows Spotlight."
    #     Remove-Item -Path $contentKey -Recurse -Force -ErrorAction SilentlyContinue
    # }

    if (Test-Path $desktopKey) {
        Write-Log "Restoring default wallpaper registry values..."
        New-ItemProperty -Path $desktopKey -Name 'Wallpaper' -Value "$env:SystemRoot\Web\Wallpaper\Windows\img0.jpg" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $desktopKey -Name 'WallpaperStyle' -Value 10 -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $desktopKey -Name 'TileWallpaper' -Value 0 -PropertyType String -Force | Out-Null
    }
}

function Update-AllProfiles {
    Write-Log "Starting per-user profile cleanup..."
    $profiles = Get-TargetProfiles
    foreach ($p in $profiles) {
        $sid = $p.SID
        $profileNtuser = Join-Path $p.ProfilePath 'NTUSER.DAT'
        $loadedHive = "HKEY_USERS\$sid"
        $tempHive   = "HKEY_USERS\Temp_$($sid.Replace('-','_'))"

        try {
            if (Test-Path "Registry::$loadedHive") {
                Write-Log "Cleaning loaded hive: $sid"
                Remove-WallpaperAndLockSettings -HiveRoot $loadedHive
            }
            elseif (Test-Path $profileNtuser) {
                Write-Log "Temporarily loading hive for $sid"
                & reg.exe load "$tempHive" "$profileNtuser" | Out-Null
                try {
                    Remove-WallpaperAndLockSettings -HiveRoot $tempHive
                }
                finally {
                    & reg.exe unload "$tempHive" | Out-Null
                    Write-Log "Unloaded hive for $sid"
                }
            }
        }
        catch {
            Write-Log "Error cleaning profile $($sid): $($_.Exception.Message)" "ERROR"
        }
    }
}

function Remove-SystemPolicies {
    Write-Log "Removing system-wide personalization policies..."
    $basePaths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PersonalizationCSP',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    )
    foreach ($b in $basePaths) {
        if (Test-Path $b) {
            Write-Log "Deleting: $b"
            Remove-Item -Path $b -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # This doesn't work due to permissions, so might need editing manually. 
    # This key might create a delay in old Lockscreen images appearing due to cacheing.
    # This key should update itself manually if another Lockscreen image is applied.
    # Take ownership and delete if problems arise.
    # $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SystemProtectedUserData\S-1-5-18\AnyoneRead\LockScreen"

    # if (Test-Path $RegPath) {
    #     Write-Log "Registry path found ($RegPath). Taking ownership and removing..."
    #     $acl = Get-Acl $RegPath
    #     $acl.SetOwner([System.Security.Principal.NTAccount]"Administrators")
    #     Set-Acl -Path $RegPath -AclObject $acl
    #     icacls "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SystemProtectedUserData\S-1-5-18\AnyoneRead\LockScreen" /grant Administrators:F /t /c | Out-Null
    #     Remove-Item -Path $RegPath -Recurse -Force
    #     Write-Log "Key successfully removed."
    # } else {
    #     Write-Log "Registry path not found, nothing to remove." "INFO"
    # }
}

function Remove-Files {
    Write-Log "Removing branding files from $FullLocation..."
    if (Test-Path $FullLocation) {
        Remove-Item -Path $FullLocation -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Deleted: $FullLocation"
    } else {
        Write-Log "No files found at $FullLocation" "INFO"
    }
}

# --- MAIN ---
try {
    Assert-Admin
    Write-Log "Starting cleanup of wallpaper, lock screen, and Spotlight policies..."
    Update-AllProfiles
    Remove-SystemPolicies
    Remove-Files
    rundll32.exe user32.dll, UpdatePerUserSystemParameters
    Write-Log "Cleanup complete. Default Windows settings will apply at next logon."

    $wallpaperPath = "$env:SystemRoot\Web\Wallpaper\Windows\img0.jpg"
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name wallpaper -Value $wallpaperPath
    rundll32.exe user32.dll,UpdatePerUserSystemParameters
    Write-Log "Restored default wallpaper for current user."

} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    Write-Log "Closing log."
}