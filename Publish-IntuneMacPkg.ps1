<#
.SYNOPSIS
    Downloads a macOS .PKG or .DMG, extracts metadata, then creates and uploads a macOS PKG (LOB) app into Microsoft Intune via Microsoft Graph.
    Optionally assigns the app to an Azure AD group and optionally cleans up local working files.

.DESCRIPTION
    This script automates the end-to-end packaging workflow for macOS PKG applications in Intune:
      - Downloads the PKG and logo assets
      - Ensures required tooling exists (Microsoft Graph PowerShell SDK, 7-Zip, AzCopy)
      - Extracts PKG metadata (BundleId, Version)
      - Creates a macOSPkgApp in Intune
      - Creates a content version + content file entry
      - Encrypts the PKG in the Intune LOB format and uploads via AzCopy
      - Commits the upload and sets committedContentVersion
      - Waits for publish completion
      - Assigns the app to a specified group (Available/Required/Uninstall)
      - Supports -WhatIf / -Confirm for safe dry runs (for actions wrapped with ShouldProcess)
      - Optionally cleans up working directories with -Cleanup

.NOTES
    Author:        James Vincent
    Created:       2026-02-13
    Last Updated:  2026-02-13
    Version:       1.0.0
    License:       Internal / Use at your own risk
    Requirements:
        - Windows PowerShell 5.1+ (PowerShell 7+ supported)
        - Microsoft.Graph.Authentication module (auto-installed if missing)
        - Network access to:
            * PKG/Logo download URL
            * graph.microsoft.com (Intune / Graph API)
            * aka.ms (AzCopy download)
            * 7-zip.org (7-Zip download, if needed)
        - Permissions:
            * Microsoft Graph scope: DeviceManagementApps.ReadWrite.All
            * Ability to create mobile apps and assignments in Intune

    Important:
        - Some external tools (7z.exe, azcopy.exe, curl.exe) may emit console output even under redirection in some environments.

.PARAMETER Cleanup
    If specified, removes the working directory ($WorkRoot) at the end of a successful run.

.EXAMPLE
    # Run end-to-end (interactive Graph login if required)
    .\Publish-IntuneMacPkg.ps1

.EXAMPLE
    # Run and remove working files at the end
    .\Publish-IntuneMacPkg.ps1 -Cleanup

.LINK
    Microsoft Graph PowerShell SDK:
    https://learn.microsoft.com/powershell/microsoftgraph/overview

.LINK
    Intune app management (Graph):
    https://learn.microsoft.com/graph/api/resources/intune-apps-conceptual

#>
[CmdletBinding()]
param(
    # ================= APPLICATION DETAILS =================
    # PKG Example:
    [string]$AppName            = "Zoom",
    [string]$Publisher          = "Zoom",
    [string]$AppDownloadUrl     = "https://zoom.us/client/latest/Zoom.pkg",
    [string]$AppLogoDownloadUrl = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/11/Zoom_Logo_2022.svg/500px-Zoom_Logo_2022.svg.png",
    [string]$AppHomepage        = "https://www.zoom.com/",
    [string]$IntuneGroup        = "f75ce629-e22b-4467-980e-620917188f0b", #Can be either group name or GUID, e.g. "All Mac Devices" or "f75ce629-e22b-4467-980e-620917188f0b"
    # DMG Example:
    # [string]$AppName            = "VLC Media Player",
    # [string]$Publisher          = "VideoLAN",
    # [string]$AppDownloadUrl     = "https://get.videolan.org/vlc/3.0.23/macosx/vlc-3.0.23-universal.dmg",
    # [string]$AppLogoDownloadUrl = "https://upload.wikimedia.org/wikipedia/commons/3/38/VLC_icon.png",
    # [string]$AppHomepage        = "https://www.videolan.org/",
    # [string]$IntuneGroup        = "All Mac Devices", #Can be either group name or GUID, e.g. "All Mac Devices" or "f75ce629-e22b-4467-980e-620917188f0b"
    # Installation intent:
    [ValidateSet("Available","Required","Uninstall")]
    [string]$InstallMode        = "Available",
    # ================= GRAPH CONNECTION =================
    [string]$ExternalConnectScript = "C:\Temp\Connect-Graph.ps1",
    [string]$AppID = "",
    [string]$TenantID = "",
    [string]$Secret = "",
    #
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'

# Graph Connection Options
$RequiredScopes = "DeviceManagementApps.ReadWrite.All"
# Working paths
$WorkRoot               = "C:\Temp\IntuneMacPkg"
$Source                 = Join-Path $WorkRoot "$AppName\Source"
$Output                 = Join-Path $WorkRoot "$AppName\Output"
$LogoPath               = Join-Path $WorkRoot "$AppName\logo.png"
$AzCopyDir              = Join-Path $WorkRoot "AzCopy"
$SevenZipPath           = "$env:ProgramFiles\7-Zip\7z.exe"
$SevenZipDownloadUrl    = "https://www.7-zip.org/download.html"
# Logging
$LogsDir = Join-Path $WorkRoot "Logs"
$LogPath = Join-Path $LogsDir ("{0}_{1}.log" -f ($AppName -replace '[\\/:*?"<>|]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:LogPath = $LogPath

# ================= FUNCTIONS =================
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO',

        [string]$Path = $script:LogPath,

        [switch]$NoHost,

        [switch]$AsError
    )
    # Function for creating log entries with timestamp and level, writing to a log file
    # and optionally to the host with colour coding.
    # First of all, ensure the log path exists
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "{0} [{1}] {2}" -f $ts, $Level, $Message
    # Append to log file (with error handling to avoid script failure if logging fails)
    try {
        Add-Content -Path $Path -Value $line -Encoding UTF8
    }
    catch {
        if (-not $NoHost) {
            Write-Host "[$ts] [WARN] Failed to write to log file '$Path': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($NoHost) { return }
    # Write-Host colours pre-defined by log level
    $colour = switch ($Level) {
        'INFO'    { 'Cyan' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'DarkGray' }
        default   { 'White' }
    }

    if ($AsError -or $Level -eq 'ERROR') {
        # Error message to log and host, but don't throw an exception 
        # (unless -AsError is specified, which is for critical errors that should also throw)
        Write-Error $Message
        Write-Host $line -ForegroundColor $colour
    }
    else {
        Write-Host $line -ForegroundColor $colour
    }
}


function Get-ChildItemLimitedDepth {
    <#
    .SYNOPSIS
        Depth-limited directory traversal compatible with Windows PowerShell 5.1.

    .DESCRIPTION
        PowerShell 7 has Get-ChildItem -Depth, but Windows PowerShell 5.1 does not.
        This helper walks directories breadth-first up to MaxDepth and emits items.

    .PARAMETER Path
        Root path to start traversal.

    .PARAMETER MaxDepth
        Maximum child depth to traverse.

    .PARAMETER Filter
        Optional leaf-name filter (e.g. 'Info.plist').

    .PARAMETER DirectoriesOnly
        If set, only directories are returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][ValidateRange(0,100)][int]$MaxDepth = 10,
        [Parameter()][string]$Filter,
        [switch]$DirectoriesOnly
    )

    if (-not (Test-Path $Path)) { return }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Path, 0))

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $currentPath = $item[0]
        $depth = [int]$item[1]

        $children = @()
        try {
            if ($Filter) {
                $children = Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue -Filter $Filter
            } else {
                $children = Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            continue
        }

        foreach ($c in $children) {
            if ($DirectoriesOnly -and -not $c.PSIsContainer) { continue }
            $c
        }

        if ($depth -ge $MaxDepth) { continue }

        $dirs = @()
        try {
            $dirs = Get-ChildItem -LiteralPath $currentPath -Directory -Force -ErrorAction SilentlyContinue
        } catch {
            $dirs = @()
        }

        foreach ($d in $dirs) {
            $queue.Enqueue(@($d.FullName, $depth + 1))
        }
    }
}

