<#
.SYNOPSIS
	Batch update Intune device category and/or Primary User
    Batch update ownership to corporate.
	Batch update Intune device using an input file or using a naming prefix
	or direct via the -ComputerName, -CategoryName, and/or -UserName parameter(s).
.PARAMETER ComputerName
	Name of one or more computers
.PARAMETER IntputFile
	Path and name of .CSV input file
	CSV file must have a column named "ComputerName"
    Must have column named "UserName" if CSV is used also for Primary User.
.PARAMETER SetCategory
    True/False value to determine whether the device category is being set.
.PARAMETER CategoryName
	A valid category name. If the name does not exist in the
	Intune subscription, it will return an error.
    Required is SetCategory is $True.
.PARAMETER SetPrimaryUser
    True/False value to determine whether the Primary User is being set.
.PARAMETER LastLogonUser
    True/False value whether to use the last logon user as Primary User.
.PARAMETER UserName
    Name of one or more users. Required if SetPrimaryUser is $True.
    Cannot be used with LastLogonUser
    Can be provided in .CSV
.PARAMETER ComputerPrefix
    Specify the prefix of computer names to set category
    Cannot be used with InputFile nor ComputerName
.EXAMPLE
    Requires -InputFile or -ComputerName parameters.

    .\Set-DeviceProperties.ps1 -ComputerName COMPUTER-12345 -SetPrimaryUser $True -UserName jmarcum@systemcenteradmin.com -SetOwner $True -Owner Company -SetCategory $False -SetLastLoggonUser $False
    .\Set-DeviceProperties.ps1 -ComputerName COMPUTER-12345 -SetPrimaryUser $True -UserName jmarcum@systemcenteradmin.com -SetOwner $True -Owner Company
    .\Set-DeviceProperties.ps1 -ComputerName COMPUTER-12345 -LastLogonUser $True -SetCategory $True -CategoryName Accounting
    .\Set-DeviceProperties.ps1 -ComputerName IT-JVTESTVM01 -SetPrimaryUser $True -LastLogonUser $True
    .\Set-DeviceProperties.ps1 -ComputerName IT-JVTESTVM01 -SetPrimaryUser $True -UserName jmarcum@systemcenteradmin.com
    .\Set-DeviceProperties.ps1 -InputFile "C:\Temp\Set-DeviceProperties.csv" -SetPrimaryUser $True

