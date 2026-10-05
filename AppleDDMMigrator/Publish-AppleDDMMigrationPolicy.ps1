#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$PolicyFile,
    [Parameter(Mandatory)][string]$ManifestFile,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$ClientId,
    [switch]$DeviceCode,
    [switch]$ReviewedRequirements,
    [string]$ReceiptPath='./creation-receipt.json'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src/AppleDDM.psm1') -Force
$p=Get-Content -LiteralPath $PolicyFile -Raw | ConvertFrom-Json -AsHashtable
$m=Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json -AsHashtable
if(-not $ReviewedRequirements){throw 'Review the draft, bindings, OS, supervision, enrolment and omitted settings, then use -ReviewedRequirements.'}
if($m.schemaVersion -ne 1 -or (Get-FileHash -LiteralPath $PolicyFile -Algorithm SHA256).Hash -cne $m.policySha256){throw 'Policy differs from generated manifest. Regenerate and review.'}
if($m.Contains('platform') -and $m.platform -cne $p.platforms){throw 'Manifest platform does not match policy.'}
if($m.sourceTenantId -cne $TenantId){throw 'Source tenant does not match requested tenant. Offline demos cannot be published.'}
if($p.platforms -cnotin @('iOS','macOS') -or $p.technologies -cne 'mdm' -or -not $p.name.StartsWith('MIGRATION - ')){throw 'Invalid migration policy envelope.'}
foreach($key in $p.Keys){if($key -notin @('name','description','platforms','technologies','settings')){throw "Unsupported policy field: $key"}}
if($m.ContainsKey('assignments') -and @($m.assignments).Count){throw 'Assignments are forbidden.'}
if(Test-Path -LiteralPath $ReceiptPath){throw 'Receipt exists; inspect it before creating another policy. Use another receipt path only for an intentional new creation.'}
if(-not $PSCmdlet.ShouldProcess("$TenantId / $($p.name)",'Create new UNASSIGNED Settings Catalog policy')){return}
Connect-DDMGraph -TenantId $TenantId -ClientId $ClientId -DeviceCode:$DeviceCode -Write
$leaves=@($p.settings | ForEach-Object {Get-DDMInstanceLeaves $_.settingInstance})
if(-not $leaves.Count){throw 'Policy has no settings.'}
foreach($leaf in $leaves) {
    $id=[uri]::EscapeDataString($leaf.key)
    $d=Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$id" -OutputType Hashtable
    if($p.platforms -notin ($d.applicability.platform -split ',\s*')){throw "Target definition is not applicable to the selected platform: $($leaf.key)"}
    $binding=@($m.bindings.bindings | Where-Object {$_.targetDefinitionId -ceq $leaf.key})
    if($binding.Count -eq 1) {
        $parts=$binding[0].targetPath.Split('/',2)
        $normalise={param($s) ([string]$s -replace '[^a-zA-Z0-9]','').ToLowerInvariant()}
        $base=if($d.ContainsKey('baseUri')){& $normalise $d.baseUri}else{''}
        $offset=if($d.ContainsKey('offsetUri')){& $normalise $d.offsetUri}else{''}
        $identity=& $normalise $d.id
        $expected=& $normalise $binding[0].targetPath
        if(-not (($base.Contains((& $normalise $parts[0])) -and $offset.EndsWith((& $normalise $parts[1]))) -or $identity.EndsWith($expected))) {
            throw "Live definition cannot be verified against the DDM target path: $($leaf.key). Review metadata and catalogue before publishing."
        }
    } elseif($leaf.key -notin $m.bindings.structuralDefinitionIds){throw 'Unbound policy value.'}
    if($leaf.instance.ContainsKey('choiceSettingValue')) {
        $valid=@($d.options | Where-Object {$_.itemId -ceq $leaf.value})
        if($valid.Count -ne 1){throw "Choice option not present in live definition: $($leaf.key)"}
    } elseif($leaf.instance.ContainsKey('simpleSettingValue')) {
        if($d.ContainsKey('minimumValue') -and $leaf.value -lt $d.minimumValue){throw 'Value below current minimum.'}
        if($d.ContainsKey('maximumValue') -and $leaf.value -gt $d.maximumValue){throw 'Value above current maximum.'}
    } else{throw 'Unsupported leaf type.'}
}
# Single POST; do not automatically retry ambiguous writes.
try {$created=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -Body ($p | ConvertTo-Json -Depth 100) -ContentType 'application/json' -OutputType Hashtable}
catch {throw 'Creation failed or response was lost. Inspect Intune for the MIGRATION profile before retrying; no write was retried automatically.'}
try { Write-DDMJson @{policyId=$created.id;tenantId=$TenantId;name=$p.name;createdAt=[datetime]::UtcNow.ToString('o');assignments='NONE';sourcePolicyId=$m.sourcePolicyId} $ReceiptPath }
catch { throw "Policy created with ID $($created.id), but receipt could not be saved. Do not rerun automatically." }
Write-Host "Created unassigned policy: $($created.id). Receipt: $ReceiptPath"
