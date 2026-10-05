<#
.SYNOPSIS
    Downloads the latest Bitwarden desktop EXE, packages it as an Intune Win32 app,
    and uploads it to Microsoft Intune without creating assignments.

.DESCRIPTION
    Uses the IntuneWin32App PowerShell module (v1.5.0 or later).

    The script:
      - Retrieves the latest Bitwarden Desktop release from GitHub.
      - Downloads the standard Windows installer.
      - Downloads the official Bitwarden product icon.
      - Creates install, uninstall, and detection scripts.
      - Creates an .intunewin package.
      - Tests the IntuneWin32App module's current Graph session.
      - Connects to Microsoft Graph when no usable session exists.
      - Creates the Win32 application with no assignments.

.REQUIREMENTS
      - An Entra ID app registration configured for IntuneWin32App interactive auth.
      - See: https://jamesvincent.co.uk/2025/01/16/connecting-to-microsoft-graph-api-through-powershell-via-an-app-registration/
      - Delegated DeviceManagementApps.ReadWrite.All permission.
      - Redirect URI: http://localhost
      - Public client flows enabled.
      - Windows PowerShell 5.1 or PowerShell 7+
      - Local administrator rights are recommended for module installation.

.EXAMPLE
    If you establish a Graph Connection with Connect-MgGraph first, you can run the script without parameters:
    .\Publish-BitwardenIntuneWin32.ps1 

.EXAMPLE
    .\Publish-BitwardenIntuneWin32.ps1 `
        -TenantId "contoso.onmicrosoft.com" `
        -ClientId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Publish-BitwardenIntuneWin32.ps1 `
        -TenantId "00000000-0000-0000-0000-000000000000" `
        -ClientId "00000000-0000-0000-0000-000000000000" `
        -DeviceCode `
        -WorkingDirectory "C:\IntunePackaging\Bitwarden"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [System.Management.Automation.PSCredential]$ClientSecretCredential,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory = (Join-Path $env:TEMP "Bitwarden-Intune"),

    [Parameter()]
    [switch]$DeviceCode,

    [Parameter()]
    [switch]$KeepWorkingFiles,

    [Parameter()]
    [switch]$AllowDuplicateVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Script-scoped copies allow auto-detection from Get-MgContext.
$script:TenantId = $TenantId
$script:ClientId = $ClientId

# IntuneWin32App 1.5.0 contains a locale-specific token-expiry parsing issue.
# On UK systems, ExpiresOn.ToString() produces dd/MM/yyyy, while the module
# subsequently parses the value using InvariantCulture (MM/dd/yyyy).
# Temporarily use en-US for calls into the module, then restore the user's
# original culture in the script's finally block.
$script:OriginalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
$script:OriginalUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
$moduleCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
[System.Threading.Thread]::CurrentThread.CurrentCulture = $moduleCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $moduleCulture

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


function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $escapedCharacters = [regex]::Escape((-join $invalidCharacters))

    $safeName = $Name -replace "[$escapedCharacters]", '-'
    $safeName = $safeName.Trim().TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw "The application name '$Name' could not be converted into a valid file name."
    }

    return $safeName
}

function Ensure-Module {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [version]$MinimumVersion
    )

    $installed = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $installed -or ($MinimumVersion -and $installed.Version -lt $MinimumVersion)) {
        Write-Log "Installing PowerShell module '$Name'." 'INFO'

        $installParams = @{
            Name         = $Name
            Scope        = 'CurrentUser'
            Force        = $true
            AllowClobber = $true
        }

        if ($MinimumVersion) {
            $installParams.MinimumVersion = $MinimumVersion
        }

        Install-Module @installParams
    }

    Import-Module $Name -MinimumVersion $MinimumVersion -Force
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $headers = @{
        Accept               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'         = 'Bitwarden-Intune-Packager'
    }

    Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers
}