# --- Ensure Info.plist metadata helper is available at script scope (for DMG parsing)
function Get-AppMetadataFromInfoPlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InfoPlistPath
    )

    if (-not (Test-Path $InfoPlistPath)) { throw "Info.plist not found: $InfoPlistPath" }

    # Try XML plist first (common in some DMGs)
    try {
        [xml]$xml = Get-Content -Path $InfoPlistPath -ErrorAction Stop
        $dict = @{}
        $dictNode = $xml.SelectSingleNode("/plist/dict")
        if ($dictNode) {
            $nodes = @($dictNode.ChildNodes)
            for ($i = 0; $i -lt $nodes.Count; $i++) {
                if ($nodes[$i].Name -eq "key" -and ($i + 1) -lt $nodes.Count) {
                    $k = $nodes[$i].InnerText
                    $v = $nodes[$i + 1]
                    switch ($v.Name) {
                        "string"  { $dict[$k] = $v.InnerText }
                        "integer" { $dict[$k] = $v.InnerText }
                        default   { }
                    }
                }
            }
        }
        if ($dict.ContainsKey("CFBundleIdentifier")) {
            return @{
                BundleId = $dict["CFBundleIdentifier"]
                Version  = (if ($dict.ContainsKey("CFBundleShortVersionString")) { $dict["CFBundleShortVersionString"] } else { $dict["CFBundleVersion"] })
            }
        }
    } catch { }

    # Fallback: binary plist (most common)
    $root = Read-BinaryPlist -Path $InfoPlistPath
    if ($root -isnot [hashtable]) { throw "Unexpected plist root object type in $InfoPlistPath" }

    $bundleId = $root["CFBundleIdentifier"]
    $version  = $root["CFBundleShortVersionString"]
    if (-not $version) { $version = $root["CFBundleVersion"] }

    if (-not $bundleId) { throw "CFBundleIdentifier not found in $InfoPlistPath" }
    if (-not $version)  { $version = "0.0" }

    return @{ BundleId = [string]$bundleId; Version = [string]$version }
}


