<#
    Script to check the status of defined BIOS settings on Lenovo (2017+) devices, by querying WMI.
    Script will check for entries in the $settinPrefixes variable. Different models/aged devices, typically call them slightly different things!
    Script will then check that the Current Status contains "Enabl" as some report Enable, or Enabled. Due to, as above!

    Can be used as a Remediation within Intune for Detection, or Remediation purposes.

    James Vincent
    July 2026
#>

# Set the variables
# Enter possible password variants. If you enter more than 3 passwords, and none work, you can find yourself in trouble. i.e. Locked out of BIOS.
$BIOSPassword = @(
    "$alm0n",
    "£gg5",
    "G4mmon"
) 

# Enter possible BIOS settings, as kindly defined by Lenovo.
$settingPrefixes = @(
    "Secure Boot",
    "Security Boot",
    "BootyBooty",
    "SecureBoot"
)

# Enter whether you would like to Enable, or Disable the setting. 
# This might need to be Enable/Enabled, or Disable/Disabled.
$settingControl = "Enabled"

######## DO NOT EDIT BELOW ########

# Get matching CurrentSetting entries
try { 
$currentSettings = Get-WmiObject -Class Lenovo_BiosSetting -Namespace root\wmi |
    Where-Object {
        $prefix = $_.CurrentSetting.Split(',')[0].Trim()
        $settingPrefixes -contains $prefix
    } |
    Select-Object -ExpandProperty CurrentSetting    

if (-not $currentSettings -or $currentSettings.Count -eq 0) {
    throw "Defined BIOS setting not found"
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

# Defined setting is found, script will continue.
if ($null -ne $setting) {
    if ($currentValue -eq $settingControl) {
        Write-Host "$setting exists, and is already $currentValue. Aborted."
        exit 1
    }
    else {
        Write-Host "$setting exists, will continue."

        # If no password is supplied, attempt to set the BIOS setting(s) without a password.    
        if(!$BIOSPassword){
            Write-Host "No BIOS password supplied, attempting to enable the defined setting."
            try{
                (Get-WmiObject -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting("$setting,$settingControl")
                (Get-WmiObject -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings()
            }catch{
                Write-Error $_ -ErrorAction Continue
                exit 1
            }
        }else{
            $passwordWorked = $false
            if($BIOSPassword.Count -gt 2){
                Write-Warning "Trying 3 or more passwords could lock you out of the BIOS!"
            }
            foreach($password in $BIOSPassword){
                try{
                    Write-Host "Attempting to set $Setting to $settingControl using BIOS password."
                    (Get-WmiObject -class Lenovo_SetBiosSetting -namespace root\wmi).SetBiosSetting("$setting,$settingControl,$password,ascii,us,$password")
                    (Get-WmiObject -class Lenovo_SaveBiosSettings -namespace root\wmi).SaveBiosSettings("$password,ascii,us")
                    $passwordWorked = $true
                    break
                }catch{
                    Write-Host "Failed: $($_.Exception.Message)."
                }   
            }
            if($passwordWorked -eq $false){
                Write-Error "None of BIOS passwords worked, aborting." -ErrorAction Continue
                exit 1
            }
        }
    Write-Host "$setting was $settingControl"
    exit 0
    }
    else {
        Write-Host "Configuring $setting failed."
        exit 1
    }
}