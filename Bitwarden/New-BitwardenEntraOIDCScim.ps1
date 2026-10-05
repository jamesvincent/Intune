#requires -Version 7.0
<#
.SYNOPSIS
Creates a Bitwarden Microsoft Entra Enterprise Application with OIDC and SCIM provisioning.

.DESCRIPTION
Creates an Enterprise Application by instantiating Microsoft's non-gallery application
application template. This is important because the resulting service principal supports
Microsoft Entra application provisioning, unlike a service principal created only from a
plain app registration in some portal experiences.

The script then:
- Configures the associated application registration as a confidential OIDC web client.
- Adds delegated Microsoft Graph User.Read.
- Creates a client secret.
- Creates a SCIM synchronization job from the provisioning template exposed by the service principal.
- Tests and stores the Bitwarden SCIM endpoint credentials.
- Optionally starts provisioning.
- Optionally assigns and provisions a test user on demand.
- Validates the Entra OIDC configuration and OpenID metadata endpoint.

A true end-to-end Bitwarden OIDC login cannot be completed solely through Microsoft Graph.
The returned Authority, Client ID and Client Secret must first be entered in the Bitwarden
Admin Console, and the login test must then be initiated from Bitwarden.

.EXAMPLE
Connect-MgGraph -Scopes Application.ReadWrite.All,Synchronization.ReadWrite.All,Directory.Read.All -NoWelcome