function Connect-ToGraph {
    [CmdletBinding()]
    param()

    Write-Log "Checking Microsoft Graph connection method..." -Level INFO
    # Attempt multiple connection methods in order, with fallback if credentials/methods are not supplied or fail. 
    # The first successful connection will be used for the rest of the script.
    # ===== Method 1: External script =====
    if ($ExternalConnectScript -and (Test-Path $ExternalConnectScript)) {
        Write-Log "Using external Graph connection script: $ExternalConnectScript" -Level INFO
        try {
            . $ExternalConnectScript
            return
        }
        catch {
            Write-Log "External connection script failed: $_" -Level WARN
        }
    } else {
        Write-Log "External connection script not found, trying next authentication method." -Level INFO
    }

    # ===== Method 2: App registration =====
    if ($AppID -and $TenantID -and $Secret) {
        Write-Log "Using App Registration authentication..." -Level INFO
        try {
            $SecureSecret = ConvertTo-SecureString $Secret -AsPlainText -Force
            $Credential = New-Object System.Management.Automation.PSCredential($AppID, $SecureSecret)

            Connect-MgGraph `
                -TenantId $TenantID `
                -ClientSecretCredential $Credential `
                -NoWelcome

            return
        }
        catch {
            Write-Log "App Registration authentication failed: $_" -Level WARN
        }
    } else {
        Write-Log "App Registration details not supplied, trying next authentication method." -Level INFO
    }

    # ===== Method 3: Interactive =====
    Write-Log "Falling back to interactive login..." -Level INFO
    Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All"
}

function Test-MgGraphConnection {
    [CmdletBinding()]
    param(
        # One or more scopes you expect to be present on the current Graph context
        [Parameter(Mandatory)]
        [string[]]$RequiredScopes,
        # If set, throw when not connected or missing scopes
        [switch]$ThrowOnFail
    )
    # Function that performs basic checks to determine if we're connected to Microsoft Graph 
    # and have the required scopes in the current context.
    if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) {
        $msg = "Microsoft Graph PowerShell SDK not available (Get-MgContext not found). Install/Import Microsoft.Graph.Authentication."
        if ($ThrowOnFail) { throw $msg }
        return [pscustomobject]@{
            Connected     = $false
            TenantId      = $null
            Account       = $null
            AuthType      = $null
            Required      = $RequiredScopes
            Granted       = @()
            Missing       = $RequiredScopes
            HasAllScopes  = $false
            Message       = $msg
        }
    }

    $ctx = Get-MgContext

    if (-not $ctx) {
        $msg = "Not connected to Microsoft Graph."
        if ($ThrowOnFail) { throw $msg }
        return [pscustomobject]@{
            Connected     = $false
            TenantId      = $null
            Account       = $null
            AuthType      = $null
            Required      = $RequiredScopes
            Granted       = @()
            Missing       = $RequiredScopes
            HasAllScopes  = $false
            Message       = $msg
        }
    }
    # Scopes can be null/empty depending on auth flow (e.g., app-only). Normalise.
    $granted = @()
    if ($ctx.Scopes) { $granted = @($ctx.Scopes) }
    # Compare text case
    $missing = @()
    foreach ($s in $RequiredScopes) {
        if (-not ($granted -contains $s)) {
            # Try case-insensitive match
            if (-not ($granted | Where-Object { $_.ToString().Equals($s, [System.StringComparison]::OrdinalIgnoreCase) })) {
                $missing += $s
            }
        }
    }

    $hasAll = ($missing.Count -eq 0)

    $msg = if ($hasAll) {
        "Connected to Microsoft Graph with all required scopes."
    } else {
        if ($granted.Count -eq 0) {
            "Connected to Microsoft Graph, but scopes are not present in the context (common with app-only auth)."
        } else {
            "Connected to Microsoft Graph, but missing required scopes: $($missing -join ', ')"
        }
    }

    if ($ThrowOnFail -and (-not $hasAll)) { throw $msg }

    [pscustomobject]@{
        Connected     = $true
        TenantId      = $ctx.TenantId
        Account       = $ctx.Account
        AuthType      = $ctx.AuthType
        Required      = $RequiredScopes
        Granted       = $granted
        Missing       = $missing
        HasAllScopes  = $hasAll
        Message       = $msg
    }
}

function Install-ModuleIfMissing {
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "$Name not found. Installing..." -Level INFO 
        Install-Module $Name -Scope CurrentUser -Force
    }
    # Function to check if the specified PowerShell module is installed, and if not, 
    # install it from the PowerShell Gallery. Finally import the module.
    Import-Module $Name -Force
}

function New-CleanDirectory($Path) {
    # Function to create a new, empty directory at the specified path. 
    # If the directory already exists, it will be removed and recreated.
    if (Test-Path $Path) { 
        Remove-Item $Path -Recurse -Force 
    }
    New-Item -ItemType Directory -Path $Path | Out-Null
}

function Get-FileNameFromUrl {
    param(
        [Parameter(Mandatory)][string]$Url
    )
    # Function to get a filename from a URL, following redirects if necessary. 
    # If the URL does not contain a filename, error - we need a file! 
    try {
        # Follow redirects to get the final filename
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "HEAD"
        $response = $request.GetResponse()
        $finalUrl = $response.ResponseUri.AbsoluteUri
        $response.Close()
    }
    catch {
        $finalUrl = $Url
    }

    $fileName = [IO.Path]::GetFileName($finalUrl)

    if ($fileName -match '\?') {
        $fileName = $fileName.Split('?')[0]
    }

    if (-not $fileName) {
        Write-Log "Could not determine filename from URL: $Url" -Level ERROR -AsError
        throw
    }

    return $fileName
}

function Save-FileFromUrl {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter()]
        [string]$DestinationFolder,

        [Parameter()]
        [string]$DestinationPath,

        [Parameter()]
        [int]$MaxRetries = 4,

        [Parameter()]
        [int]$TimeoutSec = 15,

        [Parameter()]
        [hashtable]$Headers
    )

    $ErrorActionPreference = 'Stop'

    if (-not $DestinationPath -and -not $DestinationFolder) {
        throw "Specify -DestinationFolder or -DestinationPath."
    }

    if ($DestinationFolder -and -not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }

    if (-not $DestinationPath) {
        $fileName = [System.IO.Path]::GetFileName(([System.Uri]$Url).AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "download.bin" }
        $DestinationPath = Join-Path $DestinationFolder $fileName
    } else {
        $parent = Split-Path $DestinationPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    # Best-effort HEAD content length
    $expectedLength = $null
    try {
        $head = [System.Net.HttpWebRequest]::Create($Url)
        $head.Method = "HEAD"
        $head.AllowAutoRedirect = $true
        $head.Timeout = $TimeoutSec * 1000
        if ($Headers) { foreach ($k in $Headers.Keys) { $head.Headers[$k] = $Headers[$k] } }
        $resp = $head.GetResponse()
        $expectedLength = $resp.ContentLength
        $resp.Close()
    } catch {
        $expectedLength = $null
    }

    function Test-DownloadedFileOk {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter()][object]$ExpectedLength
        )
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -le 0) { return $false }
        if ($ExpectedLength -ne $null -and [int64]$ExpectedLength -gt 0) {
            if ($len -ne [int64]$ExpectedLength) { return $false }
        }
        return $true
    }

    if (Test-DownloadedFileOk -Path $DestinationPath -ExpectedLength $expectedLength) {
        return $DestinationPath
    }

    # IMPORTANT: download to TEMP first, then move to destination
    $tempName = "dl_{0}_{1}" -f ([guid]::NewGuid().ToString("N")), ([IO.Path]::GetFileName($DestinationPath))
    $tmp = Join-Path $env:TEMP $tempName

    $methods = @("CURL", "BITS", "IWR")
    $lastError = $null

    foreach ($method in $methods) {
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            $delay = [Math]::Min(30, [Math]::Pow(2, $attempt))

            try {
                if (-not $PSCmdlet.ShouldProcess($DestinationPath, "Download via $method from $Url")) {
                    return $DestinationPath
                }

                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

                switch ($method) {
                    "CURL" {
                        $curl = Join-Path $env:WINDIR "System32\curl.exe"
                        if (-not (Test-Path -LiteralPath $curl)) { $curl = "curl.exe" }
                        if (-not (Get-Command $curl -ErrorAction SilentlyContinue)) { throw "curl.exe not available" }

                        $curlArgs = @(
                            '--location'
                            '--fail'
                            '--retry', '6'
                            '--retry-delay', '1'
                            '--connect-timeout', '20'
                            '--max-time', "$TimeoutSec"
                            '--output', $tmp
                            $Url
                        )

                        if ($Headers) {
                            foreach ($k in $Headers.Keys) {
                                $curlArgs = @('--header', ("{0}: {1}" -f $k, $Headers[$k])) + $curlArgs
                            }
                        }

                        $p = Start-Process -FilePath $curl -ArgumentList $curlArgs -Wait -PassThru -NoNewWindow
                        if ($p.ExitCode -ne 0) { throw "curl.exe failed with exit code $($p.ExitCode)" }
                    }

                    "BITS" {
                        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                            Start-BitsTransfer -Source $Url -Destination $tmp -ErrorAction Stop
                        } else {
                            throw "BITS not available"
                        }
                    }

                    "IWR" {
                        $iwrParams = @{
                            Uri                = $Url
                            OutFile            = $tmp
                            MaximumRedirection = 10
                            TimeoutSec         = $TimeoutSec
                            ErrorAction        = 'Stop'
                        }
                        if ($Headers) { $iwrParams.Headers = $Headers }
                        if ($PSVersionTable.PSVersion.Major -lt 6) { $iwrParams.UseBasicParsing = $true }
                        Invoke-WebRequest @iwrParams | Out-Null
                    }
                }

                if (Test-DownloadedFileOk -Path $tmp -ExpectedLength $expectedLength) {
                    Move-Item -LiteralPath $tmp -Destination $DestinationPath -Force
                    return $DestinationPath
                }

                throw "Downloaded file failed validation (size mismatch/empty)."
            }
            catch {
                $lastError = $_
                if ($attempt -ge $MaxRetries) { break }
                Start-Sleep -Seconds $delay
            }
        }
    }

    if ($lastError) { throw $lastError }
    throw "Failed to download $Url to $DestinationPath after trying: $($methods -join ', ')"
}

function Install-AzCopy {
    # Function to detect and install AzCopy if not already present in $AzCopyDir. 
    # Downloads the latest AzCopy v10 from Microsoft and extracts it.
    # We need AzCopy to upload the macOS PKG content file to the Intune content storage endpoint, 
    # as it supports the required authentication and large file uploads with resume support.
    $AzCopyExe = Join-Path $AzCopyDir "azcopy.exe"
    if (Test-Path $AzCopyExe) { 
        return 
    }
    $ZipPath = Join-Path $WorkRoot "azcopy.zip"
    Invoke-WebRequest "https://aka.ms/downloadazcopy-v10-windows" -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $WorkRoot -Force
    Remove-Item $ZipPath -Force
    $folder = Get-ChildItem $WorkRoot -Directory | Where-Object Name -like "azcopy*" | Select-Object -First 1
    Rename-Item $folder.FullName $AzCopyDir
}

function Install-7ZipIfMissing {
    param(
        [Parameter(Mandatory)] [string] $SevenZipPath,
        [Parameter(Mandatory)] [string] $SevenZipDownloadUrl
    )
    # Function to detect and install 7-Zip if not already present at $SevenZipPath.
    # We need 7-Zip to extract the macOS PKG and read its metadata.
    if (Test-Path -LiteralPath $SevenZipPath) {
        Write-Log "7-Zip already present: $SevenZipPath" -Level INFO
        return
    }

    Write-Log "7z.exe not found at: $SevenZipPath" -Level WARN
    Write-Log "Fetching installer link from: $SevenZipDownloadUrl" -Level INFO

    try {
        $html = Invoke-WebRequest -Uri $SevenZipDownloadUrl -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Log "Failed to download 7-Zip download page. $($_.Exception.Message)" -Level ERROR
        throw "Failed to download 7-Zip download page. $($_.Exception.Message)"
    }

    # Find a 64-bit Windows .exe installer link (e.g. a/7z2409-x64.exe)
    $match = [regex]::Match($html.Content, '(?im)href\s*=\s*"(?<url>[^"]+7z\d{3,5}-x64\.exe)"')
    if (-not $match.Success) {
        throw "Could not find a 64-bit .exe installer link on the 7-Zip download page."
    }

    $installerUrl = $match.Groups['url'].Value
    if ($installerUrl -notmatch '^https?://') {
        $base = [Uri]$SevenZipDownloadUrl
        $installerUrl = (New-Object Uri($base, $installerUrl)).AbsoluteUri
    }

    Write-Log "Installer found: $installerUrl" -Level INFO

    $tempInstaller = Join-Path $env:TEMP ("7zip-" + [guid]::NewGuid().ToString() + ".exe")

    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $tempInstaller -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded installer to: $tempInstaller" -Level INFO
    } catch {
        throw "Failed to download installer. $($_.Exception.Message)"
    }

    Write-Log "Installing 7-Zip silently..." -Level INFO
    try {
        $proc = Start-Process -FilePath $tempInstaller -ArgumentList "/S" -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -ne 0) {
            Write-Log "Installer exited with code $($proc.ExitCode)." -Level ERROR
            throw "Installer exited with code $($proc.ExitCode)."
        }
    } catch {
        Write-Log "Failed to run installer. $($_.Exception.Message)" -Level ERROR
        throw "Failed to run installer. $($_.Exception.Message)"
    }

    # Verify 7-zip install
    if (-not (Test-Path -LiteralPath $SevenZipPath)) {
        Write-Log "Install completed but 7z.exe still not found at: $SevenZipPath" -Level ERROR
        throw "Install completed but 7z.exe still not found at: $SevenZipPath"
    }

    Write-Log "7-Zip installed successfully: $SevenZipPath" -Level SUCCESS
}

function Expand-Pkg {
    [CmdletBinding()]
    param()
    # Function that uses 7-Zip to extract the macOS PKG to a specified output directory.
    if (!($SevenZipPath)) {
        Write-Log "Defining 7-zip path" -Level INFO
        $SevenZipPath = "$env:ProgramFiles\7-Zip\7z.exe"
    }
    # Validate 7-Zip exists
    if (-not (Test-Path $SevenZipPath)) {
        throw "7-Zip not found at $SevenZipPath"
    }
    # Validate package exists
    if (-not (Test-Path $PkgPath)) {
        throw "Package not found: $PkgPath"
    }
    # Create output folder if needed
    if (-not (Test-Path $Output)) {
        New-Item -ItemType Directory -Path $Output -Force | Out-Null
    }

    Write-Log "Extracting $PkgPath" -Level INFO

    $arguments = @(
        'x'
        "`"$PkgPath`""
        "-o`"$Output`""
        '-y'
    )

    & $SevenZipPath $arguments | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Log "7-Zip extraction failed with exit code $LASTEXITCODE" -Level ERROR
        throw "7-Zip extraction failed with exit code $LASTEXITCODE"
    }

    Write-Log "Extraction complete." -Level SUCCESS
}

function Get-PkgMetadata {
    # Function to get metadata (BundleId and Version) from the extracted PKG contents.
    $packageInfo = Get-ChildItem -Path $Output -Recurse -Filter "PackageInfo" | Select-Object -First 1
    if (-not $packageInfo) { 
        throw "PackageInfo not found" 
    }
}

function Convert-BigEndianToUInt64 {
    param([byte[]]$Bytes)
    # Converts up to 8 bytes (big endian) into UInt64
    $v = [UInt64]0
    foreach ($b in $Bytes) {
        $v = ($v -shl 8) -bor [UInt64]$b
    }
    return $v
}

function Read-BinaryPlistObject {
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [Parameter(Mandatory)][UInt64[]]$Offsets,
        [Parameter(Mandatory)][int]$OffsetSize,
        [Parameter(Mandatory)][int]$ObjectRefSize,
        [Parameter(Mandatory)][UInt64]$ObjRef
    )

    function Read-IntBE([byte[]]$buf, [int]$start, [int]$count) {
        $slice = $buf[$start..($start+$count-1)]
        return Convert-BigEndianToUInt64 -Bytes $slice
    }

    function Read-ObjRefList([byte[]]$buf, [int]$start, [int]$count, [int]$refSize) {
        $refs = New-Object System.Collections.Generic.List[UInt64]
        for ($i=0; $i -lt $count; $i++) {
            $refs.Add((Read-IntBE $buf ($start + ($i*$refSize)) $refSize))
        }
        return ,$refs.ToArray()
    }

    $offset = $Offsets[$ObjRef]
    $marker = $Data[$offset]
    $objType = ($marker -band 0xF0) -shr 4
    $objInfo = ($marker -band 0x0F)

    # helper: read "count" for arrays/dicts/strings when objInfo==0xF
    function Read-CountAndOffset([UInt64]$off, [int]$info) {
        if ($info -ne 0xF) { return @{ Count=[UInt64]$info; Offset=($off+1) } }
        $lenMarker = $Data[$off+1]
        $lenType = ($lenMarker -band 0xF0) -shr 4
        $lenInfo = ($lenMarker -band 0x0F)
        if ($lenType -ne 0x1) { throw "Unsupported length object type in bplist: $lenType" }
        $intBytes = [int][math]::Pow(2, $lenInfo)
        $count = Convert-BigEndianToUInt64 -Bytes $Data[($off+2)..($off+1+$intBytes)]
        return @{ Count=[UInt64]$count; Offset=($off+2+$intBytes) }
    }

    switch ($objType) {
        0x0 { # simple
            switch ($objInfo) {
                0x0 { return $null } # null
                0x8 { return $false }
                0x9 { return $true }
                default { throw "Unsupported simple object in bplist: 0x$('{0:X}' -f $objInfo)" }
            }
        }
        0x1 { # integer
            $intBytes = [int][math]::Pow(2, $objInfo)
            $val = Convert-BigEndianToUInt64 -Bytes $Data[($offset+1)..($offset+$intBytes)]
            return [UInt64]$val
        }
        0x2 { # real
            $realBytes = [int][math]::Pow(2, $objInfo)
            $raw = $Data[($offset+1)..($offset+$realBytes)]
            if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($raw) }
            if ($realBytes -eq 4) { return [BitConverter]::ToSingle($raw,0) }
            if ($realBytes -eq 8) { return [BitConverter]::ToDouble($raw,0) }
            throw "Unsupported real size in bplist: $realBytes"
        }
        0x4 { # data
            $tmp = Read-CountAndOffset $offset $objInfo
            $count = [int]$tmp.Count
            $start = [int]$tmp.Offset
            return ,$Data[$start..($start+$count-1)]
        }
        0x5 { # ASCII string
            $tmp = Read-CountAndOffset $offset $objInfo
            $count = [int]$tmp.Count
            $start = [int]$tmp.Offset
            return [Text.Encoding]::ASCII.GetString($Data[$start..($start+$count-1)])
        }
        0x6 { # Unicode string (UTF-16BE)
            $tmp = Read-CountAndOffset $offset $objInfo
            $count = [int]$tmp.Count
            $start = [int]$tmp.Offset
            $byteCount = $count * 2
            $bytes = $Data[$start..($start+$byteCount-1)]
            # bytes are big-endian UTF-16
            for ($i=0; $i -lt $bytes.Length; $i+=2) {
                $t = $bytes[$i]; $bytes[$i] = $bytes[$i+1]; $bytes[$i+1] = $t
            }
            return [Text.Encoding]::Unicode.GetString($bytes)
        }
        0xA { # array
            $tmp = Read-CountAndOffset $offset $objInfo
            $count = [int]$tmp.Count
            $start = [int]$tmp.Offset
            $refs = Read-ObjRefList $Data $start $count $ObjectRefSize
            $arr = @()
            foreach ($r in $refs) {
                $arr += Read-BinaryPlistObject -Data $Data -Offsets $Offsets -OffsetSize $OffsetSize -ObjectRefSize $ObjectRefSize -ObjRef $r
            }
            return ,$arr
        }
        0xD { # dict
            $tmp = Read-CountAndOffset $offset $objInfo
            $count = [int]$tmp.Count
            $start = [int]$tmp.Offset
            $keyRefs = Read-ObjRefList $Data $start $count $ObjectRefSize
            $valRefs = Read-ObjRefList $Data ($start + ($count*$ObjectRefSize)) $count $ObjectRefSize
            $ht = @{}
            for ($i=0; $i -lt $count; $i++) {
                $k = Read-BinaryPlistObject -Data $Data -Offsets $Offsets -OffsetSize $OffsetSize -ObjectRefSize $ObjectRefSize -ObjRef $keyRefs[$i]
                $v = Read-BinaryPlistObject -Data $Data -Offsets $Offsets -OffsetSize $OffsetSize -ObjectRefSize $ObjectRefSize -ObjRef $valRefs[$i]
                $ht[$k] = $v
            }
            return $ht
        }
        default { throw "Unsupported bplist object type: 0x$('{0:X}' -f $objType)" }
    }
}

function Read-BinaryPlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $data = [System.IO.File]::ReadAllBytes($Path)
    if ($data.Length -lt 40) { throw "Invalid plist (too small): $Path" }
    $header = [Text.Encoding]::ASCII.GetString($data[0..7])
    if ($header -ne "bplist00") { throw "Not a binary plist: $Path" }

    # trailer is last 32 bytes
    $trailer = $data[($data.Length-32)..($data.Length-1)]
    $offsetSize = $trailer[6]
    $objectRefSize = $trailer[7]
    $numObjects = Convert-BigEndianToUInt64 -Bytes $trailer[8..15]
    $topObject  = Convert-BigEndianToUInt64 -Bytes $trailer[16..23]
    $offsetTableOffset = Convert-BigEndianToUInt64 -Bytes $trailer[24..31]

    if ($numObjects -gt 500000) { throw "Refusing to parse plist with absurd object count: $numObjects" }

    $offsets = New-Object UInt64[] ([int]$numObjects)
    for ($i=0; $i -lt [int]$numObjects; $i++) {
        $start = [int]$offsetTableOffset + ($i * $offsetSize)
        $offsets[$i] = Convert-BigEndianToUInt64 -Bytes $data[$start..($start+$offsetSize-1)]
    }

    return Read-BinaryPlistObject -Data $data -Offsets $offsets -OffsetSize $offsetSize -ObjectRefSize $objectRefSize -ObjRef $topObject
}

function Get-AppMetadataFromInfoPlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InfoPlistPath
    )

    if (-not (Test-Path $InfoPlistPath)) { throw "Info.plist not found: $InfoPlistPath" }

    # Try XML plist first (common in some DMGs)
    try {
        [xml]$xml = Get-Content -Path $InfoPlistPath -ErrorAction Stop
        $dict = @{}
        $dictNode = $xml.SelectSingleNode("/plist/dict")
        if ($dictNode) {
            $nodes = @($dictNode.ChildNodes)
            for ($i = 0; $i -lt $nodes.Count; $i++) {
                if ($nodes[$i].Name -eq "key" -and ($i + 1) -lt $nodes.Count) {
                    $k = $nodes[$i].InnerText
                    $v = $nodes[$i + 1]
                    switch ($v.Name) {
                        "string"  { $dict[$k] = $v.InnerText }
                        "integer" { $dict[$k] = $v.InnerText }
                        default   { }
                    }
                }
            }
        }
        if ($dict.ContainsKey("CFBundleIdentifier")) {
            return @{
                BundleId = $dict["CFBundleIdentifier"]
                Version  = (if ($dict.ContainsKey("CFBundleShortVersionString")) { $dict["CFBundleShortVersionString"] } else { $dict["CFBundleVersion"] })
            }
        }
    } catch { }

    # Fallback: binary plist (most common)
    $root = Read-BinaryPlist -Path $InfoPlistPath
    if ($root -isnot [hashtable]) { throw "Unexpected plist root object type in $InfoPlistPath" }

    $bundleId = $root["CFBundleIdentifier"]
    $version  = $root["CFBundleShortVersionString"]
    if (-not $version) { $version = $root["CFBundleVersion"] }

    if (-not $bundleId) { throw "CFBundleIdentifier not found in $InfoPlistPath" }
    if (-not $version)  { $version = "0.0" }

    return @{ BundleId = [string]$bundleId; Version = [string]$version }
}

function Get-ChildItemLimitedDepth {
    <#
    .SYNOPSIS
        Depth-limited directory traversal compatible with Windows PowerShell 5.1.

    .DESCRIPTION
        PowerShell 7 has Get-ChildItem -Depth, but Windows PowerShell 5.1 does not.
        This helper walks directories breadth-first up to MaxDepth and emits items.

    .PARAMETER Path
        Root path to start traversal.

    .PARAMETER MaxDepth
        Maximum child depth to traverse. 0 returns only the root.

    .PARAMETER Filter
        Optional leaf-name filter (e.g. 'Info.plist').

    .PARAMETER DirectoriesOnly
        If set, only directories are returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][ValidateRange(0,100)][int]$MaxDepth = 10,
        [Parameter()][string]$Filter,
        [switch]$DirectoriesOnly
    )

    if (-not (Test-Path $Path)) { return }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Path, 0))

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $currentPath = $item[0]
        $depth = [int]$item[1]

        # Emit children at this level
        $children = @()
        try {
            if ($Filter) {
                $children = Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue -Filter $Filter
            }
            else {
                $children = Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            continue
        }

        foreach ($c in $children) {
            if ($DirectoriesOnly -and -not $c.PSIsContainer) { continue }
            $c
        }

        # Traverse deeper directories
        if ($depth -ge $MaxDepth) { continue }

        $dirs = @()
        try {
            $dirs = Get-ChildItem -LiteralPath $currentPath -Directory -Force -ErrorAction SilentlyContinue
        } catch {
            $dirs = @()
        }

        foreach ($d in $dirs) {
            $queue.Enqueue(@($d.FullName, $depth + 1))
        }
    }
}
function Get-PkgMetadata {
    [CmdletBinding()]
    param()
    # Function to get metadata (BundleId and Version) from the extracted PKG contents.
    $packageInfo = Get-ChildItem -Path $Output -Recurse -Filter "PackageInfo" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $packageInfo) { throw "PackageInfo not found" }

    [xml]$xml = Get-Content -LiteralPath $packageInfo.FullName -ErrorAction Stop
    $node = $xml.SelectSingleNode("//bundle")
    if (-not $node) { $node = $xml.SelectSingleNode("//pkg-info") }
    if (-not $node) { throw "Could not parse PackageInfo for bundle id/version." }

    $BundleId = if ($node.id) { $node.id } else { $node.identifier }
    $Version  = if ($node.CFBundleShortVersionString) { $node.CFBundleShortVersionString } else { $node.version }
    return @{ BundleId = $BundleId; Version = $Version }
}

function Find-InfoPlists {
    <#
    .SYNOPSIS
        Finds Info.plist files within a depth limit.

    .DESCRIPTION
        For DMG extraction, file/folder nesting varies (and may not present clean *.app folders).
        This function searches up to MaxDepth and prefers typical app bundle plists
        (..\\.app\\Contents\\Info.plist).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter()][ValidateRange(1,100)][int]$MaxDepth = 10
    )

    $plists = @(Get-ChildItemLimitedDepth -Path $Root -MaxDepth $MaxDepth -Filter 'Info.plist' -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    if (-not $plists -or $plists.Count -eq 0) { return @() }

    # Prefer plists inside app bundles first
    $preferred = @($plists | Where-Object { $_.FullName -match '\\.app\\Contents\\Info\.plist$' })
    if ($preferred.Count -gt 0) {
        return $preferred + @($plists | Where-Object { $_.FullName -notmatch '\\.app\\Contents\\Info\.plist$' })
    }
    return $plists
}

function Expand-Installer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DestinationFolder
    )
    if (-not (Test-Path $SevenZipPath)) { throw "7-Zip not found at $SevenZipPath" }
    if (-not (Test-Path $SourceFile)) { throw "Installer not found: $SourceFile" }
    if (-not (Test-Path $DestinationFolder)) { New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null }

    Write-Log "Extracting installer using 7-Zip: $SourceFile -> $DestinationFolder" -Level INFO
    $args = @('x', "`"$SourceFile`"", "-o`"$DestinationFolder`"", '-y')
    & $SevenZipPath $args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed with exit code $LASTEXITCODE" }
}

function Get-DmgMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DmgPath
    )

    $dmgExtract = Join-Path $Output "DMG"
    if (Test-Path $dmgExtract) { Remove-Item $dmgExtract -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $dmgExtract -Force | Out-Null

    Expand-Installer -SourceFile $DmgPath -DestinationFolder $dmgExtract

    # DMG extraction structure can vary. Prefer classic "*.app\Contents\Info.plist" but fall back
    # to searching for any Info.plist within a depth limit.
    $plists = @(Find-InfoPlists -Root $dmgExtract -MaxDepth 10)
    if (-not $plists -or $plists.Count -eq 0) {
        throw "Info.plist not found inside extracted DMG content (searched up to 10 folder levels)."
    }

    $included = @()
    foreach ($plistItem in $plists) {
        try {
            $m = Get-AppMetadataFromInfoPlist -InfoPlistPath $plistItem.FullName
            $included += @{
                "@odata.type" = "#microsoft.graph.macOSIncludedApp"
                bundleId      = $m.BundleId
                bundleVersion = $m.Version
            }
        } catch {
            Write-Log "Failed to read '$($plistItem.FullName)': $($_.Exception.Message)" -Level WARN
        }
    }

    if (-not $included -or $included.Count -eq 0) { 
        throw "Could not read CFBundleIdentifier/Version from any Info.plist in the DMG (searched up to 10 folder levels)." 
    }

    $primary = $included | Select-Object -First 1
    return @{
        PrimaryBundleId      = $primary.bundleId
        PrimaryBundleVersion = $primary.bundleVersion
        IncludedApps         = $included
    }
}

