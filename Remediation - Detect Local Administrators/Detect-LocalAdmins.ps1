<#
.SYNOPSIS
    Detection Script for unauthorised Local Administrator accounts
    Companion to "Remediate-LocalAdmins.ps1"

.AUTHOR
    James Vincent - October 2025

.DESCRIPTION
    - Identifies all local accounts in the Administrators group
    - Excludes known/approved accounts (e.g. LAPSAdmin)
    - If any unauthorised accounts exist, outputs them for Intune detection
#>

# Translate localised Administrators group name using its SID
$sid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$account = $sid.Translate([System.Security.Principal.NTAccount])
$accountName = $account.Value
$parts = $accountName -split '\\'
$groupName = $parts[1]

# Get members of the local Administrators group
$adminlist = (net localgroup $groupName) | Where-Object { $_ -match '\S' } | Select-Object -Skip 4 | Select-Object -SkipLast 1

# Filter to only local accounts (exclude domain users)
$Regexes = '^[^\\]+$'
$localAdmins = ($adminlist | Select-String -Pattern $Regexes).Line

# Approved local admin accounts
$allowedAdmins = @(
    "LAPSAdmin",
    "LAPSadm",
    "James",
    "Vini"
)

# Filter out approved accounts
$unauthorisedAdmins = $localAdmins | Where-Object { $allowedAdmins -notcontains $_ }

# Define Log file and location
$LogDir = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogDir "Remediate-LocalAdmins.log"

# Ensure log directory exists
if (!(Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# Write logging function
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("dd-MM-yyyy HH:mm:ss")
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Output $entry
}

Write-Log "Starting Local Admin Detection Script"

if ($unauthorisedAdmins) {
    Write-Log "Unauthorised Local Admins found: $($unauthorisedAdmins -join ', ')"
    Write-Output "Unauthorised Local Admins found:"
    Write-Output "$($unauthorisedAdmins -join ', ')"
    exit 1  # Non-compliant, triggers remediation
} else {
    Write-Log "No unauthorised Local Admin accounts found."
    Write-Output "Compliant - No unauthorised Local Admin accounts found."
    exit 0  # Compliant
}

Write-Log "Local Admin Detection Complete"