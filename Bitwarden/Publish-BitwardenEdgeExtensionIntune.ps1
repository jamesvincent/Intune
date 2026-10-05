<#
.SYNOPSIS
    Creates or updates an Intune policy that force-installs the Bitwarden
    browser extension in Microsoft Edge.

.DESCRIPTION
    Creates a Windows 10/11 custom configuration profile using the Microsoft
    Edge ADMX-backed ExtensionInstallForcelist policy.

    Bitwarden Edge extension:
      ID: jbkfoedolllekgbhcbcoahefnbanhhlh
      Update URL: https://edge.microsoft.com/extensionwebstorebase/v1/crx

    By default, the policy is created without assignments. Supply -GroupId to
    assign it to an existing Microsoft Entra group.

    Requires Microsoft.Graph.Authentication and delegated or application
    permission DeviceManagementConfiguration.ReadWrite.All.

.EXAMPLE
    .\Publish-BitwardenEdgeExtensionIntune-v1.ps1

.EXAMPLE
    .\Publish-BitwardenEdgeExtensionIntune-v1.ps1 `
        -GroupId '00000000-0000-0000-0000-000000000000'

.EXAMPLE
    .\Publish-BitwardenEdgeExtensionIntune-v1.ps1 `
        -PolicyName 'Microsoft Edge - Bitwarden Extension' `
        -UpdateExisting `
        -GroupId '00000000-0000-0000-0000-000000000000'
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$PolicyName = 'Microsoft Edge - Force Install Bitwarden Extension',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$PolicyDescription = 'Force-installs the official Bitwarden Password Manager extension from Microsoft Edge Add-ons.',

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$GroupId,

    [Parameter()]
    [switch]$UpdateExisting,

    [Parameter()]
    [switch]$AssignToAllDevices,

    [Parameter()]
    [switch]$AssignToAllUsers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExtensionId = 'jbkfoedolllekgbhcbcoahefnbanhhlh'
$UpdateUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
$GraphBaseUri = 'https://graph.microsoft.com/beta'
$RequiredScope = 'DeviceManagementConfiguration.ReadWrite.All'

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [$Level] $Message"
}

function Test-GraphConnection {
    $context = Get-MgContext

    if (-not $context) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace([string]$context.TenantId) -or
        [string]::IsNullOrWhiteSpace([string]$context.ClientId)) {
        return $false
    }

    try {
        $null = Invoke-MgGraphRequest `
            -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/organization?$top=1' `
            -OutputType PSObject `
            -ErrorAction Stop

        return $true
    }
    catch {
        Write-Log "An existing Graph context was found, but its token could not be used: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Ensure-GraphConnection {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Log 'Installing Microsoft.Graph.Authentication for the current user.'
        Install-Module `
            -Name Microsoft.Graph.Authentication `
            -Scope CurrentUser `
            -Force `
            -AllowClobber
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    if (Test-GraphConnection) {
        $context = Get-MgContext
        $identity = if (-not [string]::IsNullOrWhiteSpace([string]$context.Account)) {
            [string]$context.Account
        }
        else {
            "application $($context.ClientId)"
        }

        Write-Log "Reusing the active Microsoft Graph connection for tenant '$($context.TenantId)' as $identity."
        return
    }

    $existingContext = Get-MgContext
    if ($existingContext) {
        Write-Log 'The existing Microsoft Graph context is not usable. Disconnecting it before authentication.' 'WARN'
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Log "No usable Microsoft Graph connection was found. Connecting with scope '$RequiredScope'."
    Connect-MgGraph `
        -Scopes $RequiredScope `
        -UseDeviceCode `
        -NoWelcome `
        -ErrorAction Stop

    if (-not (Test-GraphConnection)) {
        throw 'Microsoft Graph authentication completed, but the resulting connection could not be validated.'
    }

    $context = Get-MgContext

    if ($context.AuthType -eq 'Delegated') {
        $currentScopes = @($context.Scopes)
        if ($RequiredScope -notin $currentScopes) {
            throw "The Microsoft Graph session does not include the required delegated scope '$RequiredScope'."
        }
    }

    $identity = if (-not [string]::IsNullOrWhiteSpace([string]$context.Account)) {
        [string]$context.Account
    }
    else {
        "application $($context.ClientId)"
    }

    Write-Log "Connected to Microsoft Graph tenant '$($context.TenantId)' as $identity." 'SUCCESS'
}

function Invoke-GraphPagedGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri

    while ($nextLink) {
        $response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $nextLink `
            -OutputType PSObject

        if ($response.PSObject.Properties.Name -contains 'value') {
            foreach ($item in @($response.value)) {
                $results.Add($item)
            }
        }
        else {
            $results.Add($response)
        }

        if ($response.PSObject.Properties.Name -contains '@odata.nextLink') {
            $nextLink = $response.'@odata.nextLink'
        }
        else {
            $nextLink = $null
        }
    }

    return $results
}