.NOTES
    Requires modules AzureADPreview,Microsoft.Graph.Intune,Microsoft.Graph

	7.0	3-21-2023	John Marcum - csv import and last logged on user tested and confirmed to work.
    	9.0	3-22-2024	John Marcum - Fixed bugs, added tons of logging, added ability to use Intune Device ID instead of computer name.
    	10.1	3-25-2024	John Marcum - Fix bugs reported by James Vincent @LinkedIn [https://www.linkedin.com/in/jddvincent/]
    	11.0	3-28-2024	James Vincent - Refactored some sections, changes mostly made to Host outputs. Added some error checking.
#>

[CmdletBinding()]
param (
    [string]$ComputerName = "",
    [string]$IntuneID = "",
    [string]$ComputerPrefix = "",
    [string]$InputFile = "",
    [bool]$SetCategory = $False,
    [string]$CategoryName = "",
    [bool]$SetPrimaryUser = $False,
    [bool]$LastLogonUser = $False,    
    [string]$UserName = "",
    [bool]$SetOwner = $False,
    [ValidateSet("Company", "Personal")][string]$Owner = "Company"
)

######## Begin Functions ########

####################################################

# Check for required modules, install if not present
function Assert-ModuleExists([string]$ModuleName) {
    $module = Get-Module $ModuleName -ListAvailable -ErrorAction SilentlyContinue
    if (!$module) {
        Write-Host "Installing module $ModuleName ..."
        Install-Module -Name $ModuleName -Force -Scope Allusers
        Write-Host "Module installed"
    }    
}

####################################################

# Get device info from Intune
function Get-DeviceInfo {
    [CmdletBinding()]
    param (
        [parameter(Mandatory)][string] $Computername
    )
    Get-IntuneManagedDevice -Filter "Startswith(DeviceName, '$Computername') and operatingSystem eq 'Windows'" -Top 1000 `
    | Get-MSGraphAllPages `
    | Select-Object DeviceName, UserPrincipalName, id, userId, DeviceCategoryDisplayName, ManagedDeviceOwnerType, chassisType, usersLoggedOn
}

# Get device info from Intune
function Get-DeviceInfoByID {
    [CmdletBinding()]
    param (
        [parameter(Mandatory)][string] $managedDeviceId
    )
    Get-IntuneManagedDevice -managedDeviceId $IntuneID `
    | Select-Object DeviceName, UserPrincipalName, id, userId, DeviceCategoryDisplayName, ManagedDeviceOwnerType, chassisType, usersLoggedOn
}

####################################################

# Set the device categories
function Set-DeviceCategory {
    [CmdletBinding()]
    param (
        [parameter(Mandatory)][string] $DeviceID,
        [parameter(Mandatory)][string] $CategoryID
    )
    Write-Host "Updating device category for $Computer"
    $requestBody = @{
        "@odata.id" = "$baseUrl/deviceManagement/deviceCategories/$CategoryID" # $CategoryName
    }
    $url = "$baseUrl/deviceManagement/managedDevices/$DeviceID/deviceCategory/`$ref"
    Write-Host "request-url: $url"
        
    $null = Invoke-MSGraphRequest -HttpMethod PUT -Url $url -Content $requestBody
    Write-Host "Device category for $Computer updated"
}
        
####################################################

# Set the device ownership
function Set-Owner {
    [CmdletBinding()]
    param (
        [parameter(Mandatory)][string] $DeviceID,
        [parameter(Mandatory)][string] $Owner       
    )
    Write-Host "Updating owner for $Computer"

    $JSON = @"
{
ownerType:"$Owner"
}
"@

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$deviceId')"
    Invoke-MSGraphRequest -Url $uri -HttpMethod PATCH -Content $Json
}
        
####################################################

# Get Intune Primary User
function Get-IntuneDevicePrimaryUser {

    [CmdletBinding()]
    param (
        [parameter(Mandatory)][string] $DeviceID   
    )
     
    $graphApiVersion = "beta"
    $Resource = "deviceManagement/managedDevices"
    $uri = "https://graph.microsoft.com/$graphApiVersion/$($Resource)" + "/" + $deviceId + "/users"

    try {
        
        $primaryUser = Invoke-MSGraphRequest -Url $uri -HTTPMethod Get

        return $primaryUser.value."id"
        
    }
    catch {
        $ex = $_.Exception
        $errorResponse = $ex.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorResponse)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEND();
        Write-Host "Response content:`n$responseBody" -f Red
        Write-Error "Request to $Uri failed with HTTP Status $($ex.Response.StatusCode) $($ex.Response.StatusDescription)"
        throw "Get-IntuneDevicePrimaryUser error"
    }
        
}

####################################################

# Set the Intune Primary User
function Set-IntuneDevicePrimaryUser {
    [cmdletbinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $DeviceId,
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $userId
    )

    $graphApiVersion = "beta"
    $Resource = "deviceManagement/managedDevices('$DeviceId')/users/`$ref"     

    $uri = "https://graph.microsoft.com/$graphApiVersion/$($Resource)"
    $userUri = "https://graph.microsoft.com/$graphApiVersion/users/" + $userId

    $JSON = @"

{"@odata.id":"$userUri"}

"@

    Invoke-MSGraphRequest -HttpMethod POST -Url $uri -Content $JSON  
}

####################################################

