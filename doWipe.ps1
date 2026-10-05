$LogPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\doWipe.log"
 
$LogFolder = Split-Path $LogPath -Parent
 
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
 
function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,
 
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
 
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] [$Level] $Message"
 
    Add-Content -Path $LogPath -Value $LogEntry
    Write-Output $LogEntry
}
 
Write-Log "========== Starting MDM Remote Wipe =========="
Write-Log "Execution context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
 
try {
 
    # RemoteWipe must execute as Local System.
    $CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
 
    if ($CurrentIdentity -ne "NT AUTHORITY\SYSTEM") {
        throw "This script must be executed as NT AUTHORITY\SYSTEM. Current identity: $CurrentIdentity"
    }
 
    $NamespaceName = "root\cimv2\mdm\dmmap"
    $ClassName     = "MDM_RemoteWipe"
    $MethodName    = "doWipeMethod"
 
    Write-Log "Retrieving MDM_RemoteWipe instance"
 
    $Instance = Get-CimInstance `
        -Namespace $NamespaceName `
        -ClassName $ClassName `
        -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" `
        -ErrorAction Stop
 
    if (-not $Instance) {
        throw "MDM_RemoteWipe instance was not found."
    }
 
    Write-Log "MDM_RemoteWipe instance successfully retrieved"
    Write-Log "ParentID: $($Instance.ParentID)"
    Write-Log "InstanceID: $($Instance.InstanceID)"
 
    Write-Log "Invoking $MethodName"
 
    $Result = Invoke-CimMethod `
        -InputObject $Instance `
        -MethodName $MethodName `
        -Arguments @{
            param = ""
        } `
        -ErrorAction Stop
 
    Write-Log "Wipe method invoked successfully"
    Write-Log "Return value: $($Result.ReturnValue)"
 
}
catch {
 
    Write-Log "Exception occurred: $($_.Exception.Message)" "ERROR"
 
    if ($_.Exception.InnerException) {
        Write-Log "Inner exception: $($_.Exception.InnerException.Message)" "ERROR"
    }
 
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
 
    exit 1
}
 
Write-Log "========== Script Complete =========="
exit 0