function Get-InstallerMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath
    )
    $ext = ([IO.Path]::GetExtension($InstallerPath)).ToLowerInvariant()

    switch ($ext) {
        ".pkg" {
            Expand-Pkg
            $m = Get-PkgMetadata
            return @{
                InstallerType        = "PKG"
                ODataType            = "#microsoft.graph.macOSPkgApp"
                PrimaryBundleId      = $m.BundleId
                PrimaryBundleVersion = $m.Version
                IncludedApps         = @(@{
                    "@odata.type" = "#microsoft.graph.macOSIncludedApp"
                    bundleId      = $m.BundleId
                    bundleVersion = $m.Version
                })
            }
        }
        ".dmg" {
            $m = Get-DmgMetadata -DmgPath $InstallerPath
            return @{
                InstallerType        = "DMG"
                ODataType            = "#microsoft.graph.macOSDmgApp"
                PrimaryBundleId      = $m.PrimaryBundleId
                PrimaryBundleVersion = $m.PrimaryBundleVersion
                IncludedApps         = $m.IncludedApps
            }
        }
        default { throw "Unsupported installer type '$ext'. Only .pkg and .dmg are supported." }
    }
}
function Write-IntuneLobFile {
    param(
        [Parameter(Mandatory)]
        [string]$SourceFile
    )
    # Function that takes a file path and encrypts it according to the Intune encryption format, 
    # returning the path to the encrypted file and the encryption metadata needed for the Graph API upload.
    function New-RandomKey([int]$bytes = 32) {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $b = New-Object byte[] $bytes
        $rng.GetBytes($b)
        $rng.Dispose()
        return $b
    }

    $TargetFile = "${SourceFile}_Encrypted.bin"

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $aes    = [System.Security.Cryptography.Aes]::Create()
    $hmac   = [System.Security.Cryptography.HMACSHA256]::new()

    $aes.Key  = New-RandomKey 32
    $hmac.Key = New-RandomKey 32

    $hashLength = $hmac.HashSize / 8

    $sourceStream = [System.IO.File]::OpenRead($SourceFile)
    $sourceSha256 = $sha256.ComputeHash($sourceStream)
    $sourceStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null

    $targetStream = [System.IO.File]::Open($TargetFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite)
    # Reserve space for HMAC, then write IV, then ciphertext
    $targetStream.Write((New-Object byte[] $hashLength), 0, $hashLength)
    $targetStream.Write($aes.IV, 0, $aes.IV.Length)

    $transform    = $aes.CreateEncryptor()
    $cryptoStream = [System.Security.Cryptography.CryptoStream]::new($targetStream, $transform, [System.Security.Cryptography.CryptoStreamMode]::Write)
    $sourceStream.CopyTo($cryptoStream)
    $cryptoStream.FlushFinalBlock()

    # Compute HMAC over (IV + ciphertext)
    $targetStream.Seek($hashLength, [System.IO.SeekOrigin]::Begin) | Out-Null
    $mac = $hmac.ComputeHash($targetStream)

    # Write HMAC at start
    $targetStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
    $targetStream.Write($mac, 0, $mac.Length)

    $cryptoStream.Close()
    $targetStream.Close()
    $sourceStream.Close()

    # Return the fileEncryptionInfo object for commit
    [PSCustomObject][ordered]@{
        encryptedPath         = $TargetFile
        fileEncryptionInfo    = [PSCustomObject][ordered]@{
            encryptionKey        = [Convert]::ToBase64String($aes.Key)
            fileDigest           = [Convert]::ToBase64String($sourceSha256)
            fileDigestAlgorithm  = "SHA256"
            initializationVector = [Convert]::ToBase64String($aes.IV)
            mac                  = [Convert]::ToBase64String($mac)
            macKey               = [Convert]::ToBase64String($hmac.Key)
            profileIdentifier    = "ProfileVersion1"
        }
    }
}