# Set the Primary User of the device to the last logged on user if it they are not already the same user
function Set-LastLogon {    
        
    #Check if there is a Primary User set on the device already
    $IntuneDevicePrimaryUser = Get-IntuneDevicePrimaryUser -deviceId $DeviceID
    if (!($IntuneDevicePrimaryUser)) {
        Write-Host "No Intune Primary User Id set for Intune Managed Device" $Device.deviceName
    }
    else {
        #  A Primary User is there already. Find out who it is. 
        $PrimaryAADUser = Get-AzureADUser -ObjectId $IntuneDevicePrimaryUser
    }
   
    # Using the objectID of the last logged on user, get the user info from Microsoft Graph for logging purposes
    $LastLoggedOnAdUser = Get-AzureADUser -ObjectId $LastLoggedOnUser
    #Write-Host "Matched the last logged on user id:" $LastLoggedOnUser "to the AAD user info:" $LastLoggedOnAdUser.Objectid 
    #Write-Host "Last logged on user name is:"  $LastLoggedOnAdUser.UserPrincipalName

    #Check if the current Primary User of the device is the same as the last logged in user
    if ($IntuneDevicePrimaryUser -ne $LastLoggedOnUser) {
        #If the user does not match, then set the last logged in user as the new Primary User
        Write-Host $Device.deviceName "has a Primary User which that is NOT the last logged on user"
        Write-Host "Will update the Primary User on" $Device.deviceName "to" $LastLoggedOnAdUser.displayName
        Set-IntuneDevicePrimaryUser -DeviceId $DeviceID -userId $LastLoggedOnUser

        # Get the Primary User to see if that worked.
        $Result = Get-IntuneDevicePrimaryUser -deviceId $DeviceID
        if ($Result -eq $LastLoggedOnUser) {
            Write-Host "User" $LastLoggedOnAdUser.displayName "successfully set as Primary User for device" $Device.deviceName
        }
        else {
            #If the result does not match the expecation something did not work right
            Write-Host "Failed to set as Primary User for device" $Device.deviceName
        }
    }
    else {
        #write-host "Last logged on user:" $LastLoggedOnAdUser.displayName "matches the current Primary User"  
        write-host "No modifications required for" $Device.deviceName
    }

}

####################################################

######## *** END *** Functions ########

######## Script Entry Point ########
# Start logging
$Today = Get-Date -Format "ddMMyyyy_HHmm"
$LogPath = "$env:Temp\Set-DeviceProperties-" + $Today + ".log"
Start-Transcript $LogPath
Write-Host "Script started."

# Check if either InputFile or ComputerName variable is empty
if ([string]::IsNullOrEmpty($InputFile) -and [string]::IsNullOrEmpty($ComputerName)) {
    Write-Error "InputFile or ComputerName variable is empty. Please ensure one parameter is used."
    Stop-Transcript
    exit 1
}

if (-not [string]::IsNullOrEmpty($ComputerName) -or ($SetPrimaryUser -eq $True)) {
    if ([string]::IsNullOrEmpty($UserName)) {
        if ($LastLogonUser -eq $False) {
        Write-Error "No UserName was supplied and the LastLogonUser is not set to $True."
        Stop-Transcript
        exit 1
        }
    }
}

if (($UserName) -and ($SetPrimaryUser -eq $False) -or ($LastLogonUser -eq $False)) {
    Write-Warning "A UserName was supplied, but SetPrimaryUser was not defined (Default = False). The Primary User will not be set."
    Stop-Transcript
    exit 1
}

# Install required modules
if ($SetPrimaryUser) {
    Assert-ModuleExists -ModuleName "AzureADPreview"
}
Assert-ModuleExists -ModuleName "Microsoft.Graph.Intune"
Assert-ModuleExists -ModuleName "MSGraph"

# Import modules
if ($SetPrimaryUser) {
    Import-Module "AzureADPreview"
}
Import-Module "Microsoft.Graph.Intune"
Import-Module "MSGraph"

# Connect to Azure to get user ID's
if ($SetPrimaryUser) {
    Write-Host "Connecting to AzureAD"
    if (!($azconn)) { 
        $azconn = Connect-AzureAD
        Write-Host "Connected to $azconn.TenantDomain"
    }
}

# Connect to Graph API
Write-Host "Connecting to MSGraph"
[string]$baseUrl = "https://graph.microsoft.com/beta"
if (!($GraphCon)) {
    $GraphCon = Connect-MSGraph
}
Update-MSGraphEnvironment -SchemaVersion beta

# Get the computers that we want to work on
if (($ComputerPrefix) -and ($InputFile)) {
    $Msg = @'
Prefix And InputFile Cannot
    Used Together!
        EXITING!
'@
    [System.Windows.MessageBox]::Show($Msg, 'Error!', 'Ok', 'Error')
    # Exit 1
}