function Get-LatestBitwardenRelease {
    Write-Log 'Retrieving the latest Bitwarden Desktop release.'

    $releases = Invoke-GitHubApi -Uri 'https://api.github.com/repos/bitwarden/clients/releases?per_page=100'

    $release = $releases |
        Where-Object {
            -not $_.draft -and
            -not $_.prerelease -and
            $_.tag_name -match '^desktop-v(?<Version>\d+\.\d+\.\d+)$'
        } |
        Sort-Object {
            [version]([regex]::Match($_.tag_name, '\d+\.\d+\.\d+').Value)
        } -Descending |
        Select-Object -First 1

    if (-not $release) {
        throw 'Unable to locate a stable Bitwarden Desktop release.'
    }

    $installer = $release.assets |
        Where-Object { $_.name -match '^Bitwarden-Installer-.*\.exe$' } |
        Select-Object -First 1

    if (-not $installer) {
        throw "Release '$($release.tag_name)' does not contain the expected Windows installer asset."
    }

    [pscustomobject]@{
        Version     = [regex]::Match($release.tag_name, '\d+\.\d+\.\d+').Value
        TagName     = $release.tag_name
        ReleaseUrl  = $release.html_url
        FileName    = $installer.name
        DownloadUrl = $installer.browser_download_url
        Size        = $installer.size
    }
}

function Get-BitwardenIcon {
    param(
        [Parameter(Mandatory)]
        [string]$Destination
    )

    Write-Log 'Locating the official Bitwarden product icon.'

    $tree = Invoke-GitHubApi -Uri 'https://api.github.com/repos/bitwarden/brand/git/trees/main?recursive=1'

    $preferredPatterns = @(
        '(?i)^icons/.+rounded.+256.+\.png$',
        '(?i)^icons/.+256.+rounded.+\.png$',
        '(?i)^icons/.+square.+256.+\.png$',
        '(?i)^icons/.+256.+\.png$'
    )

    $iconItem = $null
    foreach ($pattern in $preferredPatterns) {
        $iconItem = $tree.tree |
            Where-Object { $_.type -eq 'blob' -and $_.path -match $pattern } |
            Select-Object -First 1

        if ($iconItem) {
            break
        }
    }

    if (-not $iconItem) {
        throw 'Unable to locate a suitable PNG product icon in the official Bitwarden brand repository.'
    }

    $encodedPath = ($iconItem.path -split '/' | ForEach-Object {
        [uri]::EscapeDataString($_)
    }) -join '/'

    $downloadUrl = "https://raw.githubusercontent.com/bitwarden/brand/main/$encodedPath"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $Destination -UseBasicParsing

    if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -lt 1024) {
        throw 'The Bitwarden icon download did not produce a valid image file.'
    }

    Write-Log "Downloaded icon: $($iconItem.path)" 'SUCCESS'
}

function Resolve-GraphConnectionDetails {
    <#
        TenantId and ClientId can be taken from an existing Connect-MgGraph
        session. Microsoft Graph PowerShell does not expose the client secret
        or a supported reusable access-token property through Get-MgContext.
    #>

    $mgContext = $null

    if (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue) {
        $mgContext = Get-MgContext -ErrorAction SilentlyContinue
    }

    if (-not $script:TenantId -and $mgContext -and $mgContext.TenantId) {
        $script:TenantId = [string]$mgContext.TenantId
        Write-Log "Using Tenant ID from the active Microsoft Graph connection: $script:TenantId"
    }

    if (-not $script:ClientId -and $mgContext -and $mgContext.ClientId) {
        $script:ClientId = [string]$mgContext.ClientId
        Write-Log "Using Client ID from the active Microsoft Graph connection: $script:ClientId"
    }

    if (-not $script:TenantId -or -not $script:ClientId) {
        return $null
    }

    if ($script:TenantId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Tenant ID '$script:TenantId' is not a valid GUID."
    }

    if ($script:ClientId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Client ID '$script:ClientId' is not a valid GUID."
    }

    return $mgContext
}