function Resolve-MgGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Group
    )
    # Function to resolve a group name or GUID to its corresponding GroupID and GroupName via Microsoft Graph.
    # Allows the user to specify either a group name or a GUID for app assignment, 
    # and resolve it to the required GroupID for the Graph API calls.

    # Ensure Graph connection
    if (-not (Get-MgContext)) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph -Scopes "Group.Read.All"
    }

    # Check if GUID
    $isGuid = [Guid]::TryParse($Group, [ref]([Guid]::Empty))

    try {
        if ($isGuid) {
            Write-Verbose "Detected GUID. Looking up group name..."

            $g = Get-MgGroup -GroupId $Group -ErrorAction Stop

            return [PSCustomObject]@{
                GroupID   = $g.Id
                GroupName = $g.DisplayName
                Type      = "GUID"
            }
        }
        else {
            Write-Verbose "Detected text. Searching for group..."

            $results = Get-MgGroup -Filter "displayName eq '$Group'"

            if ($results.Count -eq 0) {
                throw "No group found with name '$Group'"
            }

            if ($results.Count -gt 1) {
                Write-Warning "Multiple groups found. Returning first match."
            }

            $g = $results | Select-Object -First 1

            return [PSCustomObject]@{
                GroupID   = $g.Id
                GroupName = $g.DisplayName
                Type      = "Name"
            }
        }
    }
    catch {
        Write-Error $_
    }
}