if ([string]::IsNullOrEmpty($ComputerName)) {
    if ($InputFile) {
        Write-Host "Evaluating Primary User" -ForegroundColor Green
        Write-Host "The ComputerName parameter was not used, checking for CSV input file"
        if (-not(Test-Path $InputFile)) {
            throw "File not found: $InputFile"
        }
        else {
            if ($InputFile.ENDsWith(".csv")) {
                [array]$computers = Import-Csv -Path $InputFile | Select-Object ComputerName, UserName, IntuneID
                Write-Host "Found $($Computers.Count) devices in file"             

            }
            else {
                throw "Only .csv files are supported"
            }
        }
    } 
    if ($ComputerPrefix) {
        Write-Host "Getting computers with the prefix from Intune"
        # Confirm that you really want to run against all computers!
        $Msg = @'
        Selecting all devices with prefix!
        ARE YOU SURE YOU WANT TO DO THIS?
        THIS HAS POTENTIAL TO DO DAMAGE! 
'@
        $Result = [System.Windows.MessageBox]::Show($Msg, 'CAUTION!', 'YesNo', 'Warning')
        Write-Host "Your choice is $Result"
        if ($Result -eq 'No') {
            throw 'Exiting to prevent a disater!'
            Exit 1
        }
        $Computers = Get-MgDeviceManagementManagedDevice -Filter "Startswith(DeviceName, '$ComputerPrefix') and operatingSystem eq 'Windows'" -Top 1000 | Get-MSGraphAllPages | Select-Object DeviceName, UserPrincipalName, id, userId, DeviceCategoryDisplayName, ManagedDeviceOwnerType
        Write-Host "Found $($Computers.Count) devices in Intune"
   
    }
}
else {
    Write-Host "Computer name(s) provided via command line, ignoring CSV."
    $Computers = $ComputerName -split ','
    Write-Host "Will update the following device(s): $Computers"
    Write-Host ""
}

# Set Device Category
if ($SetCategory -ne $False) {
    Write-host "Evaluating Device Category" -ForegroundColor Green 
    # Get the categories from Intune so we have the ID
    Write-Host "Getting List of Categories from Intune"
    $Categories = Get-DeviceManagement_DeviceCategories
    $CatNames = $Categories.DisplayName
    Write-host "Found $($Categories.Count) Categories in Intune"  
        
    if ($null -ne $CategoryName) {
        # Validate category name is valid        
        Write-Host "Validating requested category: $CategoryName"
        $Category = $Categories | Where-Object { $_.displayName -eq $CategoryName }
        if (!($Category)) { 
            Write-Warning  "Category name $CategoryName not valid" 
        }
        $CategoryID = $Category.id
        Write-Host "$CategoryName is $CategoryID"
    }
    else {
        Write-Warning  "No category name specified"
       
    } 

    # Set the device categories
    foreach ($Computer in $Computers) {
        if ($InputFile) {
            $ComputerName = $Computer.ComputerName
            $IntuneID = $Computer.IntuneID
        }         
                            
        If ($ComputerName) {
            $Device = Get-DeviceInfo -ComputerName $ComputerName

            Write-Host "Found $ComputerName in Intune"
            if (!($device)) {
                Write-Warning "$ComputerName not found in Intune."
            }
            else {
                $DeviceID = $Device.id
                if ($Device.deviceCategoryDisplayName -ne $CategoryName) {
                    Write-Progress -Status "Updating Device Category" -Activity "$computer ($deviceId) --> $($device.deviceCategoryDisplayName)"
                    Write-Host "Device Name = $Computer"
                    Write-Host "Device ID = $DeviceID"
                    Write-Host "Current category is $($Device.deviceCategoryDisplayName)"
                    Write-Host "Setting category to $CategoryName"
                    Set-DeviceCategory -DeviceID $DeviceID -category $CategoryID
                }
                else {
                    write-host "$Computer is already in $CategoryName"
                }
            }
        }              
        
        If (!($ComputerName)) {     
            If ($IntuneID) {
                Write-host "Setting category for $IntuneID"
                $Device = Get-DeviceInfoByID -managedDeviceId $IntuneID
                Write-Host "Found $IntuneID in Intune"
                if (!($device)) {
                    Write-Warning "$IntuneID not found in Intune."
                }
                else {
                    $DeviceID = $Device.id
                    $DeviceName = $Device.deviceName
                    if ($Device.deviceCategoryDisplayName -ne $CategoryName) {
                        Write-Progress -Status "Updating Device Category" -Activity "$DeviceName ($deviceId)"
                        Write-Host "Device Name = $DeviceName"
                        Write-Host "Device ID = $DeviceID"
                        Write-Host "Current category is $($Device.deviceCategoryDisplayName)"
                        Write-Host "Setting category to $CategoryName"
                        Set-DeviceCategory -DeviceID $DeviceID -category $CategoryID
                    }
                    else {
                        write-host "$DeviceName is already in $CategoryName"
                    }
                }
            }
        }
        Write-host "Finished processing the Device Category" -ForegroundColor Red
    }
}

