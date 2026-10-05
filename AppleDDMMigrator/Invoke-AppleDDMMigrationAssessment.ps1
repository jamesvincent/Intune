#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName='Offline')]
param(
    [Parameter(Mandatory,ParameterSetName='Offline')][string]$InputFile,
    [Parameter(Mandatory,ParameterSetName='Live')][switch]$Live,
    [Parameter(ParameterSetName='Live')][string]$TenantId,
    [Parameter(ParameterSetName='Live')][string]$ClientId,
    [Parameter(ParameterSetName='Live')][switch]$DeviceCode,
    [ValidateSet('iOS','macOS','All')][string]$Platform='iOS',
    [Parameter(ParameterSetName='Live')][switch]$IncludeDeviceInventory,
    [string]$OutputPath='./Results'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src/AppleDDM.psm1') -Force
if ($Live) {
    Connect-DDMGraph -TenantId $TenantId -ClientId $ClientId -DeviceCode:$DeviceCode -IncludeDeviceInventory:$IncludeDeviceInventory
    $inventory=Get-DDMInventory -Platform $Platform -IncludeDeviceInventory:$IncludeDeviceInventory
} else {
    $inventory=Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json -AsHashtable
}
$assessment=Invoke-DDMAssessment -Inventory $inventory -Platform $Platform
Export-DDMReport -Assessment $assessment -OutputPath $OutputPath
if ($Live) { $inventory | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $OutputPath 'tenant-export.json') -Encoding utf8 }
$assessment.summary | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize
Write-Host "Reports: $([IO.Path]::GetFullPath($OutputPath))"
