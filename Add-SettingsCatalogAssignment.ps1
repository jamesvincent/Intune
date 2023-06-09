# Script to Assign a single Security Group to Settings Catalog items.
# Cobbled together by James Vincent in June 2023
# Thanks to;
# https://www.nielskok.tech/intune/assign-store-applications-in-intune-via-powershell/
# https://powers-hell.com/2021/07/04/create-assign-filters-with-powershell-graph/
# https://powers-hell.com/2021/03/08/working-with-intune-settings-catalog-using-powershell-and-graph/
# https://www.rozemuller.com/deploy-power-settings-automated-in-microsoft-endpoint-manager/#power-settings-assignment-with-filters
# https://memv.ennbee.uk/posts/automate-endpoint-privilege-management/#assigning-epm-policies

#Search/Dynamic Vars
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $True)] [string] $PolicyName = "",
    [Parameter(Mandatory = $True)] [string] $TargetGroup = "Security gRoup",
    [Parameter(Mandatory = $True)] [string] $AssignmentType = ""
)

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

#Security Group Lookup based on supplied TargetGroup variable
$baseUri = "https://graph.microsoft.com/beta"
$restParam = @{
    Method = 'Get'
    Uri = "$baseUri/groups"
    Headers = $authHeaders
    ContentType = 'Application/json'
}

$securityGroup = Invoke-RestMethod @restParam
$securityGroupTarget = $securityGroup.value
$NextLink = $securityGroup."@odata.nextLink"
while ($null -ne $NextLink){
$securityGroup = (Invoke-RestMethod -Uri $NextLink -Headers $authHeaders -Method Get)
$NextLink = $securityGroup."@odata.nextLink"
$securityGroupTarget += $securityGroup.value
}

#Define Target Group variables
$TargetGroupDetails = $securityGroupTarget | Where-Object {$_.displayName -like "$TargetGroup*"} | Select-Object -first 1
$TargetGroupName = $TargetGroupDetails.displayName
$TargetGroupId = $TargetGroupDetails.id

#Return All Settings Catalog Policies
$baseUri = "https://graph.microsoft.com/beta/deviceManagement"
$restParam = @{
    Method = 'Get'
    Uri = "$baseUri/configurationPolicies"
    Headers = $authHeaders
    ContentType = 'Application/json'
}

$settingsPolicy = Invoke-RestMethod @restParam
$settingsPolicyTarget = $settingsPolicy.value
$NextLink = $settingsPolicy."@odata.nextLink"
while ($null -ne $NextLink){
$settingsPolicy = (Invoke-RestMethod -Uri $NextLink -Headers $authHeaders -Method Get)
$NextLink = $settingsPolicy."@odata.nextLink"
$settingsPolicyTarget += $settingsPolicy.value
}

#Display Confirmation/Warning
$SettingsPolicyDetails = $settingsPolicyTarget | Where-Object {$_.name -like "$PolicyName*"} 

foreach ($i in $SettingsPolicyDetails) {
    Write-Host Attempting to assign $TargetGroupName to $i.name as $AssignmentType -ForegroundColor Green
}

$confirmation = Read-Host "Are you sure you wish to do this? [y/n]"
if ($confirmation -eq 'y') {
    foreach ($i in $SettingsPolicyDetails) {
        try {

                            #Report existing assignments
                            Write-Host The following security assignments exist for $i.name -ForegroundColor Yellow
                            $assignmentsuri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assignments" -f $i.id
                            $Respons = (Invoke-RestMethod -Uri $assignmentsuri -Headers $authHeaders -Method Get).value
            
                            foreach ($group in $($Respons.target.groupid)) {
                                #Security Group Lookup based on supplied TargetGroup variable
                                $baseUri = "https://graph.microsoft.com/beta"
                                $restParam = @{
                                    Method = 'Get'
                                    Uri = "$baseUri/groups/$group"
                                    Headers = $authHeaders
                                    ContentType = 'Application/json'
                                }
            
                                $securityGroupNames = Invoke-RestMethod @restParam
                                Write-Host $securityGroupNames.displayname -ForegroundColor Yellow
                            }

                    # Collect existing assignments of the Settings Catalog Item
                    $assignmentsuri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assignments" -f $i.id
                    $Respons = (Invoke-RestMethod -Uri $assignmentsuri -Headers $authHeaders -Method Get).value

                    $requestBody = @{
                        assignments = @()
                    }
                    #Check if there already are groups assigned to the settings catalog item
                    if ($Respons) {
                        foreach ($group in $($Respons)) {
                            # Get group assignment
                            if ($group.target."@odata.type" -eq "#microsoft.graph.groupAssignmentTarget") {
                                # Check to see if TargetGroupId is already assigned.
                                if ($group.target.groupId -ne $TargetGroupId) {
                                    $requestBody.assignments += @{
                                        "target" = $group.target    
                                    }  
                                }
                                # If assigned already, then report back and take no action
                                elseif ($group.target.groupId -eq $TargetGroupId) {
                                    Write-Host $targetgroupname '('$targetgroupid ')' is already assigned to $i.name - No action taken -ForegroundColor Red
                                }
                            }
                            # Get exclusion group assignment
                            if ($group.target."@odata.type" -eq "#microsoft.graph.exclusionGroupAssignmentTarget") {
                                $requestBody.configurationPoliciesAssignments += @{
                                    "target" = $group.target
                                }
                            } 
                        }
                    }
            
                #Append Target Group ID to already assigned groups
                $requestBody.assignments += @{
                    "target" = @{
                        "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                        "groupId"     = "$TargetGroupId"
                    }
                }
                #Assign the array of Target Groups, to the Settings Catalog items
                $restore = $requestBody | ConvertTo-Json -Depth 99
                $assignuri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assign" -f $i.id
                Invoke-RestMethod -Uri $assignuri -Headers $authHeaders -Method Post -Body $restore

                #Check new assignments
                Write-Host After changes, the following security assignments exist for $i.name -ForegroundColor Green
                $assignmentsuri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assignments" -f $i.id
                $Respons = (Invoke-RestMethod -Uri $assignmentsuri -Headers $authHeaders -Method Get).value

                foreach ($group in $($Respons.target.groupid)) {
                    #Security Group Lookup based on supplied TargetGroup variable
                    $baseUri = "https://graph.microsoft.com/beta"
                    $restParam = @{
                        Method = 'Get'
                        Uri = "$baseUri/groups/$group"
                        Headers = $authHeaders
                        ContentType = 'Application/json'
                    }

                    $securityGroupNames = Invoke-RestMethod @restParam
                    Write-Host $securityGroupNames.displayname -ForegroundColor Green
                }

            }    
    catch {
        write-host $_.Exception.Message -f Red
        write-host $_.Exception.ItemName -f Red
        write-host
        Write-host $_.Exception.Message -LogLevel 3
        Write-host $_.Exception.ItemName -LogLevel 3
    }      
}
} elseif ($confirmation -eq 'n') {
        write-host User declined assignment, no changes made.
        break
}