# Set Device Ownership Type (Company|Personal)
if ($SetOwner -ne $False) {
    foreach ($Computer in $Computers) {
        if ($InputFile) {
            $ComputerName = $Computer.ComputerName
            $IntuneID = $Computer.IntuneID
        }   
                          
        If ($ComputerName) {
            Write-host "Evaluating Device Ownership" -ForegroundColor Green 
            $Device = Get-DeviceInfo -ComputerName $ComputerName
            if ($Device) {
                if ($Device.ManagedDeviceOwnerType -ne $Owner) {
                    $DeviceID = $Device.id
                    Write-Progress -Status "Updating Device Ownership" -Activity "$computer ($deviceId) --> $($device.ManagedDeviceOwnerType)"
                    Write-Host "Device Name = $Computer"
                    Write-Host "Device ID = $DeviceID"
                    Write-Host "Current Device Ownership is $($Device.ManagedDeviceOwnerType)"
                    Write-Host "Setting Device Ownership to $Owner"
                    Set-Owner -DeviceID $DeviceID -owner $Owner
                }                
                else {
                    write-host $Device.DeviceName "Device Ownership is already set to $Owner, no action taken."
                }
            }       
            else {
                Write-Warning "$ComputerName was not found in Intune."
            }
        }

        If (!($ComputerName)) {     
            If ($IntuneID) {
                Write-host "Computer name was not found, searching by $DeviceID" 
                $Device = Get-DeviceInfoByID -managedDeviceId $IntuneID
                if ($device) {
                    $DeviceID = $Device.id
                    $DeviceName = $Device.deviceName
                    Write-Host "Current Device Ownership is $($Device.ManagedDeviceOwnerType)"
                    if ($Device.ManagedDeviceOwnerType -ne $Owner) {
                        Write-Progress -Status "Updating Device Ownership" -Activity "$computer ($deviceId) --> $($device.ManagedDeviceOwnerType)"
                        Write-Host "Device Name = $Computer"
                        Write-Host "Device ID = $DeviceID"                        
                        Write-Host "Setting Device Ownership to $Owner"
                        Set-Owner -DeviceID $DeviceID -owner $Owner
                    }   
                    else {
                        write-host $Device.DeviceName "is already set to $Owner, no action taken."
                    }             
                }
                else {
                    Write-Warning "$IntuneID not found in Intune."
                }
            }
        }
    }
    Write-host "Finished processing the Device Ownership" -ForegroundColor Red
}