function ConvertFrom-SecureStringToPlainText {
    param(
        [Parameter(Mandatory)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-IntuneWin32AppConnection {
    try {
        $null = Get-IntuneWin32App `
            -DisplayName '__Bitwarden_Connection_Test__' `
            -ErrorAction Stop

        return $true
    }
    catch {
        return $false
    }
}

function Connect-IntuneGraph {
    <#
        Authentication order:

        1. Reuse an already-active IntuneWin32App connection.
        2. Read TenantId and ClientId from an active Connect-MgGraph session.
        3. For delegated Microsoft Graph sessions, attempt IntuneWin32App
           delegated authentication using the existing tenant and client IDs.
           Existing browser/broker SSO may allow this without another prompt.
        4. For app-only Microsoft Graph sessions, use the supplied
           ClientSecretCredential because Get-MgContext does not expose the
           original secret or a reusable token.
        5. Only request missing connection information when no usable context
           exists.
    #>

    Write-Log 'Checking for an existing IntuneWin32App connection.'

    if (Test-IntuneWin32AppConnection) {
        Write-Log 'Reusing the existing IntuneWin32App Microsoft Graph connection.' 'SUCCESS'
        return
    }

    $mgContext = Resolve-GraphConnectionDetails

    if (-not $mgContext) {
        throw @"
No active Microsoft Graph connection was found.

Connect first with Connect-MgGraph, or run this script with -TenantId and
-ClientId. For app-only authentication, also supply -ClientSecretCredential.
"@
    }

    Write-Log "Active Microsoft Graph connection found. AuthType: $($mgContext.AuthType)."

    $connectParams = @{
        TenantID = $script:TenantId
        ClientID = $script:ClientId
        Scopes   = @(
            'DeviceManagementApps.ReadWrite.All',
            'offline_access'
        )
    }

    if ($mgContext.AuthType -eq 'AppOnly') {
        if (-not $ClientSecretCredential) {
            throw @"
An active app-only Connect-MgGraph session was found, but its client secret is
not exposed by Get-MgContext and cannot be reused by IntuneWin32App.

Supply the existing credential object with:
    -ClientSecretCredential `$secretCredential
"@
        }

        if (
            $ClientSecretCredential.UserName -and
            $ClientSecretCredential.UserName -ne $script:ClientId
        ) {
            throw "The ClientSecretCredential username does not match Client ID '$script:ClientId'."
        }

        $plainTextSecret = ConvertFrom-SecureStringToPlainText `
            -SecureString $ClientSecretCredential.Password

        $connectParams.ClientSecret = $plainTextSecret
        Write-Log 'Using the active Graph context IDs and supplied client-secret credential.'
    }
    elseif ($DeviceCode) {
        $connectParams.DeviceCode = $true
        Write-Log 'Using device-code authentication with the active Graph context IDs.'
    }
    else {
        Write-Log 'Using delegated authentication with the active Graph context IDs.'
    }

    try {
        Connect-MSIntuneGraph @connectParams
    }
    finally {
        if (Get-Variable -Name plainTextSecret -ErrorAction SilentlyContinue) {
            $plainTextSecret = $null
        }
    }

    if (-not (Test-IntuneWin32AppConnection)) {
        throw 'Microsoft Graph authentication completed, but IntuneWin32App access could not be validated.'
    }

    Write-Log 'IntuneWin32App Microsoft Graph connection is available.' 'SUCCESS'
}

function New-PackageContent {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [Parameter(Mandatory)]
        [string]$InstallerFileName,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$SetupFileName
    )

    $installScript = @"
[CmdletBinding()]
param()

`$ErrorActionPreference = 'Stop'
`$installer = Join-Path `$PSScriptRoot '$InstallerFileName'

if (-not (Test-Path `$installer)) {
    throw "Bitwarden installer not found: `$installer"
}

`$process = Start-Process `
    -FilePath `$installer `
    -ArgumentList @('/allusers', '/S') `
    -Wait `
    -PassThru `
    -WindowStyle Hidden

exit `$process.ExitCode
"@

    $uninstallScript = @'
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$uninstallCandidates = @(
    (Join-Path $env:ProgramFiles 'Bitwarden\Uninstall Bitwarden.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Bitwarden\Uninstall Bitwarden.exe')
) | Where-Object { $_ -and (Test-Path $_) }

$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$registryEntry = Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'Bitwarden' } |
    Select-Object -First 1

if ($registryEntry -and $registryEntry.UninstallString) {
    $match = [regex]::Match($registryEntry.UninstallString, '^\s*"?(?<Path>[^"]+?\.exe)"?(?:\s|$)')
    if ($match.Success -and (Test-Path $match.Groups['Path'].Value)) {
        $uninstallCandidates = @($match.Groups['Path'].Value) + $uninstallCandidates
    }
}

$uninstaller = $uninstallCandidates | Select-Object -First 1

if (-not $uninstaller) {
    # App is already absent.
    exit 0
}

$process = Start-Process `
    -FilePath $uninstaller `
    -ArgumentList @('/allusers', '/S') `
    -Wait `
    -PassThru `
    -WindowStyle Hidden

exit $process.ExitCode
'@

    $detectionScript = @"
[CmdletBinding()]
param()

`$minimumVersion = [version]'$Version'
`$executablePaths = @(
    (Join-Path `$env:ProgramFiles 'Bitwarden\Bitwarden.exe'),
    (Join-Path `${env:ProgramFiles(x86)} 'Bitwarden\Bitwarden.exe')
) | Where-Object { `$_ }

