#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InventoryFile,
    [Parameter(Mandatory)][string]$PolicyId,
    [string]$OutputFile='./ddm-template.json'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src/AppleDDM.psm1') -Force
$inventory=Get-Content -LiteralPath $InventoryFile -Raw | ConvertFrom-Json -AsHashtable
$matches=@($inventory.policies | Where-Object {$_.id -ceq $PolicyId -and $_.sourceKind -eq 'settingsCatalog'})
if($matches.Count -ne 1){throw 'Expected exactly one Settings Catalog policy with this ID.'}
Write-DDMJson $matches[0] $OutputFile
Write-Host "Exported template: $OutputFile. Review its DDM category and remove unrelated settings before generation."