function Invoke-GraphSafe {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter()]
        $Body,

        [Parameter()]
        [string]$ContentType = 'application/json',

        [Parameter()]
        [hashtable]$Headers,

        [Parameter()]
        [int]$MaxRetries = 6,

        [Parameter()]
        [int]$BaseDelaySec = 2
    )

    # Wraps Invoke-MgGraphRequest with basic retry/backoff for transient Graph failures (429/5xx)
    # and respects -WhatIf/-Confirm via ShouldProcess.
    if (-not $PSCmdlet.ShouldProcess($Uri, "$Method via Microsoft Graph")) {
        Write-Log "WhatIf: Skipping Graph call: $Method $Uri" -Level DEBUG
        return $null
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $invokeParams = @{
                Method      = $Method
                Uri         = $Uri
                ErrorAction = 'Stop'
            }

            if ($Headers) {
                $invokeParams.Headers = $Headers
            }

            if ($null -ne $Body) {
                if ($Body -is [string]) {
                    $invokeParams.Body = $Body
                }
                else {
                    $invokeParams.Body = ($Body | ConvertTo-Json -Depth 50)
                }
                $invokeParams.ContentType = $ContentType
            }

            return Invoke-MgGraphRequest @invokeParams
        }
        catch {
            # Try to determine HTTP status code
            $statusCode = $null
            $retryAfter = $null

            try {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode.value__
                }
            } catch {}

            try {
                if ($_.Exception.Response -and $_.Exception.Response.Headers -and $_.Exception.Response.Headers['Retry-After']) {
                    $retryAfter = [int]$_.Exception.Response.Headers['Retry-After']
                }
            } catch {}

            $msg = $_.Exception.Message

            # Fallback parsing for status codes if not available directly
            if (-not $statusCode -and $msg -match '\b(4\d\d|5\d\d)\b') {
                try { $statusCode = [int]$Matches[1] } catch {}
            }

            $isTransient = $false
            if ($statusCode -eq 429) { $isTransient = $true }
            if ($statusCode -ge 500 -and $statusCode -le 599) { $isTransient = $true }
            if ($msg -match 'TooManyRequests|throttl' ) { $isTransient = $true }

            if (-not $isTransient -or $attempt -ge $MaxRetries) {
                Write-Log "Graph call failed ($Method $Uri). Status=$statusCode Attempt=$attempt/$MaxRetries Error=$msg" -Level ERROR
                throw
            }

            $delay = if ($retryAfter) { $retryAfter } else { [math]::Min(60, $BaseDelaySec * [math]::Pow(2, ($attempt - 1))) }
            Write-Log "Transient Graph error (Status=$statusCode). Retrying in $delay sec (attempt $attempt/$MaxRetries)..." -Level WARN
            Start-Sleep -Seconds $delay
        }
    }
}