foreach (`$path in `$executablePaths) {
    if (-not (Test-Path `$path)) {
        continue
    }

    try {
        `$installedVersionText = (Get-Item `$path).VersionInfo.ProductVersion
        `$installedVersionText = [regex]::Match(`$installedVersionText, '\d+\.\d+\.\d+').Value

        if (`$installedVersionText -and [version]`$installedVersionText -ge `$minimumVersion) {
            Write-Output "Bitwarden `$installedVersionText detected."
            exit 0
        }
    }
    catch {
        continue
    }
}

exit 1
"@

    Set-Content -Path (Join-Path $SourceDirectory $SetupFileName) -Value $installScript -Encoding UTF8
    Set-Content -Path (Join-Path $SourceDirectory 'Uninstall-Bitwarden.ps1') -Value $uninstallScript -Encoding UTF8
    Set-Content -Path (Join-Path $SourceDirectory 'Detect-Bitwarden.ps1') -Value $detectionScript -Encoding UTF8
}

try {
    Write-Log 'Starting Bitwarden Intune Win32 application publishing process.'

    Ensure-Module -Name 'IntuneWin32App' -MinimumVersion ([version]'1.5.0')

    $release = Get-LatestBitwardenRelease
    Write-Log "Latest stable Bitwarden Desktop version: $($release.Version)" 'SUCCESS'

    $sourceDirectory = Join-Path $WorkingDirectory 'Source'
    $outputDirectory = Join-Path $WorkingDirectory 'Output'
    $iconPath = Join-Path $WorkingDirectory 'Bitwarden.png'

    if (Test-Path $WorkingDirectory) {
        Remove-Item -Path $WorkingDirectory -Recurse -Force
    }

    New-Item -Path $sourceDirectory -ItemType Directory -Force | Out-Null
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null

    $installerPath = Join-Path $sourceDirectory $release.FileName

    Write-Log "Downloading $($release.FileName)."
    Invoke-WebRequest -Uri $release.DownloadUrl -OutFile $installerPath -UseBasicParsing

    if ((Get-Item $installerPath).Length -ne $release.Size) {
        throw 'Downloaded installer size does not match the release metadata.'
    }

    Unblock-File -Path $installerPath -ErrorAction SilentlyContinue
    Write-Log 'Bitwarden installer downloaded successfully.' 'SUCCESS'

    Get-BitwardenIcon -Destination $iconPath

    $displayName = "Bitwarden $($release.Version)"
    $safeApplicationName = ConvertTo-SafeFileName -Name $displayName
    $setupFileName = "$safeApplicationName.ps1"

    New-PackageContent `
        -SourceDirectory $sourceDirectory `
        -InstallerFileName $release.FileName `
        -Version $release.Version `
        -SetupFileName $setupFileName

    Write-Log 'Creating the .intunewin package.'
    $package = New-IntuneWin32AppPackage `
        -SourceFolder $sourceDirectory `
        -SetupFile $setupFileName `
        -OutputFolder $outputDirectory `
        -Verbose

    $intuneWinFile = $package.Path
    if (-not $intuneWinFile -or -not (Test-Path $intuneWinFile)) {
        $intuneWinFile = Get-ChildItem -Path $outputDirectory -Filter '*.intunewin' |
            Select-Object -ExpandProperty FullName -First 1
    }

    if (-not $intuneWinFile -or -not (Test-Path $intuneWinFile)) {
        throw 'The Intune Win32 package was not created.'
    }

    # Rename the generated package so it matches the Intune application name.
    $renamedIntuneWinFile = Join-Path $outputDirectory "$safeApplicationName.intunewin"

    if ($intuneWinFile -ne $renamedIntuneWinFile) {
        if (Test-Path $renamedIntuneWinFile) {
            Remove-Item -Path $renamedIntuneWinFile -Force
        }

        Move-Item `
            -Path $intuneWinFile `
            -Destination $renamedIntuneWinFile `
            -Force

        $intuneWinFile = $renamedIntuneWinFile
    }

    Write-Log "Package renamed to: $(Split-Path $intuneWinFile -Leaf)" 'SUCCESS'

    Connect-IntuneGraph

    if (-not $AllowDuplicateVersion) {
        $existingApps = @(Get-IntuneWin32App -DisplayName $displayName -ErrorAction Stop)
        $exactMatch = $existingApps | Where-Object { $_.displayName -eq $displayName }

        if ($exactMatch) {
            throw "An Intune Win32 app named '$displayName' already exists. Use -AllowDuplicateVersion to override this check."
        }
    }

    $detectionRule = New-IntuneWin32AppDetectionRuleScript `
        -ScriptFile (Join-Path $sourceDirectory 'Detect-Bitwarden.ps1') `
        -EnforceSignatureCheck $false `
        -RunAs32Bit $false

    $requirementRule = New-IntuneWin32AppRequirementRule `
        -Architecture 'AllWithARM64' `
        -MinimumSupportedWindowsRelease 'W10_21H2'

    $icon = New-IntuneWin32AppIcon -FilePath $iconPath

    $installCommand = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `".\$setupFileName`""
    $uninstallCommand = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Uninstall-Bitwarden.ps1"'

    Write-Log "Uploading '$displayName' to Microsoft Intune."

    # The module can emit a non-standard or multi-item pipeline result even
    # after a successful upload. Do not depend on Add-IntuneWin32App returning
    # a single object with an id property.
    $null = Add-IntuneWin32App `
        -FilePath $intuneWinFile `
        -DisplayName $displayName `
        -Description "Bitwarden Password Manager desktop application. Version $($release.Version). Packaged automatically from the official Bitwarden GitHub release." `
        -Publisher 'Bitwarden Inc.' `
        -AppVersion $release.Version `
        -InformationURL 'https://bitwarden.com/products/personal/' `
        -PrivacyURL 'https://bitwarden.com/privacy/' `
        -Developer 'Bitwarden Inc.' `
        -Owner 'IT' `
        -Notes "Source release: $($release.ReleaseUrl). No assignments were created by the publishing script." `
        -InstallExperience 'system' `
        -RestartBehavior 'suppress' `
        -MaximumInstallationTimeInMinutes 5 `
        -InstallCommandLine $installCommand `
        -UninstallCommandLine $uninstallCommand `
        -DetectionRule $detectionRule `
        -RequirementRule $requirementRule `
        -Icon $icon `
        -Verbose

    # Graph can be eventually consistent immediately after a Win32 app upload.
    # Retry the lookup rather than relying on a single fixed delay.
    $uploadedApps = @()
    $lookupAttempts = 8
    $maximumLookupDelaySeconds = 30

    for ($attempt = 1; $attempt -le $lookupAttempts; $attempt++) {
        Write-Log "Looking up the uploaded Intune application (attempt $attempt of $lookupAttempts)."

        try {
            $uploadedApps = @(
                Get-IntuneWin32App -DisplayName $displayName -ErrorAction Stop |
                    Where-Object {
                        $_.PSObject.Properties.Name -contains 'displayName' -and
                        $_.displayName -eq $displayName
                    }
            )
        }
        catch {
            Write-Log "Application lookup attempt $attempt failed: $($_.Exception.Message)" 'WARN'
            $uploadedApps = @()
        }

        if ($uploadedApps.Count -gt 0) {
            break
        }

        if ($attempt -lt $lookupAttempts) {
            $lookupDelaySeconds = [int][Math]::Min(
                $maximumLookupDelaySeconds,
                2 * [Math]::Pow(2, ($attempt - 1))
            )

            Write-Log "The application is not visible yet; waiting $lookupDelaySeconds seconds before retrying." 'WARN'
            Start-Sleep -Seconds $lookupDelaySeconds
        }
    }

    if ($uploadedApps.Count -eq 0) {
        throw "The upload completed, but '$displayName' was not returned by the Intune list endpoint after $lookupAttempts attempts."
    }

    $app = $uploadedApps |
        Sort-Object -Property @{
            Expression = {
                if ($_.PSObject.Properties.Name -contains 'createdDateTime') {
                    try { [datetimeoffset]$_.createdDateTime }
                    catch { [datetimeoffset]::MinValue }
                }
                else {
                    [datetimeoffset]::MinValue
                }
            }
            Descending = $true
        } |
        Select-Object -First 1

    $appId = if ($app.PSObject.Properties.Name -contains 'id') {
        [string]$app.id
    }
    else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($appId)) {
        throw "The application '$displayName' was retrieved, but its Intune ID was missing."
    }

    # IntuneWin32App creates the app-level fileName property from the package
    # metadata, which Microsoft IntuneWinAppUtil records as
    # "IntunePackage.intunewin". Correct that property after upload so the
    # Intune admin centre shows a meaningful package filename.
    $desiredPackageFileName = "$safeApplicationName.intunewin"
    $fileNamePatchBody = @{
        '@odata.type' = '#microsoft.graph.win32LobApp'
        fileName      = $desiredPackageFileName
    } | ConvertTo-Json

    Write-Log "Updating the Intune package filename to '$desiredPackageFileName'."

    if (-not (Get-Command -Name Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw @"
Invoke-MgGraphRequest is unavailable. Install or import the
Microsoft.Graph.Authentication module before running this script.
"@
    }

    try {
        $null = Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId" `
            -Body $fileNamePatchBody `
            -ContentType 'application/json' `
            -ErrorAction Stop
    }
    catch {
        throw "The application was uploaded, but its displayed package filename could not be updated: $($_.Exception.Message)"
    }

    # Confirm the app-level fileName property was updated.
    $updatedApp = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId" `
        -OutputType PSObject `
        -ErrorAction Stop

    if (
        -not ($updatedApp.PSObject.Properties.Name -contains 'fileName') -or
        $updatedApp.fileName -ne $desiredPackageFileName
    ) {
        throw "The filename PATCH completed, but Intune still reports '$($updatedApp.fileName)' instead of '$desiredPackageFileName'."
    }

    Write-Log "Created Intune Win32 app '$displayName'." 'SUCCESS'
    Write-Log "Application ID: $appId" 'SUCCESS'
    Write-Log 'Maximum installation time: 5 minutes.' 'SUCCESS'
    Write-Log 'No application assignments were created.' 'SUCCESS'

    [pscustomobject]@{
        DisplayName             = $displayName
        Version                 = $release.Version
        IntuneAppId             = $appId
        Installer               = $release.FileName
        IntuneWinFile           = $intuneWinFile
        MaximumInstallMinutes   = 5
        PackageFileName         = $desiredPackageFileName
        Assigned                = $false
        ReleaseUrl              = $release.ReleaseUrl
    }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
}
finally {
    if (-not $KeepWorkingFiles -and (Test-Path $WorkingDirectory)) {
        Write-Log "Removing working directory: $WorkingDirectory"
        Remove-Item -Path $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path $WorkingDirectory) {
        Write-Log "Working files retained at: $WorkingDirectory"
    }

    # Restore the culture that was active before the script started.
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:OriginalCulture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $script:OriginalUICulture
}