./New-BitwardenEntraOIDCScim.ps1 `
    -DisplayName 'Bitwarden' `
    -Region EU `
    -ScimTenantUrl 'https://scim.bitwarden.eu/v2/your-organization-id' `
    -ScimSecretToken (Read-Host 'SCIM token' -AsSecureString) `
    -StartProvisioning

.EXAMPLE
./New-BitwardenEntraOIDCScim.ps1 `
    -DisplayName 'Bitwarden' `
    -Region EU `
    -ScimTenantUrl 'https://scim.bitwarden.eu/v2/your-organization-id' `
    -ScimSecretToken (Read-Host 'SCIM token' -AsSecureString) `
    -TestUserObjectId '00000000-0000-0000-0000-000000000000' `
    -AssignTestUser `
    -ProvisionOnDemand `
    -StartProvisioning
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName = 'Bitwarden',

    [Parameter(ParameterSetName = 'Cloud')]
    [ValidateSet('US', 'EU')]
    [string]$Region = 'US',

    [Parameter(Mandatory, ParameterSetName = 'Custom')]
    [ValidatePattern('^https://')]
    [string]$RedirectUri,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$ScimTenantUrl,

    [Parameter(Mandatory)]
    [SecureString]$ScimSecretToken,

    [Parameter()]
    [ValidateRange(1, 24)]
    [int]$SecretLifetimeMonths = 12,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SecretDisplayName = 'Bitwarden OIDC client secret',

    [Parameter()]
    [switch]$GrantAdminConsent,

    [Parameter()]
    [switch]$AssignmentRequired,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssignedGroupObjectId,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TestUserObjectId,

    [Parameter()]
    [switch]$AssignTestUser,

    [Parameter()]
    [switch]$ProvisionOnDemand,

    [Parameter()]
    [switch]$StartProvisioning,

    [Parameter()]
    [switch]$AutoConnect,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Microsoft's global non-gallery application template. Instantiating this template creates
# both the application and service principal in a provisioning-capable form.
$NonGalleryApplicationTemplateId = '8adf8e6e-67b2-4cf2-a259-e3dc5476c621'
$MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$UserReadScopeId = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
$DefaultAppRoleId = '00000000-0000-0000-0000-000000000000'

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}

function ConvertFrom-SecureStringPlainText {
    param([Parameter(Mandatory)][SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-GraphContextSafely {
    try { Get-MgContext -ErrorAction Stop } catch { $null }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}


function Get-GraphErrorText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    $parts = [System.Collections.Generic.List[string]]::new()

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        $parts.Add([string]$ErrorRecord.Exception.Message)
    }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $parts.Add([string]$ErrorRecord.ErrorDetails.Message)
    }
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
        try { $parts.Add(($ErrorRecord.Exception.Response | Out-String)) } catch { }
    }

    # Invoke-MgGraphRequest often places the Graph response body in the rendered
    # error record rather than Exception.Message. Include it so nested Graph
    # error codes such as CredentialValidationUnavailable can be detected.
    try { $parts.Add(($ErrorRecord | Out-String)) } catch { }

    return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")
}

function Invoke-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $results = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri

    while ($nextLink) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
        $value = Get-PropertyValue -InputObject $response -Name 'value'

        if ($null -ne $value) {
            foreach ($item in @($value)) { $results.Add($item) }
        }
        else {
            $results.Add($response)
        }

        $nextLink = [string](Get-PropertyValue -InputObject $response -Name '@odata.nextLink')
    }

    return @($results)
}


function Invoke-GraphCollectionWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Description,
        [ValidateRange(1, 30)][int]$MaxAttempts = 12,
        [ValidateRange(1, 30)][int]$InitialDelaySeconds = 3
    )

    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return @(Invoke-GraphCollection -Uri $Uri)
        }
        catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties['ResponseStatusCode']) {
                $statusCode = [int]$_.Exception.ResponseStatusCode
            }
            elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $errorText = Get-GraphErrorText -ErrorRecord $_
            $isRetryable = ($statusCode -in @(401, 404, 409, 429, 500, 502, 503, 504)) -or
                ($errorText -match '(?i)401|Unauthorized|404|NotFound|ResourceNotFound|does not exist|Too Many Requests|temporarily unavailable|conflict')

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            Write-Log WARN "$Description is not yet available from the Entra provisioning backend (attempt $attempt of $MaxAttempts). Waiting $delay second(s)."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 15)
        }
    }
}

function Invoke-GraphJson {
    param(
        [Parameter(Mandatory)][ValidateSet('POST', 'PUT', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Body
    )

    Invoke-MgGraphRequest -Method $Method -Uri $Uri `
        -Body ($Body | ConvertTo-Json -Depth 30 -Compress) `
        -ContentType 'application/json' -OutputType PSObject
}


function Invoke-GraphJsonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('POST', 'PUT', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Body,
        [Parameter(Mandatory)][string]$Description,
        [int[]]$AdditionalRetryStatusCodes = @(),
        [ValidateRange(1, 30)][int]$MaxAttempts = 12,
        [ValidateRange(1, 30)][int]$InitialDelaySeconds = 2
    )

    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-GraphJson -Method $Method -Uri $Uri -Body $Body
        }
        catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties['ResponseStatusCode']) {
                $statusCode = [int]$_.Exception.ResponseStatusCode
            }
            elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $errorText = Get-GraphErrorText -ErrorRecord $_
            $retryStatusCodes = @(404, 409, 429, 500, 502, 503, 504) + @($AdditionalRetryStatusCodes)
            $isRetryable = ($statusCode -in $retryStatusCodes) -or
                ($errorText -match '(?i)404|NotFound|ResourceNotFound|does not exist|Too Many Requests|temporarily unavailable|conflict') -or
                (($statusCode -eq 401) -and (401 -in $AdditionalRetryStatusCodes))

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            Write-Log WARN "$Description is not yet accepted by Graph (attempt $attempt of $MaxAttempts). Waiting $delay second(s)."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 15)
        }
    }
}

function Get-GraphObjectWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Description,
        [ValidateRange(1, 30)][int]$MaxAttempts = 12,
        [ValidateRange(1, 30)][int]$InitialDelaySeconds = 2
    )

    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        }
        catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties['ResponseStatusCode']) {
                $statusCode = [int]$_.Exception.ResponseStatusCode
            }
            elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $isRetryable = ($statusCode -in @(404, 429, 500, 502, 503, 504)) -or
                ($_.Exception.Message -match '404|NotFound|ResourceNotFound|Too Many Requests|temporarily unavailable')

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            Write-Log WARN "$Description is not yet available from Graph (attempt $attempt of $MaxAttempts). Waiting $delay second(s)."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 15)
        }
    }
}

function Test-BitwardenScimEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token
    )

    $testUri = "$($BaseUrl.TrimEnd('/'))/Users?startIndex=1&count=1"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/scim+json'
    }

    try {
        $response = Invoke-RestMethod -Method GET -Uri $testUri -Headers $headers -ErrorAction Stop
        $schemas = @($response.schemas)
        if ('urn:ietf:params:scim:api:messages:2.0:ListResponse' -notin $schemas) {
            throw "The endpoint responded, but it did not return a SCIM 2.0 ListResponse."
        }

        return [pscustomobject]@{
            Passed       = $true
            TestUri      = $testUri
            TotalResults = $response.totalResults
        }
    }
    catch {
        throw "The Bitwarden SCIM endpoint pre-flight test failed for '$testUri'. $($_.Exception.Message)"
    }
}

function Assert-GraphConnection {
    param([Parameter(Mandatory)][string[]]$RequiredScopes)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is not installed. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $context = Get-GraphContextSafely

    if ($null -eq $context -or -not $context.TenantId) {
        if (-not $AutoConnect) {
            throw "No active Microsoft Graph connection was found. Connect first with: Connect-MgGraph -Scopes '$($RequiredScopes -join "','")' -NoWelcome"
        }

        Write-Log INFO "Connecting to Microsoft Graph with: $($RequiredScopes -join ', ')"
        Connect-MgGraph -Scopes $RequiredScopes -NoWelcome
        $context = Get-GraphContextSafely
    }
    else {
        Write-Log INFO "Using existing Graph connection for tenant $($context.TenantId) as $($context.Account)."
    }

    $missingScopes = @($RequiredScopes | Where-Object { $_ -notin @($context.Scopes) })
    if ($missingScopes.Count -gt 0) {
        throw "The active Graph session is missing: $($missingScopes -join ', '). Reconnect yourself with: Connect-MgGraph -Scopes '$($RequiredScopes -join "','")' -NoWelcome"
    }

    return $context
}

function Get-UserProvisioningRuleId {
    param(
        [Parameter(Mandatory)][string]$ServicePrincipalId,
        [Parameter(Mandatory)][string]$JobId
    )

    $schema = Invoke-MgGraphRequest -Method GET `
        -Uri "/v1.0/servicePrincipals/$ServicePrincipalId/synchronization/jobs/$JobId/schema" `
        -OutputType PSObject

    $rules = @(Get-PropertyValue -InputObject $schema -Name 'synchronizationRules')
    if ($rules.Count -eq 0) {
        throw 'The synchronization schema does not contain any synchronization rules.'
    }

    # Prefer a rule that clearly maps an Entra user to a target user. Gallery/template
    # names vary, so inspect both object definitions and the rule name.
    $userRule = $rules | Where-Object {
        $sourceName = [string](Get-PropertyValue -InputObject $_ -Name 'sourceDirectoryName')
        $targetName = [string](Get-PropertyValue -InputObject $_ -Name 'targetDirectoryName')
        $name = [string](Get-PropertyValue -InputObject $_ -Name 'name')
        $objectMappings = @(Get-PropertyValue -InputObject $_ -Name 'objectMappings')

        $mappingLooksLikeUser = $false
        foreach ($mapping in $objectMappings) {
            $sourceObject = [string](Get-PropertyValue -InputObject $mapping -Name 'sourceObjectName')
            $targetObject = [string](Get-PropertyValue -InputObject $mapping -Name 'targetObjectName')
            if ($sourceObject -match 'User' -and $targetObject -match 'User') {
                $mappingLooksLikeUser = $true
                break
            }
        }

        $mappingLooksLikeUser -or $name -match 'User' -or ($sourceName -match 'Azure' -and $targetName -match 'SCIM')
    } | Select-Object -First 1

    if (-not $userRule) {
        throw "A user synchronization rule could not be identified automatically. Available rules: $((@($rules | ForEach-Object { $_.id }) -join ', '))"
    }

    return [string]$userRule.id
}

if ($PSCmdlet.ParameterSetName -eq 'Cloud') {
    $RedirectUri = if ($Region -eq 'EU') {
        'https://sso.bitwarden.eu/oidc-signin'
    }
    else {
        'https://sso.bitwarden.com/oidc-signin'
    }
}

if ($ProvisionOnDemand -and -not $TestUserObjectId) {
    throw '-ProvisionOnDemand requires -TestUserObjectId.'
}
if ($AssignTestUser -and -not $TestUserObjectId) {
    throw '-AssignTestUser requires -TestUserObjectId.'
}

$requiredScopes = [System.Collections.Generic.List[string]]::new()
@('Application.ReadWrite.All', 'Synchronization.ReadWrite.All', 'Directory.Read.All') | ForEach-Object { $requiredScopes.Add($_) }
if ($GrantAdminConsent) { $requiredScopes.Add('DelegatedPermissionGrant.ReadWrite.All') }
if ($AssignedGroupObjectId -or $AssignTestUser -or $AssignmentRequired) { $requiredScopes.Add('AppRoleAssignment.ReadWrite.All') }
$requiredScopes = @($requiredScopes | Sort-Object -Unique)

$context = Assert-GraphConnection -RequiredScopes $requiredScopes
$plainScimToken = ConvertFrom-SecureStringPlainText -SecureString $ScimSecretToken

# Bitwarden does not currently expose ServiceProviderConfig at the organisation-specific
# endpoint. Test the supported /Users collection instead before creating any Entra objects.
Write-Log INFO 'Running a direct Bitwarden SCIM pre-flight test against the Users endpoint.'
$directScimTest = Test-BitwardenScimEndpoint -BaseUrl $ScimTenantUrl -Token $plainScimToken
Write-Log SUCCESS "The Bitwarden SCIM endpoint responded with a valid SCIM ListResponse (totalResults: $($directScimTest.TotalResults))."

$application = $null
$applicationObjectId = $null
$servicePrincipalObjectId = $null
$servicePrincipal = $null
$secret = $null
$syncJob = $null
$created = $false

try {
    $escapedName = $DisplayName.Replace("'", "''")
    $existing = @(Invoke-GraphCollection -Uri "/v1.0/servicePrincipals?`$filter=displayName eq '$escapedName'&`$select=id,appId,displayName,applicationTemplateId")
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "An Enterprise Application named '$DisplayName' already exists. Choose another name or use -Force to create another instance."
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Bitwarden OIDC and SCIM Enterprise Application')) {
        return
    }

    Write-Log INFO "Instantiating Microsoft non-gallery application template as '$DisplayName'."
    $instance = Invoke-GraphJson -Method POST `
        -Uri "/v1.0/applicationTemplates/$NonGalleryApplicationTemplateId/instantiate" `
        -Body @{ displayName = $DisplayName }

    $applicationResult = Get-PropertyValue -InputObject $instance -Name 'application'
    $servicePrincipalResult = Get-PropertyValue -InputObject $instance -Name 'servicePrincipal'

    $applicationObjectId = [string]((Get-PropertyValue -InputObject $applicationResult -Name 'id') ?? (Get-PropertyValue -InputObject $applicationResult -Name 'objectId'))
    $servicePrincipalObjectId = [string]((Get-PropertyValue -InputObject $servicePrincipalResult -Name 'id') ?? (Get-PropertyValue -InputObject $servicePrincipalResult -Name 'objectId'))

    if (-not $applicationObjectId -or -not $servicePrincipalObjectId) {
        throw 'The template was instantiated, but Graph did not return the application and service principal object IDs.'
    }
    $created = $true

    # Template instantiation is eventually consistent. The IDs can be returned before
    # the application and service principal are readable from their collection endpoints.
    $application = Get-GraphObjectWithRetry `
        -Uri "/v1.0/applications/$applicationObjectId" `
        -Description 'The newly created application object'
    $servicePrincipal = Get-GraphObjectWithRetry `
        -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId" `
        -Description 'The newly created service principal'

    Write-Log INFO 'Configuring the application registration for OIDC.'
    $applicationPatch = @{
        signInAudience = 'AzureADMyOrg'
        web = @{
            redirectUris = @($RedirectUri)
            implicitGrantSettings = @{
                enableAccessTokenIssuance = $false
                enableIdTokenIssuance = $false
            }
        }
        requiredResourceAccess = @(
            @{
                resourceAppId = $MicrosoftGraphAppId
                resourceAccess = @(
                    @{ id = $UserReadScopeId; type = 'Scope' }
                )
            }
        )
    }
    Invoke-GraphJsonWithRetry -Method PATCH `
        -Uri "/v1.0/applications/$applicationObjectId" `
        -Body $applicationPatch `
        -Description 'OIDC application registration update' | Out-Null

    Write-Log INFO "Setting assignment required to $([bool]$AssignmentRequired)."
    Invoke-GraphJsonWithRetry -Method PATCH `
        -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId" `
        -Body @{ appRoleAssignmentRequired = [bool]$AssignmentRequired } `
        -Description 'Enterprise Application assignment configuration' | Out-Null

    Write-Log INFO "Creating an OIDC client secret valid for $SecretLifetimeMonths month(s)."
    $secret = Invoke-GraphJsonWithRetry -Method POST `
        -Uri "/v1.0/applications/$applicationObjectId/addPassword" `
        -Description 'OIDC client secret creation' `
        -Body @{
        passwordCredential = @{
            displayName = $SecretDisplayName
            startDateTime = (Get-Date).ToUniversalTime().ToString('o')
            endDateTime = (Get-Date).ToUniversalTime().AddMonths($SecretLifetimeMonths).ToString('o')
        }
    }

    if ($GrantAdminConsent) {
        Write-Log INFO 'Granting tenant-wide admin consent to Microsoft Graph User.Read.'
        $graphServicePrincipal = Invoke-MgGraphRequest -Method GET `
            -Uri "/v1.0/servicePrincipals(appId='$MicrosoftGraphAppId')?`$select=id" -OutputType PSObject

        $grants = @(Invoke-GraphCollection -Uri "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$servicePrincipalObjectId' and resourceId eq '$($graphServicePrincipal.id)' and consentType eq 'AllPrincipals'")
        $existingGrant = $grants | Select-Object -First 1

        if ($existingGrant) {
            $scopes = @(([string]$existingGrant.scope -split ' ') | Where-Object { $_ })
            if ('User.Read' -notin $scopes) {
                $scopes += 'User.Read'
                Invoke-GraphJson -Method PATCH -Uri "/v1.0/oauth2PermissionGrants/$($existingGrant.id)" -Body @{ scope = ($scopes -join ' ') } | Out-Null
            }
        }
        else {
            Invoke-GraphJson -Method POST -Uri '/v1.0/oauth2PermissionGrants' -Body @{
                clientId = $servicePrincipalObjectId
                consentType = 'AllPrincipals'
                resourceId = $graphServicePrincipal.id
                scope = 'User.Read'
            } | Out-Null
        }
    }

    if ($AssignedGroupObjectId) {
        Write-Log INFO "Assigning group $AssignedGroupObjectId to the Enterprise Application."
        Invoke-GraphJson -Method POST -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/appRoleAssignedTo" -Body @{
            principalId = $AssignedGroupObjectId
            resourceId = $servicePrincipalObjectId
            appRoleId = $DefaultAppRoleId
        } | Out-Null
    }

    if ($AssignTestUser) {
        Write-Log INFO "Assigning test user $TestUserObjectId to the Enterprise Application."
        Invoke-GraphJson -Method POST -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/appRoleAssignedTo" -Body @{
            principalId = $TestUserObjectId
            resourceId = $servicePrincipalObjectId
            appRoleId = $DefaultAppRoleId
        } | Out-Null
    }

    Write-Log INFO 'Waiting for the Entra provisioning backend to initialise the Enterprise Application.'
    Start-Sleep -Seconds 5

    Write-Log INFO 'Retrieving the SCIM synchronization template exposed by the Enterprise Application.'
    $syncTemplates = @(Invoke-GraphCollectionWithRetry `
        -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/synchronization/templates" `
        -Description 'SCIM synchronization templates' `
        -MaxAttempts 12 `
        -InitialDelaySeconds 3)
    if ($syncTemplates.Count -eq 0) {
        throw 'The Enterprise Application does not expose a synchronization template. Entra may still be finalising the application; wait several minutes and rerun, or configure Provisioning > New configuration once in the portal.'
    }

    # Prefer the current SCIM connector template when Entra exposes it. Older tenants or
    # service principals can still expose the legacy customappsso template.
    $syncTemplate = $syncTemplates | Where-Object { $_.id -eq 'scim' } | Select-Object -First 1
    if (-not $syncTemplate) {
        $syncTemplate = $syncTemplates | Where-Object { $_.id -match 'customappsso|scim|appsso' } | Select-Object -First 1
    }
    if (-not $syncTemplate) { $syncTemplate = $syncTemplates | Select-Object -First 1 }

    Write-Log INFO "Creating synchronization job from template '$($syncTemplate.id)'."
    try {
        # The provisioning backend can lag behind the application/service-principal APIs.
        # During that window, POST /synchronization/jobs can return a temporary 401 even
        # though the delegated token contains Synchronization.ReadWrite.All.
        $syncJob = Invoke-GraphJsonWithRetry -Method POST `
            -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/synchronization/jobs" `
            -Body @{ templateId = $syncTemplate.id } `
            -Description 'SCIM synchronization job creation' `
            -AdditionalRetryStatusCodes @(401) `
            -MaxAttempts 12 `
            -InitialDelaySeconds 3
    }
    catch {
        $jobErrorText = Get-GraphErrorText -ErrorRecord $_
        if ($jobErrorText -match '(?i)401|Unauthorized') {
            throw ("Entra continued to return 401 Unauthorized while creating the synchronization job. " +
                "Confirm that the active token contains Synchronization.ReadWrite.All and that the signed-in " +
                "account holds Application Administrator, Cloud Application Administrator, Hybrid Identity " +
                "Administrator, or Global Administrator. Reconnect to Graph after activating any PIM role, " +
                "then rerun. Original error: " + $_.Exception.Message)
        }
        throw
    }

    $credentials = @(
        @{ key = 'BaseAddress'; value = $ScimTenantUrl.TrimEnd('/') }
        @{ key = 'SecretToken'; value = $plainScimToken }
    )

    $graphCredentialValidation = 'Passed'
    Write-Log INFO 'Asking Entra provisioning to validate the Bitwarden SCIM credentials.'
    try {
        Invoke-GraphJson -Method POST `
            -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/synchronization/jobs/$($syncJob.id)/validateCredentials" `
            -Body @{ credentials = $credentials } | Out-Null
        Write-Log SUCCESS 'Entra provisioning accepted the supplied SCIM credentials.'
    }
    catch {
        # Entra's generic customappsso validator probes SCIM discovery behaviour that the
        # Bitwarden organisation endpoint does not expose and can return a misleading 404.
        # Continue only because the direct authenticated /Users SCIM 2.0 test already passed.
        $message = Get-GraphErrorText -ErrorRecord $_
        $knownBitwardenValidationMismatch = $message -match '(?i)CredentialValidationUnavailable|SystemForCrossDomainIdentityManagementCredentialValidationUnavailable|HTTP/404|404 Not Found|expected HTTP/200'

        if ($directScimTest.Passed -and $knownBitwardenValidationMismatch) {
            $graphCredentialValidation = 'Warning: Entra discovery validation returned 404; direct authenticated Bitwarden /Users SCIM test passed'
            Write-Log WARN 'Entra validateCredentials could not validate Bitwarden discovery and returned CredentialValidationUnavailable/404. The authenticated Bitwarden /Users SCIM 2.0 pre-flight test passed, so the script will continue and save the credentials.'
        }
        else {
            throw
        }
    }

    Write-Log INFO 'Saving the SCIM endpoint credentials in Entra provisioning.'
    Invoke-GraphJson -Method PUT `
        -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/synchronization/secrets" `
        -Body @{ value = $credentials } | Out-Null

    if ($StartProvisioning) {
        Write-Log INFO 'Starting the SCIM synchronization job.'
        Invoke-MgGraphRequest -Method POST `
            -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/synchronization/jobs/$($syncJob.id)/start" | Out-Null
    }

    $provisionOnDemandResult = $null
    if ($ProvisionOnDemand) {
        Write-Log INFO "Running provision-on-demand for user $TestUserObjectId."
        $ruleId = Get-UserProvisioningRuleId -ServicePrincipalId $servicePrincipalObjectId -JobId $syncJob.id
        $provisionOnDemandResult = Invoke-GraphJson -Method POST `
            -Uri "/v1.0/servicePrincipals/$servicePrincipalObjectId/synchronization/jobs/$($syncJob.id)/provisionOnDemand" `
            -Body @{
                parameters = @(
                    @{
                        subjects = @(
                            @{ objectId = $TestUserObjectId; objectTypeName = 'User' }
                        )
                        ruleId = $ruleId
                    }
                )
            }
        Write-Log SUCCESS 'Provision-on-demand request completed. Review the returned steps and Bitwarden membership.'
    }

    Write-Log INFO 'Validating Entra OIDC metadata and application configuration.'
    $metadataUri = "https://login.microsoftonline.com/$($context.TenantId)/v2.0/.well-known/openid-configuration"
    $oidcMetadata = Invoke-RestMethod -Method GET -Uri $metadataUri
    if (-not $oidcMetadata.authorization_endpoint -or -not $oidcMetadata.token_endpoint) {
        throw 'The tenant OpenID configuration document did not contain the expected endpoints.'
    }

    $configuredApplication = Invoke-MgGraphRequest -Method GET `
        -Uri "/v1.0/applications/${applicationObjectId}?`$select=id,appId,displayName,signInAudience,web,requiredResourceAccess" `
        -OutputType PSObject

    if ($RedirectUri -notin @($configuredApplication.web.redirectUris)) {
        throw "OIDC validation failed because '$RedirectUri' was not found on the application registration."
    }

    $authority = "https://login.microsoftonline.com/$($context.TenantId)/v2.0"
    $clientSecretValue = [string](Get-PropertyValue -InputObject $secret -Name 'secretText')
    if (-not $clientSecretValue) {
        $clientSecretValue = [string](Get-PropertyValue -InputObject $secret -Name 'secretText')
    }

    Write-Log SUCCESS 'Bitwarden Entra OIDC and SCIM configuration completed.'
    Write-Warning 'The client secret is displayed only in this output. Store it securely.'

    [pscustomobject]@{
        DisplayName                  = $DisplayName
        TenantId                    = $context.TenantId
        ApplicationObjectId         = $applicationObjectId
        EnterpriseApplicationId     = $servicePrincipalObjectId
        ClientId                    = $configuredApplication.appId
        ClientSecret                = $clientSecretValue
        ClientSecretExpires         = Get-PropertyValue -InputObject $secret -Name 'endDateTime'
        OidcAuthority               = $authority
        OidcMetadataAddress         = $metadataUri
        OidcRedirectUri             = $RedirectUri
        OidcConfigurationTest       = 'Passed: metadata, redirect URI and application configuration validated'
        OidcEndToEndTest            = 'Pending: enter the returned values in Bitwarden, then initiate Use single sign-on from Bitwarden'
        ScimTenantUrl               = $ScimTenantUrl.TrimEnd('/')
        ScimDirectEndpointTest      = 'Passed: authenticated /Users endpoint returned a SCIM 2.0 ListResponse'
        ScimCredentialTest          = $graphCredentialValidation
        SynchronizationTemplateId   = $syncTemplate.id
        SynchronizationJobId        = $syncJob.id
        ProvisioningStarted         = [bool]$StartProvisioning
        ProvisionOnDemandRequested  = [bool]$ProvisionOnDemand
        ProvisionOnDemandResult     = $provisionOnDemandResult
    }
}
catch {
    Write-Log ERROR $_.Exception.Message

    if ($created) {
        Write-Warning "A partial application may remain. Application object: $applicationObjectId; service principal: $servicePrincipalObjectId"
    }
    throw
}
finally {
    $plainScimToken = $null
    [GC]::Collect()
}