# ================= PREP =================
# Check for required modules and install if missing. 
# We only need the Authentication module for Connect-MgGraph,
Install-ModuleIfMissing -Name "Microsoft.Graph.Authentication"

# =========== CONNECT TO GRAPH ===========
# No point in the script continuning if we're not connected to Graph, 
# so we'll throw an error if connection fails.
$result = Test-MgGraphConnection -RequiredScopes @("DeviceManagementApps.ReadWrite.All")

if ($result.HasAllScopes -eq $false) {
    Write-Log "Not connected to Microsoft Graph." -Level INFO 
    Write-Log "Connecting to Microsoft Graph..." -Level INFO 
    Connect-ToGraph
}

# ================= DOWNLOAD =================
# Download the application package and logo, unless the package already exists 
# in the source folder (e.g. from a previous run), in which case we can skip 
# downloading and use the existing file.
$fileName = Get-FileNameFromUrl -Url $AppDownloadUrl
$existingFile = Join-Path $Source $fileName

if (Test-Path $existingFile) {
    Write-Log "File already exists. Skipping download: $existingFile" -Level INFO
    $PkgPath = $existingFile
}
else {
    Write-Log "Downloading $filename..." -Level INFO
    $PkgPath = Save-FileFromUrl -Url $AppDownloadUrl -DestinationFolder $Source
}
Invoke-WebRequest $AppLogoDownloadUrl -OutFile $LogoPath

# =================== INSTALL AZCOPY ===================
# Install AzCopy if not already present, as we need it to upload the app content to Intune.
Install-AzCopy

# ================= EXTRACT + METADATA =================
# Extract installer metadata required for Intune:
#   - PKG: BundleId + Version from PackageInfo
#   - DMG: CFBundleIdentifier + CFBundleShortVersionString from the primary .app's Info.plist
try {
    Install-7ZipIfMissing -SevenZipPath $SevenZipPath -SevenZipDownloadUrl $SevenZipDownloadUrl

    $installerMeta = Get-InstallerMetadata -InstallerPath $PkgPath
    $AppODataType  = $installerMeta.ODataType
    $BundleId      = $installerMeta.PrimaryBundleId
    $Version       = $installerMeta.PrimaryBundleVersion
    $IncludedApps  = $installerMeta.IncludedApps

    Write-Log "InstallerType=$($installerMeta.InstallerType) BundleId=$BundleId Version=$Version" -Level SUCCESS
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

# ================= CREATE INTUNE APP =================
# Create the Intune application with the required metadata. 
# We create the app first, then upload the content, because the content upload 
# requires the app ID and content version ID, which we won't have until after creating the app.
$appBody = @{
    "@odata.type" = $AppODataType
    displayName   = $AppName
    description   = $AppName
    publisher     = $Publisher
    fileName      = [IO.Path]::GetFileName($PkgPath)
    informationUrl= $AppHomepage
    minimumSupportedOperatingSystem = @{
        "@odata.type" = "#microsoft.graph.macOSMinimumOperatingSystem"
        v11_0 = $true
    }
    primaryBundleId      = $BundleId
    primaryBundleVersion = $Version
    includedApps         = $IncludedApps
}

# PKG apps still require bundleId + versionNumber in addition to the primary/included values
if ($AppODataType -eq "#microsoft.graph.macOSPkgApp") {
    $appBody.bundleId      = $BundleId
    $appBody.versionNumber = $Version
}

Write-Log "Creating Intune application: $AppName..." -Level INFO
$app = Invoke-GraphSafe -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps" -Body $appBody
Write-Log "Created $AppName app. Application ID: $($app.id)" -Level SUCCESS

# ================= UPLOAD MACOS PKG =================
Write-Log "Creating content version..." -Level INFO

# Get app meta back so we can read the @odata.type reliably
$appDetails = Invoke-GraphSafe -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)"
$appType = $appDetails.'@odata.type'  # e.g. "#microsoft.graph.macOSPkgApp"

# Convert "#microsoft.graph.macOSPkgApp" -> "microsoft.graph.macOSPkgApp"
$appTypeSegment = $appType.TrimStart('#')
Write-Log "Detected app type: $appTypeSegment" -Level INFO

# Create a new content version for the app. This is required before we can upload any content files.
$contentVersion = Invoke-GraphSafe -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/$appTypeSegment/contentVersions" `
    -Body @{}   # POST empty JSON object to create a new content version.

$contentVersionId = $contentVersion.id
Write-Log "Created content version. Content Version ID: $contentVersionId" -Level SUCCESS