function Get-ExistingPolicy {
    $escapedName = $PolicyName.Replace("'", "''")
    $encodedFilter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $uri = "$GraphBaseUri/deviceManagement/deviceConfigurations?`$filter=$encodedFilter"

    try {
        $response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $uri `
            -OutputType PSObject

        return @($response.value) |
            Where-Object { $_.displayName -eq $PolicyName } |
            Select-Object -First 1
    }
    catch {
        Write-Log 'Filtered policy lookup failed; falling back to a full policy lookup.' 'WARN'

        return Invoke-GraphPagedGet `
            -Uri "$GraphBaseUri/deviceManagement/deviceConfigurations" |
            Where-Object { $_.displayName -eq $PolicyName } |
            Select-Object -First 1
    }
}

function New-PolicyPayload {
    $omaValue = '<enabled/><data id="ExtensionInstallForcelistDesc" value="1&#xF000;' +
        $ExtensionId +
        ';' +
        $UpdateUrl +
        '"/>'

    return @{
        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
        displayName = $PolicyName
        description = $PolicyDescription
        omaSettings = @(
            @{
                '@odata.type' = '#microsoft.graph.omaSettingString'
                displayName = 'Microsoft Edge: Force install Bitwarden extension'
                description = 'Silently installs Bitwarden from Microsoft Edge Add-ons. Users cannot disable or uninstall a force-installed extension.'
                omaUri = './Device/Vendor/MSFT/Policy/Config/Edge~Policy~microsoft_edge~Extensions/ExtensionInstallForcelist'
                value = $omaValue
            }
        )
    }
}

function Set-PolicyAssignment {
    param(
        [Parameter(Mandatory)]
        [string]$PolicyId
    )

    $targets = [System.Collections.Generic.List[hashtable]]::new()

    if ($GroupId) {
        $targets.Add(@{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId = $GroupId
        })
    }

    if ($AssignToAllDevices) {
        $targets.Add(@{
            '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget'
        })
    }

    if ($AssignToAllUsers) {
        $targets.Add(@{
            '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget'
        })
    }

    if ($targets.Count -eq 0) {
        Write-Log 'No assignment target was supplied. The policy remains unassigned.' 'WARN'
        return
    }

    $assignments = @(
        foreach ($target in $targets) {
            @{
                '@odata.type' = '#microsoft.graph.deviceConfigurationAssignment'
                target = $target
            }
        }
    )

    $body = @{
        assignments = $assignments
    } | ConvertTo-Json -Depth 10

    Write-Log 'Applying Intune policy assignments.'

    Invoke-MgGraphRequest `
        -Method POST `
        -Uri "$GraphBaseUri/deviceManagement/deviceConfigurations/$PolicyId/assign" `
        -Body $body `
        -ContentType 'application/json' | Out-Null

    Write-Log 'Policy assignments applied.' 'SUCCESS'
}

try {
    if ($AssignToAllDevices -and $AssignToAllUsers) {
        throw 'Choose either -AssignToAllDevices or -AssignToAllUsers, not both.'
    }

    if ($GroupId -and ($AssignToAllDevices -or $AssignToAllUsers)) {
        throw 'Use -GroupId or an all-users/all-devices switch, not both.'
    }

    Ensure-GraphConnection

    $existingPolicy = Get-ExistingPolicy
    $payload = New-PolicyPayload
    $jsonBody = $payload | ConvertTo-Json -Depth 10

    if ($existingPolicy) {
        if (-not $UpdateExisting) {
            throw "A policy named '$PolicyName' already exists with ID '$($existingPolicy.id)'. Use -UpdateExisting to replace its settings."
        }

        Write-Log "Updating existing Intune policy '$PolicyName'."

        Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri "$GraphBaseUri/deviceManagement/deviceConfigurations/$($existingPolicy.id)" `
            -Body $jsonBody `
            -ContentType 'application/json' | Out-Null

        $policyId = [string]$existingPolicy.id
        Write-Log "Policy '$PolicyName' updated." 'SUCCESS'
    }
    else {
        Write-Log "Creating Intune policy '$PolicyName'."

        $createdPolicy = Invoke-MgGraphRequest `
            -Method POST `
            -Uri "$GraphBaseUri/deviceManagement/deviceConfigurations" `
            -Body $jsonBody `
            -ContentType 'application/json' `
            -OutputType PSObject

        $policyId = [string]$createdPolicy.id

        if ([string]::IsNullOrWhiteSpace($policyId)) {
            throw 'The policy was created, but Microsoft Graph did not return its ID.'
        }

        Write-Log "Policy '$PolicyName' created." 'SUCCESS'
    }

    Set-PolicyAssignment -PolicyId $policyId

    [pscustomobject]@{
        PolicyName    = $PolicyName
        PolicyId      = $policyId
        ExtensionName = 'Bitwarden Password Manager'
        ExtensionId   = $ExtensionId
        UpdateUrl     = $UpdateUrl
        Assignment    = if ($GroupId) {
            "Entra group: $GroupId"
        }
        elseif ($AssignToAllDevices) {
            'All devices'
        }
        elseif ($AssignToAllUsers) {
            'All users'
        }
        else {
            'Unassigned'
        }
    }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
}