# Set the Primary User
#if ($SetPrimaryUser)
if (-not ([string]::IsNullOrEmpty($SetPrimaryUser))) {    
    if ([string]::IsNullOrEmpty($UserName)) {
        # This will not run if there is a username in the csv or on the command line!
        if ($LastLogonUser) {
            # Last logged on user variable is true. No matter how we got a list of computers to work on we are using last logged on user to set Primary User!
            Write-Host "Evaluating Primary User" -ForegroundColor Green

            foreach ($computer in $computers) {
                #Write-host "Setting the Primary User for next device:" $computer.ComputerName $Computer.IntuneID 
                if ($InputFile) {
                    $ComputerName = $Computer.ComputerName
                    $IntuneID = $Computer.IntuneID
                }  
                If ($ComputerName) {
                    #Write-host "Setting the Primary User user for next $ComputerName"
                    # If we get here the computer name was specified somewhere. Might be in the csv, or might be somewhere else. 
                    $Device = Get-DeviceInfo -ComputerName $ComputerName
                    if ($Device) {
                        # Found the computer in Intune!
                        $Name = $Device.deviceName
                        # Make sure we have a last logged on user
                        $LastLoggedOnUser = ($Device.usersLoggedOn[-1]).userId
                        $userObjectId = $LastLoggedOnUser
                        $user = Get-AzureADUser -ObjectId $userObjectId

                        if ($LastLoggedOnUser) {
                            #We have a last logged on user!
                            write-host "The desired Primary User was defined as" $user.DisplayName "via the command line"
                            #Write-Host "Identified last logged on user ID:" $user.DisplayName
                            # Go run the function to set the Primary User if it needs to be set.
                            Write-host "Checking to see if the desired Primary User matches the last logged on user"
                            $DeviceID = $Device.id                                              
                            Set-LastLogon                 
                        }
                        else {
                            write-host "We can't find the last logged on user. Cannot modify this device!"
                        }
                    }   
                    else {
                        Write-Warning "$ComputerName not found in Intune. Cannot modify this device!"
                    }  
                }              
                
                If (!($ComputerName)) {  
                    # If we get here the ComputerName parameter was not specified. Probably using the Intune Device ID from the CSV.    
                    If ($IntuneID) {
                        $Device = Get-DeviceInfoByID -managedDeviceId $IntuneID
                        if ($device) {
                            # Found the computer in Intune!
                            $DeviceID = $Device.id
                            $DeviceName = $Device.deviceName 
                            $Name = $Device.deviceName                         
                            
                            # Make sure we have a last logged on user
                            $LastLoggedOnUser = ($Device.usersLoggedOn[-1]).userId              
                            if ($LastLoggedOnUser) {
                                #We have a last logged on user!
                                Write-Host "Identified last logged on user ID: $LastLoggedOnUser"
                                # Go run the function to set the Primary User if it needs to be set.
                                Write-host "Checking to see if the Primary User matches the last logged on user"
                                Set-LastLogon
                            }
                            else {
                                write-host "We can't find the last logged on user. Cannot work on this device!"
                            }
                        }
                        else {
                            Write-Warning "$IntuneID Not found in Intune" 
                        } 
                    }
                }
            }
        }
    }
    if (!($LastLogonUser)) {
        # The last logged on user variable is not set to true. Let's check the input file for device/user pairs and set the user that way. 
        if ($Inputfile) {
                               
            foreach ($Row in $computers) {
                $Computer = $Row.ComputerName
                $User = $Row.UserName
                $Device = Get-DeviceInfo -Computername $Computer
                $Userid = Get-AzureADUser -Filter "userPrincipalName eq '$User'" | Select -ExpandProperty ObjectId
                write-host "The desired Primary User for $Computer was defined as $User within the CSV"
                #Write-Host "Found $User $Userid"
                if (!($device -and $Userid)) {
                    Write-Warning "$Computer and/or $User not found."
                }
                else {
                    $DeviceID = $Device.id
                    $CurrentUser = Get-IntuneDevicePrimaryUser -DeviceId $deviceID
                    if ($CurrentUser -ne $Userid) {
                        Write-Host "$User is NOT currently the Primary User"
                        Write-Host "The Primary User for $ComputerName will be set to $User"
                        Set-IntuneDevicePrimaryUser -DeviceId $deviceID -userId $userID
                    }
                    else {
                        Write-Host "$User is already set as the Primary User"
                        Write-Host "No change in Primary User is required"
                    }
                }
            }
        }
        else {
        Write-host "Evaluating Primary User" -ForegroundColor Green   
            foreach ($computer in $computers) {
                write-host "The desired Primary User was defined as $UserName via the command line"
                $Device = Get-DeviceInfo -ComputerName $ComputerName
                    if ($Device) {
                        # Found the computer in Intune!
                        $Name = $Device.deviceName
                        $DeviceID = $Device.id
                        # Check existing Primary User
                        $Userid = Get-AzureADUser -Filter "userPrincipalName eq '$Username'" | Select -ExpandProperty ObjectId
                        $CurrentUser = Get-IntuneDevicePrimaryUser -DeviceId $deviceID
                        if ($CurrentUser -ne $Userid) {
                            Write-Host "$UserName is NOT currently the Primary User"
                            Write-Host "The Primary User for $ComputerName will be set to $UserName"
                            Set-IntuneDevicePrimaryUser -DeviceId $deviceID -userId $userID
                        }
                        else {
                            Write-Host "$UserName is already set as the Primary User"
                            Write-Host "No change in Primary User is required"
                        }
                    }   
                    else {
                        Write-Warning "$Computer and/or $UserName not found"
                    }  
            }
        }
    }
    Write-host "Finished processing the Primary User" -ForegroundColor Red   
}
else {
    Write-host "SetPrimaryUser is not $True" -ForegroundColor Red   
}


Write-Host ""
Write-host "Process Complete!"
Stop-Transcript