# Encrypt PKG for Intune content upload. Intune requires that content files be encrypted 
# with a specific format and encryption metadata, which is then used during the commit step 
# of the upload process to validate and decrypt the file. The Write-IntuneLobFile function 
# handles this encryption and returns both the path to the encrypted file and the necessary 
# metadata for the Graph API.
Write-Log "Encrypting $filename for Intune content upload..." -Level INFO
$enc = Write-IntuneLobFile -SourceFile $PkgPath
$encryptedPath = $enc.encryptedPath
$fileEncryptionInfo = $enc.fileEncryptionInfo

# Create the content file entry in Graph. This registers the file with the content version and 
# returns a file ID, which is needed to get the upload URL and commit the file later.
Write-Log "Creating content file entry..." -Level INFO

$fileBody = @{
    "@odata.type" = "#microsoft.graph.mobileAppContentFile"
    name          = [System.IO.Path]::GetFileName($PkgPath)
    size          = (Get-Item $PkgPath).Length
    sizeEncrypted = (Get-Item $encryptedPath).Length
    isDependency  = $false
}

$file = Invoke-GraphSafe -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/$appTypeSegment/contentVersions/$contentVersionId/files" `
    -Body $fileBody

$fileId = $file.id
Write-Log "Created content file. id=$fileId" -Level SUCCESS

# Wait for Azure Storage URI to be provisioned. The content file entry needs to be created before 
# Intune will generate the upload URL, and it can take a few seconds for the URL to be ready 
# after the file entry is created. We'll poll the file status until we get the upload URL or 
# timeout after a reasonable number of attempts.
Write-Log "Waiting for Azure Storage URI..." -Level INFO
$uploadUrl = $null
$fileStatus = $null

for ($i = 1; $i -le 60; $i++) {
    $fileStatus = Invoke-GraphSafe -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/$appTypeSegment/contentVersions/$contentVersionId/files/$fileId"

    if ($fileStatus.uploadState -eq "azureStorageUriRequestSuccess" -and $fileStatus.azureStorageUri) {
        $uploadUrl = $fileStatus.azureStorageUri
        break
    }

    Write-Log "Upload URI state: $($fileStatus.uploadState) (attempt $i/60)" -Level DEBUG
    Start-Sleep -Seconds 5
}

if (-not $uploadUrl) {
    throw "Azure Storage URI was not provisioned. uploadState=$($fileStatus.uploadState)"
}

Write-Log "Azure Storage URI obtained." -Level SUCCESS

# Upload the encrypted file to the Azure Storage URI using AzCopy. 
# We need to use AzCopy because the upload requires
Write-Log "Uploading $filename via AzCopy..." -Level INFO
$AzCopyExe = Join-Path $AzCopyDir "azcopy.exe"
if (-not (Test-Path $AzCopyExe)) { 
    throw "AzCopy not found at $AzCopyExe" 
}
if (-not (Test-Path $encryptedPath)) { 
    throw "Encrypted file not found at $encryptedPath" 
}

& $AzCopyExe copy $encryptedPath $uploadUrl --overwrite=true --from-to=LocalBlob | Out-Null
if ($LASTEXITCODE -ne 0) { 
    throw "AzCopy upload failed (exit code $LASTEXITCODE)" 
}

Write-Log "AzCopy upload of $filename completed." -Level SUCCESS

# Keep checking for the file status to be updated to "uploadSuccess" after the upload completes. 
# This indicates that Intune has received and processed the uploaded file, and it's ready to be committed.
# We'll poll the file status until we get the upload success state or timeout after a reasonable number of attempts.
for ($i = 1; $i -le 60; $i++) {
    $fileStatus = Invoke-GraphSafe -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/$appTypeSegment/contentVersions/$contentVersionId/files/$fileId"

    Write-Log "uploadState: $($fileStatus.uploadState) (attempt $i/60)" -Level DEBUG

    if ($fileStatus.uploadState -in @("uploadSuccess","commitFilePending","azureStorageUriRequestSuccess","commitFileSuccess")) {
        break
    }

    Start-Sleep -Seconds 5
}

# Commit uploaded file after checking the upload state. 
# Committing the file tells Intune to validate and finalize the uploaded content, 
# making it ready for assignment.
Write-Log "Committing $filename to storage." -Level INFO
$commitBody = @{
    fileEncryptionInfo = $fileEncryptionInfo
}

Invoke-GraphSafe -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/$appTypeSegment/contentVersions/$contentVersionId/files/$fileId/commit" `
    -Body $commitBody

# Wait for commit to finalise. After committing, we need to wait for the file status 
# to be updated to "commitFileSuccess" or "uploadSuccess", which indicates that Intune 
# has successfully validated and finalised the uploaded file. We'll poll the file status 
# until we get the success state or timeout after a reasonable number of attempts.
Write-Log "Waiting for commit to finalise..." -Level INFO
for ($i = 1; $i -le 60; $i++) {
    $fileStatus = Invoke-GraphSafe -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/$appTypeSegment/contentVersions/$contentVersionId/files/$fileId"

    Write-Log "commit state: $($fileStatus.uploadState) (attempt $i/60)" -Level DEBUG

    if ($fileStatus.uploadState -match "commitFileSuccess|uploadSuccess") {
        break
    }

    Start-Sleep -Seconds 5
}

# Set committedContentVersion on the app to indicate that the content version is ready. 
# This is required before the app can be published and assigned.
Write-Log "Setting committedContentVersion on for $AppName" -Level INFO
$patchBody = @{
    "@odata.type"           = "#$appTypeSegment"              # e.g. #microsoft.graph.macOSPkgApp
    committedContentVersion = [string]$contentVersionId       # must be string
}

Write-Log "appTypeSegment=$appTypeSegment" -Level DEBUG
Write-Log "contentVersionId=$contentVersionId ($($contentVersionId.GetType().FullName))" -Level DEBUG

Invoke-GraphSafe -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)" `
    -Body $patchBody

Write-Log "$AppName source file uploaded and committed successfully!" -Level SUCCESS

# ================= WAIT FOR PUBLISH =================
# Wait for the app to be published. After committing the content, we need to wait for the 
# app's publishingState to be updated to "published" before we can assign it.
Write-Log "Waiting for $AppName to be published." -Level INFO
do {
    Start-Sleep -Seconds 15
    $appCheck = Invoke-GraphSafe -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)"
    $state = $appCheck.publishingState
    Write-Log "Publishing state: $state" -Level INFO
} until ($state -eq "published")

# ================= ASSIGN =================
# Hurray! Nearly there!
# Let's assign the app to the specified group with the specified install intent (e.g. required/available).

# Perform a reverse lookup to get the GroupID from the provided group name or GUID, 
# as the assignment API requires the GroupID.
$GroupAssignment = Resolve-MgGroup -Group $IntuneGroup
$GroupID = $GroupAssignment.GroupID
$GroupName = $GroupAssignment.GroupName

Write-Log "Assigning app to Group ID: $GroupName ($GroupID) as '$InstallMode'..." -Level INFO
$assignBody = @{
    mobileAppAssignments = @(
        @{
            "@odata.type" = "#microsoft.graph.mobileAppAssignment"
            intent        = $InstallMode
            target        = @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                groupId       = $GroupID
            }
        }
    )
}

Invoke-GraphSafe -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assign" `
    -Body $assignBody

Write-Log "$AppName assigned successfully." -Level SUCCESS

# ================= FINISH UP =================
# If we've specified -Cleanup, remove the working directory and all its contents
# to clean up any temporary files.
if ($Cleanup) {
    Write-Log "Cleaning up: $WorkRoot" -Level INFO
    Remove-Item $WorkRoot -Recurse -Force
}

# Disconnect from Graph to clean up the context. 
# This is optional, but good practice to avoid leaving open sessions.
if (Get-MgContext) {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
Write-Log "Disconnected from Graph. All Done." -Level SUCCESS