<#
    Script to check the status of Secure Boot on Lenovo (2017+) devices, by querying WMI.
    Script will check for "SecureBoot" and "Secure Boot" variations.
    Script will then check that the Current Status contains "Enabl" as some report Enable, or Enabled.

    Can be used as a Remediation within Intune

    James Vincent
    July 2026
#>

# Define the setting prefixes to match
$settingPrefixes = @(
    "SecureBoot",
    "Secure Boot"
)

# Get matching CurrentSetting entries
try { 
$currentSettings = Get-WmiObject -Class Lenovo_BiosSetting -Namespace root\wmi |
    Where-Object {
        $prefix = $_.CurrentSetting.Split(',')[0].Trim()
        $settingPrefixes -contains $prefix
    } |
    Select-Object -ExpandProperty CurrentSetting    

if (-not $currentSettings -or $currentSettings.Count -eq 0) {
    throw "Preboot Authentication setting not found"
}

    # Whole string: e.g., "SecureBoot,Enabled" or "Secure Boot,Enable"
    $BIOSSetting = $currentSettings

    # Trim the string first, then split on the FIRST comma only
    $parts = $BIOSSetting.Trim() -split ',', 2

    # Get the BIOS Setting, and it's current value - neatly.
    $setting = $parts[0].Trim()
    $currentValue  = ($parts[1] -split ';')[0].Trim()  # Strip anything after semicolon
}
catch {
    Write-Host $_
    Write-Host "NonCompliant"
    exit 1
}

# Check if value is "Enable" or "Enabled" (case-insensitive)
if ($currentValue -ieq "Enable" -or $currentValue -ieq "Enabled") {
    Write-Host "Compliant"
    exit 0
} else {
    Write-Host "NonCompliant"
    exit 1
}