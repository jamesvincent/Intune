<#
.SYNOPSIS
    Remediation Script to REMOVE unauthorised Local Administrator accounts
    Logs all actions to $env:ProgramData\Microsoft\Logs\Remediate-LocalAdmins.log

.AUTHOR
    James Vincent - October 2025

.DESCRIPTION
    - Identifies all local accounts in the Administrators group
    - Excludes approved accounts (e.g. LAPSAdmin)
    - Removes any remaining local admin accounts
    - Logs all actions and results to a central log file
#>

# Define Log file and location
$LogDir = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogDir "Remediate-LocalAdmins.log"

# Ensure log directory exists
if (!(Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# Create or append to the log file
function Write-Log {
    param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("dd-MM-yyyy HH:mm:ss")
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Output $entry
}

Write-Log "Starting Local Admin Remediation Script"

try {
    # Resolve localised Administrators group name
    $sid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $account = $sid.Translate([System.Security.Principal.NTAccount])
    $accountName = $account.Value
    $parts = $accountName -split '\\'
    $groupName = $parts[1]
    Write-Log "Resolved Administrators group name as '$groupName'."

    # Get members of the local Administrators group
    $adminlist = (net localgroup $groupName) | Where-Object { $_ -match '\S' } | Select-Object -Skip 4 | Select-Object -SkipLast 1

    # Filter to only local accounts (exclude domain)
    $Regexes = '^[^\\]+$'
    $localAdmins = ($adminlist | Select-String -Pattern $Regexes).Line

    # Approved local admin accounts
    $allowedAdmins = @(
        "LAPSAdmin",
        "LAPSadm",
        "James",
        "Vini"
    )

    if ($localAdmins) {
        Write-Log "Found the following local admin accounts: $($localAdmins -join ', ')"

        foreach ($admin in $localAdmins) {
            if ($allowedAdmins -notcontains $admin) {
                try {
                    Write-Log "Attempting to remove unauthorised admin account '$admin'."
                    net localgroup $groupName $admin /delete | Out-Null
                    Write-Log "Successfully removed '$admin'."
                } catch {
                    Write-Log "Failed to remove '$admin': $_" -Level "ERROR"
                }
            } else {
                Write-Log "Skipping approved account '$admin'."
            }
        }
    } else {
        Write-Log "No local administrator accounts found to remediate."
    }
}
catch {
    Write-Log "Unexpected error occurred: $_" -Level "ERROR"
}

Write-Log "Local Admin Remediation Complete"
