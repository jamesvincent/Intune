# Script to gather Device information, specifically osBuildVersion.
# Cobbled together by James Vincent in September 2023
# Thanks to;
# Tom Machado

#Connect to Graph
$connectionDetails = @{
    'ClientId'    = 'd1ddf0e4-d672-4dae-b554-9d5bdfd93547'
    'RedirectUri' = 'urn:ietf:wg:oauth:2.0:oob'
    'Interactive' = $true
}
$authResult = Get-MsalToken @connectionDetails
$authHeaders = @{
    'Content-Type'='application/json'
    'Authorization'="Bearer " + $authResult.AccessToken
    'ExpiresOn'=$authResult.ExpiresOn
}


#Return All Managed Devices
$baseUri = "https://graph.microsoft.com/beta/deviceManagement"
$restParam = @{
    Method = 'Get'
    Uri = "$baseUri/manageddevices"
    Headers = $authHeaders
    ContentType = 'Application/json'
}

$managedDevices = Invoke-RestMethod @restParam
$managedDevicesArray = $managedDevices.value
$NextLink = $managedDevices."@odata.nextLink"
while ($null -ne $NextLink){
$managedDevices = (Invoke-RestMethod -Uri $NextLink -Headers $authHeaders -Method Get)
$NextLink = $managedDevices."@odata.nextLink"
$managedDevicesArray += $managedDevices.value
}

#Filter by Android
$managedDeviceList = $managedDevicesArray | Where-object operatingSystem -eq Android

#For each device, pull back the relevant details
    foreach ($i in $managedDeviceList) {

        $DeviceID = $i.id
        $URI = "https://graph.microsoft.com/beta/deviceManagement/manageddevices/$DeviceID"
        $Filter = '?$select=deviceName,deviceType,userPrincipalName,userDisplayName,osVersion,operatingSystem,hardwareInformation'
        $Request = Invoke-MgGraphRequest -URI $URI$Filter -method GET
        
        $Output = @()

        #Gather relevant device details
        $DeviceName = $Request.deviceName
        $DeviceType = $Request.deviceType
        $User = $Request.userPrincipalName
        $UserDisplay = $Request.userDisplayName
        $Serial = $Request.hardwareInformation.serialNumber
        $osName = $Request.operatingSystem
        $osVersion = $Request.osVersion
        $osBuild = $Request.hardwareInformation.osBuildNumber
    
            #Store the information from this foreach loop into an array  
            $Output = New-Object -TypeName PSObject -Property @{
                "Device Name" = $DeviceName
                "Device Type" = $DeviceType
                UPN = $User 
                "User DisplayName" = $UserDisplay
                Serial = $Serial
                "Operating System" = $osName
                "OS Version" = $osVersion
                "OS Build" = $osBuild
            } | Select-Object "Device Name","UPN","User DisplayName","Device Type",Serial,"Operating System", "OS Version","OS Build"
    
    #Output the array to the CSV File
    $Output | Export-Csv C:\Temp\DeviceDetails.csv -Append
    }