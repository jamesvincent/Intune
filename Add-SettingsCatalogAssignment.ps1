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
    [Parameter(Mandatory = $True)] [string] $TargetGroup = "",
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
while ($NextLink -ne $null){
$securityGroup = (Invoke-RestMethod -Uri $NextLink -Headers $authHeaders -Method Get)
$NextLink = $securityGroup."@odata.nextLink"
$assignmentpolicy += $securityGroup.value
}

#Define Target Group variables
$TargetGroupDetails = $securityGroupTarget | Where-Object {$_.displayName -like "$TargetGroup*"} | Select-Object -first 1
$TargetGroupName = $TargetGroupDetails.displayName
$TargetGroupId = $TargetGroupDetails.id

Write-Host "Security Group to Assign: $TargetGroupName" -ForegroundColor Yellow

#Return All Settings Catalog Profiles
$baseUri = "https://graph.microsoft.com/beta/deviceManagement"
$restParam = @{
    Method = 'Get'
    Uri = "$baseUri/configurationPolicies"
    Headers = $authHeaders
    ContentType = 'Application/json'
}

$settingsProfiles = Invoke-RestMethod @restParam
$settingsProfileTarget = $settingsProfiles.value
$NextLink = $settingsProfiles."@odata.nextLink"
while ($NextLink -ne $null){
$settingsProfiles = (Invoke-RestMethod -Uri $NextLink -Headers $authHeaders -Method Get)
$NextLink = $settingsProfiles."@odata.nextLink"
$settingsProfileTarget += $settingsProfiles.value
}

#Display Confirmation/Warning
$ProfileNameArray = $settingsProfileTarget | Where-Object {$_.name -like "$PolicyName*"} 

foreach ($i in $ProfileNameArray) {
    Write-Host Will Assign $TargetGroupName to $i.name as $AssignmentType -ForegroundColor Green
}
$confirmation = Read-Host "Are you sure you wish to do this? [y/n]"
if ($confirmation -eq 'y') {
try {
    $TargetGroup = New-Object -TypeName psobject

    #Calculate if an Include or an Exclude assignment
    if ($AssignmentType -eq 'Exclude') {
        $TargetGroup | Add-Member -MemberType NoteProperty -Name '@odata.type' -Value '#microsoft.graph.exclusionGroupAssignmentTarget'
    } elseif ($AssignmentType -eq 'Include') {
        $TargetGroup | Add-Member -MemberType NoteProperty -Name '@odata.type' -Value '#microsoft.graph.groupAssignmentTarget'
    }

    $TargetGroup | Add-Member -MemberType NoteProperty -Name 'groupId' -Value "$TargetGroupId"

    $Target = New-Object -TypeName psobject
    $Target | Add-Member -MemberType NoteProperty -Name 'target' -Value $TargetGroup
    $TargetGroups = $Target

    # Creating JSON object to pass to Graph
    $Output = New-Object -TypeName psobject
    $Output | Add-Member -MemberType NoteProperty -Name 'assignments' -Value @($TargetGroups)
    $JSON = $Output | ConvertTo-Json -Depth 3

    # Create an array of Settings Catalog Id's
    $Id = $settingsProfileTarget | Where-Object {$_.name -like "$PolicyName*"} 

    # Collect existing assignments of the Settings Catalog Item
    foreach ($i in $Id) {
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
                    Write-Host This group $targetgroupname '('$targetgroupid ')' is already assigned to $i.name -ForegroundColor Red
                    break
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
    }
    #Append Target Group ID to already assigned groups
    $requestBody.assignments += @{
        "target" = @{
            "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
            "groupId"     = "$TargetGroupId"
        }
    }
    #Assign the array of Target Groups, to the Settings Catalog items
    foreach ($i in $Id) {
        $restore = $requestBody | ConvertTo-Json -Depth 99
        $assignuri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assign" -f $i.id
        Invoke-RestMethod -Uri $assignuri -Headers $authHeaders -Method Post -Body $restore
        Write-Host Successfully Assigned $TargetGroupName to $i.name as an $AssignmentType -ForegroundColor Green
        }
}           
catch {
        write-host $_.Exception.Message -f Red
        write-host $_.Exception.ItemName -f Red
        write-host
        Write-host $_.Exception.Message -LogLevel 3
        Write-host $_.Exception.ItemName -LogLevel 3
        break
    }     
} elseif ($confirmation -eq 'n') {
        write-host It Declined
        break
}