# Script that runs in early stages of your Task Sequence to:
# 1. Set the correct time zone and sync time from an internet time source
# 2. Create an OSDStartTime variable for use later in the Task Sequence
# 3. Tattoo the registry with deployment information at the end of the Task Sequence

# James Vincent - November 2025 (Well, this is when I cobbled it all back together)
# With huge thanks to Jorgen Nilsson (https://ccmexec.com/)

# Define the Variables
$YourCompanyName = "YOURCLIENTNAME" #A folder by this name will be created within HKLM\Software
$YourDesiredTZ = "GMT Standard Time" #Set your desired timezone here (Windows TimeZone ID)


# DO NOT MODIFY BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING #
####################################################################


# Map Windows TimeZone IDs to IANA-style short codes for timeapi.io
$TZMap = @{
    "GMT Standard Time" = "Europe/London"
    "UTC"               = "UTC"
    "W. Europe Standard Time" = "Europe/Berlin"
    "Central Europe Standard Time" = "Europe/Budapest"
    "Romance Standard Time" = "Europe/Paris"
    "Eastern Standard Time" = "America/New_York"
    "Pacific Standard Time" = "America/Los_Angeles"
    "Mountain Standard Time" = "America/Denver"
    "China Standard Time" = "Asia/Shanghai"
    "Tokyo Standard Time" = "Asia/Tokyo"
    "AUS Eastern Standard Time" = "Australia/Sydney"
    "New Zealand Standard Time" = "Pacific/Auckland"
}

# If we have a mapping, use it — otherwise default to UTC
$TimeApiZone = if ($TZMap.ContainsKey($YourDesiredTZ)) {
    $TZMap[$YourDesiredTZ]
} else {
    Write-Warning "Timezone '$YourDesiredTZ' not in map. Defaulting to UTC."
    "UTC"
}

# Apply the timezone to the system (in WinPE this may not persist)
Set-TimeZone -Id $YourDesiredTZ

# Get current time from the Internet API
$time = Invoke-RestMethod -Uri "https://timeapi.io/api/Time/current/zone?timeZone=$TimeApiZone"

# Build a PowerShell date object from the API response
$date = Get-Date -Year ($time.year) `
                 -Month ($time.month) `
                 -Day ($time.day) `
                 -Hour ($time.hour) `
                 -Minute ($time.minute) `
                 -Second ($time.seconds)

# Set the local date/time within WinPE
Set-Date $date
 
##VAR: Create the OSDStartTime Variable for use during Tattooing
$OSDStartTime = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
$tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
$tsenv.Value("OSDStartTime") = "$OSDStartTime"
 
##Tattoo Registry
# Name: OSDTattoo
# Authors: Jorgen Nilsson CCMEXEC (https://ccmexec.com/)
# Script to tattoo the registry with deployment variables during OS deploymnet 
$RegKeyName = "$YourCompanyName"
 
# Set values
$tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
$FullRegKeyName = "HKLM:\SOFTWARE\" + $RegKeyName
 
# Create Registry key
New-Item -Path $FullRegKeyName -type Directory -Force -ErrorAction SilentlyContinue
 
# Get values
$InstallTime = Get-Date -Format G 
$OSDStartTime = $tsenv.Value("OSDStartTime")
$AdvertisementID = $tsenv.Value("_SMSTSAdvertID")
$Organisation = $tsenv.value("_SMSTSOrgName")
$TaskSequenceID = $tsenv.value("_SMSTSPackageID")
$Packagename = $tsenv.value("_SMSTSPackageName")
$MachineName = $env:computername
$Installationmode = $tsenv.value("_SMSTSLaunchMode")
 
#Calculate time elapsed
$OSDTImeSpan = New-TimeSpan -start $OSDstartTime -end $installtime
$OSDDuration = "{0:hh}:{0:mm}:{0:ss}" -f $OSDTimeSpan
 
# Write values
new-itemproperty $FullRegKeyName -Name "Advertisement ID" -Value $AdvertisementID -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "Computername" -Value $MachineName -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "Installation Type" -Value $Installationmode -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "Organisation Name" -Value $Organisation -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "OS Version" -value (Get-CimInstance Win32_Operatingsystem).version -PropertyType String -Force | Out-Null
new-itemproperty $FullRegKeyName -Name "OSD Begin Time" -Value $OSDStartTime -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "OSD Completed Time" -Value $InstallTime -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "OSD Duration" -Value $OSDDuration -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "Task Sequence ID" -Value $TaskSequenceID -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
new-itemproperty $FullRegKeyName -Name "Task Sequence Name" -Value $Packagename -Type STRING -Force -ErrorAction SilentlyContinue | Out-Null
