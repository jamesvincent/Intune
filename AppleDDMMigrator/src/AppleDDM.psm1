#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:Root=Split-Path $PSScriptRoot -Parent
$script:GraphBase='https://graph.microsoft.com/beta'
function Get-Field($Object,[string]$Key,$Default=$null) {
    if ($null -ne $Object -and $Object.Contains($Key)) { return ,($Object[$Key]) }
    return ,$Default
}
function Write-DDMJson($Object,[string]$Path) {
    $Object | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Test-DDMGraphContext {
    param($Context,[string]$TenantId,[string]$ClientId,[string[]]$Scopes)
    if (-not $Context) { return $false }
    # SDK contexts are objects; use dictionary lookup as well for offline tests.
    $fields=@{}
    foreach($key in @('TenantId','ClientId','Environment','AuthType','Account','Scopes')) {
        $fields[$key]=if($Context -is [Collections.IDictionary]) {Get-Field $Context $key} elseif($Context.PSObject.Properties[$key]) {$Context.PSObject.Properties[$key].Value} else {$null}
    }
    if ($fields.Environment -ne 'Global' -or $fields.AuthType -ne 'Delegated' -or -not $fields.Account -or -not $fields.TenantId) { return $false }
    if ($TenantId -and $fields.TenantId -ne $TenantId) { return $false }
    if ($ClientId -and $fields.ClientId -ne $ClientId) { return $false }
    foreach($scope in $Scopes) {
        if ($fields.Scopes -contains $scope) { continue }
        # Configuration write permission also authorises configuration reads.
        if ($scope -eq 'DeviceManagementConfiguration.Read.All' -and $fields.Scopes -contains 'DeviceManagementConfiguration.ReadWrite.All') { continue }
        return $false
    }
    return $true
}
function Connect-DDMGraph {
    param([string]$TenantId,[string]$ClientId,[switch]$DeviceCode,[switch]$Write,[switch]$IncludeDeviceInventory)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser first.' }
    Import-Module Microsoft.Graph.Authentication
    $scope=if($Write){'DeviceManagementConfiguration.ReadWrite.All'}else{'DeviceManagementConfiguration.Read.All'}
    $scopes=@($scope);if($IncludeDeviceInventory){$scopes+='DeviceManagementManagedDevices.Read.All'}
    if (Test-DDMGraphContext -Context (Get-MgContext) -TenantId $TenantId -ClientId $ClientId -Scopes $scopes) {
        Write-Verbose 'Reusing the connected Microsoft Graph session.'
        return
    }
    $connectArgs=@{Scopes=$scopes;ContextScope='Process';NoWelcome=$true;Environment='Global'}
    if ($TenantId) { $connectArgs.TenantId=$TenantId }
    if ($ClientId) { $connectArgs.ClientId=$ClientId }
    if ($DeviceCode) { $connectArgs.UseDeviceAuthentication=$true }
    Connect-MgGraph @connectArgs
    $ctx=Get-MgContext
    if (-not (Test-DDMGraphContext -Context $ctx -TenantId $TenantId -ClientId $ClientId -Scopes $scopes)) {
        throw 'Microsoft Graph sign-in did not establish the requested delegated session, tenant, client, cloud and permissions. No tenant operation was performed.'
    }
}
function Invoke-DDMGraphGet([string]$Uri) {
    $parsed=[uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or -not $parsed.AbsolutePath.StartsWith('/beta/deviceManagement/')) { throw 'Unexpected Graph URL; refused.' }
    for($attempt=0;$attempt -lt 5;$attempt++) {
        try { return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable }
        catch {
            $status=0
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode }
            if ($status -notin @(429,503,504) -or $attempt -eq 4) { throw }
            $delay=[math]::Min(30,[math]::Pow(2,$attempt+1))
            if ($_.Exception.Response.Headers.RetryAfter -and $_.Exception.Response.Headers.RetryAfter.Delta) { $delay=[math]::Min(60,$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds) }
            Start-Sleep -Seconds $delay
        }
    }
}
function Get-DDMGraphCollection([string]$Uri) {
    $items=[Collections.Generic.List[object]]::new(); $seen=@{}
    while($Uri) {
        if ($seen.ContainsKey($Uri)) { throw 'Graph pagination loop detected.' }
        $seen[$Uri]=$true
        $page=Invoke-DDMGraphGet $Uri
        if (-not $page.ContainsKey('value')) { throw "Expected Graph collection: $Uri" }
        foreach($item in $page.value){$items.Add($item)}
        $Uri=Get-Field $page '@odata.nextLink' ''
    }
    return ,$items.ToArray()
}
function Get-DDMPolicyPlatform($Policy,[string]$Fallback='') {
    $platform=Get-Field $Policy 'platform' ''
    if($platform -in @('iOS','macOS')){return $platform}
    $native=(Get-Field $Policy 'platforms' '') -split ',\s*'
    if($native -contains 'macOS'){return 'macOS'}
    if($native -contains 'iOS'){return 'iOS'}
    $type=Get-Field $Policy '@odata.type' ''
    if($type -match '(?i)macOS'){return 'macOS'}
    if($type -match '(?i)ios|ipad'){return 'iOS'}
    if($Fallback -in @('iOS','macOS') -and -not $type -and -not $platform -and -not ($native -join '')){return $Fallback}
    return ''
}
function Get-DDMDevicePlatform($Device) {
    $os=Get-Field $Device 'operatingSystem' (Get-Field $Device 'platform' '')
    if($os -match '^(?i:macOS|Mac OS X|Mac)$'){return 'macOS'}
    if($os -match '^(?i:iOS|iPadOS)$'){return 'iOS'}
    return ''
}
function Get-DDMInventory {
    param([ValidateSet('iOS','macOS','All')][string]$Platform='iOS',[switch]$IncludeDeviceInventory)
    $selected=if($Platform -eq 'All'){@('iOS','macOS')}else{@($Platform)}
    $policies=[Collections.Generic.List[object]]::new()
    Write-Host "Discovering $Platform Settings Catalog policies..."
    foreach($p in (Get-DDMGraphCollection "$script:GraphBase/deviceManagement/configurationPolicies")) {
        $policyPlatform=Get-DDMPolicyPlatform $p
        if($policyPlatform -notin $selected){continue}
        $id=[uri]::EscapeDataString($p.id)
        $p['settings']=Get-DDMGraphCollection "$script:GraphBase/deviceManagement/configurationPolicies/$id/settings"
        $p['assignments']=Get-DDMGraphCollection "$script:GraphBase/deviceManagement/configurationPolicies/$id/assignments"
        $p['sourceKind']='settingsCatalog';$p['platform']=$policyPlatform; $policies.Add($p)
    }
    Write-Host "Discovering $Platform legacy configuration profiles..."
    foreach($p in (Get-DDMGraphCollection "$script:GraphBase/deviceManagement/deviceConfigurations")) {
        $policyPlatform=Get-DDMPolicyPlatform $p
        if($policyPlatform -notin $selected){continue}
        $id=[uri]::EscapeDataString($p.id)
        $p=Invoke-DDMGraphGet "$script:GraphBase/deviceManagement/deviceConfigurations/$id"
        $p['assignments']=Get-DDMGraphCollection "$script:GraphBase/deviceManagement/deviceConfigurations/$id/assignments"
        $p['sourceKind']='legacy';$p['platform']=$policyPlatform; $policies.Add($p)
    }
    Write-Host 'Retrieving setting definitions...'
    $allDefs=Get-DDMGraphCollection "$script:GraphBase/deviceManagement/configurationSettings"
    $defs=@($allDefs | Where-Object {
        $applicable=(Get-Field (Get-Field $_ 'applicability' @{}) 'platform' '') -split ',\s*'
        @($applicable | Where-Object {$_ -in $selected}).Count -gt 0
    })
    $devices=@()
    if($IncludeDeviceInventory) {
        Write-Host 'Retrieving Apple managed-device compatibility evidence...'
        $allDevices=Get-DDMGraphCollection "$script:GraphBase/deviceManagement/managedDevices?`$select=id,operatingSystem,osVersion,isSupervised,deviceEnrollmentType"
        $devices=@($allDevices | Where-Object {(Get-DDMDevicePlatform $_) -in $selected})
    }
    return @{schemaVersion=1;tenantId=(Get-MgContext).TenantId;platform=$Platform;collectedAt=[datetime]::UtcNow.ToString('o');complete=$true;policies=$policies.ToArray();definitions=$defs;devices=$devices;deviceInventoryIncluded=[bool]$IncludeDeviceInventory}
}
function Get-DDMCompatibility($Inventory,[string]$Platform,[string]$MinimumOS,$SupervisionRequired,[string]$Classification) {
    $result=@{status='NotAssessed';scope='Platform-wide inventory; assignment targeting not resolved';total=0;passed=0;blocked=0;unknown=0;summary='Not assessed: collect managed-device inventory to check OS/supervision.'}
    if($Classification -notin @('DDM_DIRECT','DDM_SEMANTIC','ALREADY_DDM')){$result.status='NotApplicable';$result.summary='No verified target to check.';return $result}
    if(-not (Get-Field $Inventory 'deviceInventoryIncluded' $false)){return $result}
    $devices=@((Get-Field $Inventory 'devices' @()) | Where-Object {(Get-DDMDevicePlatform $_) -eq $Platform})
    $result.total=$devices.Count
    if(-not $devices.Count){$result.status='Unknown';$result.summary='No managed devices found for this platform.';return $result}
    foreach($d in $devices) {
        $blocked=$false;$unknown=$false
        try {
            if(-not $MinimumOS){$unknown=$true}
            else {
                $os=Get-Field $d 'osVersion' ''
                if($os -notmatch '^\d+\.\d+(?:\.\d+){0,2}$'){$unknown=$true}
                elseif([version]$os -lt [version]$MinimumOS){$blocked=$true}
            }
        } catch {$unknown=$true}
        if($SupervisionRequired -ceq $true) {
            $supervised=Get-Field $d 'isSupervised' $null
            if($supervised -isnot [bool]){$unknown=$true}
            elseif(-not $supervised){$blocked=$true}
        }
        if($blocked){$result.blocked++}elseif($unknown){$result.unknown++}else{$result.passed++}
    }
    $result.status=if($result.blocked -eq $result.total){'Blocked'}elseif($result.blocked -gt 0){'Mixed'}elseif($result.unknown -gt 0){'Unknown'}else{'ChecksPassed'}
    $result.summary="$($result.passed) passed, $($result.blocked) blocked, $($result.unknown) unknown / $($result.total) $Platform devices (OS/supervision only; platform-wide)."
    return $result
}
function Get-DDMInstanceLeaves($Instance,[string]$Path='') {
    $id=Get-Field $Instance 'settingDefinitionId' ''
    if (-not $id) { throw 'Settings Catalog instance has no settingDefinitionId.' }
    $pathNow=if($Path){"$Path/$id"}else{$id}
    $found=$false
    foreach($key in @('simpleSettingValue','choiceSettingValue','simpleSettingCollectionValue','choiceSettingCollectionValue','groupSettingCollectionValue','groupSettingValue')) {
        if (-not $Instance.ContainsKey($key)) { continue }
        $found=$true; $values=@($Instance[$key])
        foreach($value in $values) {
            if ($value.Contains('value')) { @{key=$id;value=$value.value;path=$pathNow;instance=$Instance;valueObject=$value} }
            elseif ($key -notmatch 'group') { @{key=$id;value=$value;path=$pathNow;instance=$Instance;valueObject=$value} }
            $children=Get-Field $value 'children' @()
            foreach($child in $children){Get-DDMInstanceLeaves $child $pathNow}
            if ($key -match 'group' -and $children.Count -eq 0) { @{key=$id;value='[empty group]';path=$pathNow;instance=$Instance;valueObject=$value} }
        }
    }
    if (-not $found) { @{key=$id;value='[unrecognised setting instance]';path=$pathNow;instance=$Instance;valueObject=@{}} }
}
function Get-DDMLegacyLeaves($Policy) {
    $skip=@('name','settingsProvenance','configuredSettingKeys','isAssigned','assignmentStatus','settingCount','templateReference','technologies','platforms','creationSource','deviceStatusOverview','userStatusOverview','id','@odata.type','@odata.context','displayName','description','version','createdDateTime','lastModifiedDateTime','supportsScopeTags','roleScopeTagIds','assignments','sourceKind','platform','deviceManagementApplicabilityRuleOsEdition','deviceManagementApplicabilityRuleOsVersion','deviceManagementApplicabilityRuleDeviceMode','payloadName','payloadFileName','payload','deploymentChannel')
    foreach($key in $Policy.Keys) {
        if($key -in $skip -or $key.StartsWith('@')){continue}
        $v=$Policy[$key]
        if ($null -eq $v -or ($v -is [string] -and $v -eq 'notConfigured')) { continue }
        # Legacy resources return defaults, not a list of explicitly set fields.
        # Only a reviewed explicit export can distinguish configured false/zero.
        $explicit=(Get-Field $Policy 'settingsProvenance' '') -eq 'explicit'
        if($Policy.Contains('configuredSettingKeys')) {
            if($key -notin $Policy.configuredSettingKeys){continue}
            $explicit=$true
        }
        if(-not $explicit) {
            if($v -is [bool] -and -not $v){continue}
            if($v -is [ValueType] -and $v -isnot [bool] -and $v -eq 0){continue}
            if($v -is [string] -and ($v.Trim() -eq '' -or $v -in @('notConfigured','deviceDefault','browserDefault','default','notSet','unknown','none'))){continue}
            if($v -is [Collections.ICollection] -and $v.Count -eq 0){continue}
        }
        @{key=$key;value=$v;path=$key}
    }
    if ($Policy.ContainsKey('payload')) {
        try {
            $bytes=[Convert]::FromBase64String($Policy.payload)
            $text=[Text.Encoding]::UTF8.GetString($bytes)
            $settings=[Xml.XmlReaderSettings]::new(); $settings.DtdProcessing=[Xml.DtdProcessing]::Ignore; $settings.XmlResolver=$null
            $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($text),$settings)
            $doc=[Xml.XmlDocument]::new(); $doc.XmlResolver=$null; $doc.Load($reader); $reader.Dispose()
            $plist=Convert-DDMPlistNode $doc.DocumentElement.FirstChild
            foreach($payload in (Get-Field $plist 'PayloadContent' @())) {
                $type=Get-Field $payload 'PayloadType' 'unknown'
                foreach($key in $payload.Keys) {
                    if($key.StartsWith('Payload')){continue}
                    @{key="$type/$key";value=$payload[$key];path="$type/$key"}
                }
            }
        } catch { @{key='customPayload';value='[opaque, binary, signed or invalid plist]';path='payload'} }
    }
}
function Convert-DDMPlistNode($Node) {
    switch($Node.Name) {
        'dict' {
            $result=@{}; $nodes=@($Node.ChildNodes | Where-Object {$_.NodeType -eq 'Element'})
            if ($nodes.Count % 2) { throw 'Invalid plist dictionary.' }
            for($i=0;$i -lt $nodes.Count;$i+=2) {
                if ($nodes[$i].Name -ne 'key') { throw 'Invalid plist key.' }
                $result[$nodes[$i].InnerText]=Convert-DDMPlistNode $nodes[$i+1]
            }
            return $result
        }
        'array' { return ,@($Node.ChildNodes | Where-Object {$_.NodeType -eq 'Element'} | ForEach-Object {Convert-DDMPlistNode $_}) }
        'true' {return $true}; 'false' {return $false}; 'integer' {return [long]$Node.InnerText}
        'real' {return [double]::Parse($Node.InnerText,[cultureinfo]::InvariantCulture)}
        default {return $Node.InnerText}
    }
}
function Get-DDMSourceTechnology($Definition) {
    $evidence="$(Get-Field $Definition 'baseUri' '') $(Get-Field $Definition 'id' '')"
    if ($evidence -match 'com[._]apple[._]configuration[._](passcode|softwareupdate|safari|math|app|disk)') { return 'DDM declaration' }
    $base=Get-Field $Definition 'baseUri' ''
    if($base.StartsWith('com.apple.',[StringComparison]::OrdinalIgnoreCase) -and -not $base.StartsWith('com.apple.configuration.',[StringComparison]::OrdinalIgnoreCase)){return 'Apple MDM payload'}
    return 'Settings Catalog (transport unverified)'
}
function Test-DDMTargetDefinition($Definition,[string]$TargetPath,[string]$Platform) {
    if(-not $TargetPath -or $Platform -notin ((Get-Field (Get-Field $Definition 'applicability' @{}) 'platform' '') -split ',\s*')){return $false}
    $parts=$TargetPath.Split('/',2);if($parts.Count -ne 2){return $false}
    $normalise={param($v)([string]$v -replace '[^a-zA-Z0-9]','').ToLowerInvariant()}
    $base=& $normalise (Get-Field $Definition 'baseUri' '')
    $offset=& $normalise (Get-Field $Definition 'offsetUri' '')
    $identity=& $normalise (Get-Field $Definition 'id' '')
    return ($base.Contains((& $normalise $parts[0])) -and $offset.EndsWith((& $normalise $parts[1]))) -or $identity.EndsWith((& $normalise $TargetPath))
}
function Invoke-DDMAssessment {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,[ValidateSet('iOS','macOS','All')][string]$Platform='iOS')
    if ((Get-Field $Inventory 'schemaVersion' 0) -ne 1 -or -not $Inventory.Contains('policies')) { throw 'Expected schemaVersion 1 inventory with policies. See samples.' }
    $catalogues=@{};foreach($platformName in @('iOS','macOS')){$catalogues[$platformName]=Get-Content -LiteralPath (Join-Path $script:Root ('mappings/'+$platformName.ToLowerInvariant()+'.json')) -Raw | ConvertFrom-Json -AsHashtable}
    $definitions=@{}; foreach($d in (Get-Field $Inventory 'definitions' @())){$definitions[$d.id]=$d}
    $rows=[Collections.Generic.List[object]]::new(); $profiles=[Collections.Generic.List[object]]::new();$seenPolicies=@{}
    foreach($p in $Inventory.policies) {
        $policyPlatform=Get-DDMPolicyPlatform $p $Platform
        if(-not $policyPlatform){if($Platform -eq 'All'){throw 'Mixed-platform assessment requires each profile to have platform or native Graph platform/type metadata.'};continue}
        if($Platform -ne 'All' -and $policyPlatform -ne $Platform){continue}
        $catalog=$catalogues[$policyPlatform]
        $id=Get-Field $p 'id' ''; if(-not $id){throw 'Policy has no ID.'}
        if($seenPolicies.ContainsKey($id)){throw "Duplicate source policy ID: $id"};$seenPolicies[$id]=$true
        $name=Get-Field $p 'name' (Get-Field $p 'displayName' $id)
        $kind=Get-Field $p 'sourceKind' ''; if($kind -notin @('legacy','settingsCatalog')){throw "Unsupported sourceKind for $id"}
        # Wrap the whole conditional: PowerShell enumerates arrays returned by
        # an if branch, turning zero results into null and one into a scalar.
        $leaves=@(if($kind -eq 'settingsCatalog') {$p.settings | ForEach-Object {Get-DDMInstanceLeaves $_.settingInstance}}else{Get-DDMLegacyLeaves $p})
        foreach($leaf in $leaves) {
            $definition=Get-Field $definitions $leaf.key @{}
            $technology=if($kind -eq 'legacy'){'Legacy MDM'}else{Get-DDMSourceTechnology $definition}
            $sourceKey=$leaf.key
            if($kind -eq 'settingsCatalog' -and $technology -eq 'Apple MDM payload') {
                $base=Get-Field $definition 'baseUri' ''; $offset=(Get-Field $definition 'offsetUri' '').Trim('/')
                if($offset -and $offset -notmatch '/'){ $sourceKey="$base/$offset" }
            }
            $normalisedValue=$leaf.value
            if($kind -eq 'settingsCatalog' -and $leaf.Contains('instance') -and $leaf.instance.Contains('choiceSettingValue')) {
                $options=Get-Field $definition 'options' @()
                $selectedOption=@($options | Where-Object {(Get-Field $_ 'itemId' '') -ceq $leaf.value})
                if($selectedOption.Count -eq 1 -and (Get-Field $selectedOption[0] 'optionValue' @{}).Contains('value')){$normalisedValue=$selectedOption[0].optionValue.value}
            }
            $rule=@($catalog.rules | Where-Object {$sourceKey -cin $_.sourceKeys})
            $classification='REQUIRES_REVIEW'; $target=''; $proposed=$null; $minOS=''; $supervision=$null; $note='No verified mapping. Source value retained in assessment.'; $mappingId=''; $sources=@(); $appleSupport='Unverified'; $intuneSupport='Unverified'
            if ($technology -eq 'DDM declaration') { $classification='ALREADY_DDM';$note='Declarative identity found in setting definition. Check enrolment and applicability before relying on deployment.'
                $knownTarget=@($catalog.rules | Where-Object {(Get-Field $_ 'targetPath' '') -and (Test-DDMTargetDefinition $definition $_.targetPath $policyPlatform)} | Select-Object -First 1)
                if($knownTarget.Count){$minOS=Get-Field $knownTarget[0] 'minimumOS' (Get-Field $knownTarget[0] 'minimumIOS' '');$supervision=Get-Field $knownTarget[0] 'supervisionRequired' $null;$target=$knownTarget[0].targetPath} }
            elseif($rule.Count -eq 1) {
                $r=$rule[0];$mappingId=$r.id;$sources=$r.sources;$target=Get-Field $r 'targetPath' ''; $minOS=Get-Field $r 'minimumOS' (Get-Field $r 'minimumIOS' ''); $supervision=Get-Field $r 'supervisionRequired' $null
                $classification=$r.classification; $note=$r.notes;$appleSupport=Get-Field $r 'appleSupport' 'Unverified';$intuneSupport=Get-Field $r 'intuneSupport' 'Unverified';$proposed=$normalisedValue
                switch(Get-Field $r 'transform' 'identity') {
                    'invertBoolean' { if($normalisedValue -is [bool]){$proposed=-not $normalisedValue}else{$classification='REQUIRES_REVIEW';$note='Expected boolean; mapping refused.'} }
                    'passwordType' { if($normalisedValue -eq 'alphanumeric'){$proposed=$true}elseif($normalisedValue -eq 'numeric'){$proposed=$false}else{$classification='REQUIRES_REVIEW';$note='Unknown password type; mapping refused.'} }
                }
                if($r.Contains('valueType')) {
                    $valid=if($r.valueType -eq 'boolean'){$proposed -is [bool]}else{($proposed -is [int] -or $proposed -is [long]) -and $proposed -ge $r.minimum -and $proposed -le $r.maximum}
                    if(-not $valid){$classification='REQUIRES_REVIEW';$note='Value outside verified target range/type. No automatic conversion.'}
                }
                if($classification -notin @('DDM_DIRECT','DDM_SEMANTIC')){$proposed=$null}
                if($classification -eq 'LEGACY_RETAIN' -and $kind -eq 'settingsCatalog'){$classification='MODERN_MDM_RETAIN'}
                if ($mappingId -eq 'update-deferral') {
                    $enableKey=if($leaf.key.StartsWith('com.apple.')){'com.apple.applicationaccess/forceDelayedSoftwareUpdates'}else{'softwareUpdatesForceDelayed'}
                    $enabled=@($leaves | Where-Object {$_.key -ceq $enableKey -and $_.value -ceq $true})
                    if($enabled.Count -ne 1){$classification='REQUIRES_REVIEW';$proposed=$null;$note='Deferral enable flag is false or unavailable. Do not generate a delay without checking policy intent.'}
                }
            }
            if($rule.Count -eq 0 -and $technology -ne 'DDM declaration' -and $catalog.Contains('retainedPayloads')) {
                $family=@($catalog.retainedPayloads | Where-Object {$sourceKey.StartsWith($_.payload+'/',[StringComparison]::Ordinal)})
                if($family.Count -eq 1){$classification=if($kind -eq 'settingsCatalog'){'MODERN_MDM_RETAIN'}else{'LEGACY_RETAIN'};$note=$family[0].notes;$sources=$family[0].sources}
            }
            if($policyPlatform -eq 'macOS' -and $sourceKey.StartsWith('com.apple.applicationaccess/enforcedSoftwareUpdate')) {
                $enableKey=switch -Regex ($sourceKey) {'Major' {'com.apple.applicationaccess/forceDelayedMajorSoftwareUpdates'};'Minor' {'com.apple.applicationaccess/forceDelayedSoftwareUpdates'};default {'com.apple.applicationaccess/forceDelayedAppSoftwareUpdates'}}
                if(@($leaves | Where-Object {$_.key -ceq $enableKey -and $_.value -ceq $true}).Count -ne 1){$classification='REQUIRES_REVIEW';$proposed=$null;$note='Custom deferral requires its companion enabled restriction; check source intent.'}
            }
            $targetIds=@();if($target){$targetIds=@($definitions.Values | Where-Object {Test-DDMTargetDefinition $_ $target $policyPlatform} | ForEach-Object {$_.id});$intuneSupport=if($targetIds.Count){'Target definition verified in inventory'}else{'Target definition not resolved; review current Intune availability'}}
            $compatibility=Get-DDMCompatibility $Inventory $policyPlatform $minOS $supervision $classification
            $rows.Add([ordered]@{platform=$policyPlatform;targetDefinitionIds=$targetIds;normalisedValue=$normalisedValue;minimumOS=$minOS;minimumMacOS=$(if($policyPlatform -eq 'macOS'){$minOS}else{''});compatibilityStatus=$compatibility.status;compatibilityEvidence=$compatibility;sourcePolicyId=$id;sourcePolicyName=$name;sourceKind=$kind;sourceKey=$leaf.key;sourcePath=$leaf.path;displayName=(Get-Field $definition 'displayName' $leaf.key);currentTechnology=$technology;currentValue=$leaf.value;classification=$classification;mappingId=$mappingId;targetPath=$target;proposedValue=$proposed;appleSupport=$appleSupport;intuneSupport=$intuneSupport;minimumIOS=$(if($policyPlatform -eq 'iOS'){$minOS}else{''});supervisionRequired=$supervision;estateCompatibility=$compatibility.summary;notes=$note;sources=$sources})
        }
        $profileRows=@($rows | Where-Object {$_.sourcePolicyId -eq $id})
        $mapped=@($profileRows | Where-Object {$_.classification -in @('DDM_DIRECT','DDM_SEMANTIC')}).Count
        $alreadyCount=@($profileRows | Where-Object {$_.classification -eq 'ALREADY_DDM'}).Count
        $coverage=if($profileRows.Count){[math]::Round(100*$mapped/$profileRows.Count,1)}else{$null}
        $applicability=if($profileRows.Count){[math]::Round(100*($mapped+$alreadyCount)/$profileRows.Count,1)}else{$null}
        $profiles.Add(@{platform=$policyPlatform;id=$id;name=$name;settings=$profileRows.Count;mapped=$mapped;alreadyDDM=$alreadyCount;coveragePercent=$coverage;ddmApplicabilityPercent=$applicability;sourceReplacementApproved=$false;assignments=(Get-Field $p 'assignments' @());notes=$(if($kind -eq 'legacy'){'Indicative coverage of non-default or explicitly confirmed legacy settings; Graph cannot establish explicit/default intent for every property. Review target availability and device prerequisites.'}else{'Coverage of configured policy instances. Review target availability and device prerequisites before migration.'})})
    }
    $summary=@($rows | Group-Object { $_.classification } | Sort-Object Name | ForEach-Object {@{classification=$_.Name;count=$_.Count}})
    return @{schemaVersion=1;toolVersion='0.2.4';platform=$Platform;mappingVersion=(@($catalogues.Values | ForEach-Object {$_.version}) -join ',');assessedAt=[datetime]::UtcNow.ToString('o');tenantId=(Get-Field $Inventory 'tenantId' 'offline');inventoryComplete=(Get-Field $Inventory 'complete' $false);summary=$summary;profiles=$profiles.ToArray();settings=$rows.ToArray();limitations=@('Configuration profiles only; compliance, app configuration, enrollment and assignment intent are not assessed.','Assignment data is retained; group overlap and effective conflicts are not calculated.','Legacy Graph properties do not identify whether default-valued fields were explicitly configured. False, zero, empty and default values are excluded unless confirmed by configuredSettingKeys or settingsProvenance=explicit; legacy percentages are indicative.','Device evidence, when collected, checks platform-wide OS/supervision only; enrolment, channel/scope, hardware and Shared iPad require separate validation.')}
}
function Export-DDMReport {
    param($Assessment,[string]$OutputPath)
    $null=New-Item -ItemType Directory -Path $OutputPath -Force
    $reportPlatform=Get-Field $Assessment 'platform' 'iOS'
    $label=switch($reportPlatform){'macOS' {'macOS'};'All' {'Apple (iOS / iPadOS + macOS)'};default {'iOS / iPadOS'}}
    $prefix=if($reportPlatform -eq 'All'){'Apple'}else{$reportPlatform}
    $reportName=$prefix+'-DDM-Assessment'
    Write-DDMJson $Assessment (Join-Path $OutputPath ($reportName+'.json'))
    $flat=@($Assessment.settings | ForEach-Object {
        $r=[ordered]@{};foreach($key in $_.Keys){$v=$_[$key];$r[$key]=if($v -is [array] -or $v -is [Collections.IDictionary]){ConvertTo-Json -InputObject $v -Compress -Depth 100}else{$v}}
        # Avoid spreadsheet formula execution on opening the CSV.
        foreach($key in @($r.Keys)){if($r[$key] -is [string] -and $r[$key] -match '^\s*[=+@-]'){$r[$key]="'"+$r[$key]}}
        [pscustomobject]$r
    })
    if($flat.Count){$flat | Export-Csv -LiteralPath (Join-Path $OutputPath ($reportName+'.csv')) -NoTypeInformation -Encoding utf8}else{Set-Content -LiteralPath (Join-Path $OutputPath ($reportName+'.csv')) -Value 'sourcePolicyId,classification' -Encoding utf8}
    function Encode($v){[Net.WebUtility]::HtmlEncode([string]$v)}
    function StatusColour($classification) {
        switch ($classification) {
            {$_ -in @('ALREADY_DDM','DDM_DIRECT','DDM_SEMANTIC')} {return 'green'}
            {$_ -in @('DDM_PARTIAL','MODERN_MDM_RETAIN','LEGACY_RETAIN')} {return 'amber'}
            default {return 'red'}
        }
    }
    function ProfileExamples($rows) {
        $names=@($rows | ForEach-Object {$_.sourcePolicyName} | Sort-Object -Unique)
        $examples=($names | Select-Object -First 3 | ForEach-Object {Encode $_}) -join ', '
        if($names.Count -gt 3){$examples+=" and $($names.Count-3) more"}
        return $examples
    }
    $candidates=@($Assessment.settings | Where-Object {$_.classification -in @('DDM_DIRECT','DDM_SEMANTIC')})
    $review=@($Assessment.settings | Where-Object {(StatusColour $_.classification) -eq 'red'})
    $partial=@($Assessment.settings | Where-Object {$_.classification -eq 'DDM_PARTIAL'})
    $retained=@($Assessment.settings | Where-Object {$_.classification -in @('LEGACY_RETAIN','MODERN_MDM_RETAIN')})
    $already=@($Assessment.settings | Where-Object {$_.classification -eq 'ALREADY_DDM'})
    $updates=@($candidates | Where-Object {$_.mappingId -eq 'update-deferral'})
    $macUpdates=@($candidates | Where-Object {$_.platform -eq 'macOS' -and $_.targetPath -like '*softwareupdate.settings/Deferrals/*'})
    $blockedChecks=@($Assessment.settings | Where-Object {(Get-Field $_ 'compatibilityStatus' '') -in @('Blocked','Mixed')})
    $suggestions=[Collections.Generic.List[string]]::new()
    if(-not $Assessment.inventoryComplete){$suggestions.Add('<div class="suggestion red"><strong>Confirm inventory completeness</strong><p>This inventory is not marked complete. Finish discovery before deciding what to migrate.</p></div>')}
    if($review.Count){$suggestions.Add("<div class=`"suggestion red`"><strong>Review unresolved settings ($($review.Count))</strong><p>Check source intent and target support. Do not generate replacements for unknown or invalid values.</p><small>Profiles: $(ProfileExamples $review)</small></div>")}
    if($candidates.Count){$suggestions.Add("<div class=`"suggestion green`"><strong>Review DDM migration candidates ($($candidates.Count))</strong><p>Verify effective values and device requirements, then prepare an unassigned draft from a real DDM scaffold.</p><small>Profiles: $(ProfileExamples $candidates)</small></div>")}
    if($partial.Count -or $retained.Count){$suggestions.Add("<div class=`"suggestion amber`"><strong>Preserve coverage during migration</strong><p>$($partial.Count) partial mappings and $($retained.Count) settings to retain. Keep source policies until every intended setting has a tested home.</p><small>Profiles: $(ProfileExamples @($partial+$retained))</small></div>")}
    if($updates.Count){$suggestions.Add('<div class="suggestion amber"><strong>Check iOS update-deferral prerequisites</strong><p>CombinedPeriodInDays requires iOS/iPadOS 18+ and supervision. Confirm the legacy delay is enabled; a deferral is not an enforcement deadline.</p></div>')}
    if($macUpdates.Count){$suggestions.Add('<div class="suggestion amber"><strong>Check macOS update prerequisites</strong><p>Major, minor and system deferrals require macOS 15+ and supervision. Verify each period independently; do not replace an installation schedule with a visibility delay.</p></div>')}
    if($blockedChecks.Count){$suggestions.Add("<div class=`"suggestion red`"><strong>Review device compatibility ($($blockedChecks.Count) settings)</strong><p>Some platform-wide devices fail OS/supervision checks. Resolve assignment targeting and prerequisites before piloting. Retain legacy coverage.</p></div>")}
    if(-not $suggestions.Count){$suggestions.Add('<div class="suggestion green"><strong>No new candidates flagged</strong><p>Review existing declarative settings and profiles with no confirmed configured settings. No source policy removal is approved by this assessment.</p></div>')}
    $body=foreach($r in $Assessment.settings){
        $current=ConvertTo-Json -InputObject $r.currentValue -Compress -Depth 100
        $proposed=ConvertTo-Json -InputObject $r.proposedValue -Compress -Depth 100
        $colour=StatusColour $r.classification
        $rowPlatform=Get-Field $r 'platform' 'iOS'
        $rowMinimumOS=Get-Field $r 'minimumOS' (Get-Field $r 'minimumIOS' '')
        $compatibilityText=Get-Field $r 'estateCompatibility' 'Not assessed'
        $targetAvailability=Get-Field $r 'intuneSupport' 'Unverified'
        $compatibilityColour=switch(Get-Field $r 'compatibilityStatus' ''){'ChecksPassed' {'green'};{$_ -in @('Blocked','Mixed')} {'red'};default {'amber'}}
        "<tr class=`"setting-row`" data-profile=`"$(Encode $r.sourcePolicyId)`" data-status=`"$(Encode $r.classification)`"><td>$(Encode $r.sourcePolicyName)<small>$(Encode $rowPlatform)</small></td><td>$(Encode $r.displayName)<small>$(Encode $r.currentTechnology)</small></td><td class=`"current-value`"><code>$(Encode $current)</code></td><td><span class=`"badge $colour`">$(Encode $r.classification)</span></td><td>$(Encode $r.targetPath)<small>$(Encode $proposed)</small><small>Intune: $(Encode $targetAvailability)</small></td><td>$(Encode $rowMinimumOS)<small>Supervision: $(Encode $r.supervisionRequired)</small><small class=`"compatibility $compatibilityColour`">$(Encode $compatibilityText)</small></td><td>$(Encode $r.notes)</td></tr>"
    }
    $counts=($Assessment.summary | ForEach-Object {"<button type=`"button`" aria-pressed=`"false`" data-status=`"$(Encode $_.classification)`" class=`"badge $(StatusColour $_.classification)`">$(Encode $_.classification): <b>$($_.count)</b></button>"}) -join ''
    $profileBody=foreach($profile in $Assessment.profiles) {
        $percentage=Get-Field $profile 'ddmApplicabilityPercent' $profile.coveragePercent
        $colour=if($null -eq $percentage){'amber'}elseif($percentage -eq 100){'green'}elseif($percentage -gt 0){'amber'}else{'red'}
        $display=if($null -eq $percentage){'Not assessed'}else{"$percentage%"}
        $detail=if($profile.settings){"$($profile.mapped) candidates / $(Get-Field $profile 'alreadyDDM' 0) already DDM / $($profile.settings) configured settings"}else{'No confirmed configured settings extracted; check the source profile.'}
        "<tr><td><button type=`"button`" class=`"profile-link`" data-profile=`"$(Encode $profile.id)`" aria-pressed=`"false`">$(Encode $profile.name)</button><small>$(Encode $profile.platform)</small></td><td><span class=`"badge $colour`">$(Encode $display)</span><small>$(Encode $detail)</small></td><td>$(Encode $profile.notes)</td></tr>"
    }
    $limitations=($Assessment.limitations | ForEach-Object {"<li>$(Encode $_)</li>"}) -join ''
    $html=@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$(Encode $label) DDM assessment</title>
<style>
*{box-sizing:border-box}button{font:inherit;cursor:pointer;border:0}button.metric{text-align:left;width:100%}button.badge{border:1px solid transparent}button[aria-pressed="true"]{outline:3px solid #0071c5;outline-offset:2px}button:focus-visible,input:focus-visible{outline:3px solid #0071c5;outline-offset:2px}.profile-link{padding:0;background:transparent;color:#0071c5;text-align:left;text-decoration:underline;overflow-wrap:anywhere}.profile-table{min-width:800px}.profile-table th:first-child{width:32%}.profile-table th:nth-child(2){width:23%}.clear-filters{padding:9px 12px;border-radius:7px;background:#e8eef7;color:#203047}.filter-state{color:#52627a;font-size:12px;margin:8px 0}body{font:14px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;margin:0;color:#203047;background:#f3f6fa}main{width:100%;padding:24px 32px;margin:auto;max-width:3000px}h1{color:#0071c5;font-size:28px;margin:0 0 6px}h2{font-size:18px;margin:0 0 12px}p{margin:8px 0}header,article,.scroll{background:white;border:1px solid #e0e6ed;border-radius:12px;margin-bottom:18px}header,article{padding:22px 24px}small{display:block;color:#52627a;margin-top:7px;overflow-wrap:anywhere}header .meta{color:#64748b;overflow-wrap:anywhere}header{border-top:4px solid #0071c5}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:16px 0}.metric{padding:12px 16px;border-radius:8px;border-left:4px solid #0071c5;background:#f1f6fc}.metric strong{display:block;font-size:26px;line-height:1.2}.metric span{font-size:13px}.metric.green{border-left-color:#258350;background:#eaf6ed;color:#1c6339}.metric.amber{border-left-color:#c08713;background:#fff6df;color:#835500}.metric.red{border-left-color:#c13c41;background:#fceced;color:#9e2730}.badge{display:inline-block;font-size:11px;font-weight:650;border-radius:6px;padding:5px 8px;overflow-wrap:anywhere;white-space:normal}.green{background:#eaf6ed;color:#1c6339}.amber{background:#fff6df;color:#835500}.red{background:#fceced;color:#9e2730}.statuses{display:flex;flex-wrap:wrap;gap:8px}.legend{font-size:12px;color:#52627a;margin-top:12px}.legend .badge{margin-right:4px}.suggestions{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}.suggestion{min-width:0;border:1px solid currentColor;border-left-width:4px;border-radius:8px;padding:14px 16px;overflow-wrap:anywhere}.suggestion strong{font-size:14px}.suggestion p{font-size:13px;line-height:1.45}.suggestion small{color:inherit;font-size:12px}details{border-top:1px solid #e0e6ed;margin-top:16px;padding-top:12px}summary{cursor:pointer;color:#52627a;font-weight:600}ul{padding-left:20px}.table-tools{display:flex;gap:16px;align-items:center;justify-content:space-between;margin:0 0 12px}.table-tools h2{margin:0}input{padding:10px 12px;border:1px solid #bbc8d8;border-radius:7px;width:min(50%,520px);font:inherit}.scroll{overflow-x:auto}table{width:100%;min-width:1280px;table-layout:fixed;border-collapse:collapse;background:white}col.profile{width:13%}col.setting{width:17%}col.current{width:220px;min-width:220px;max-width:220px}col.status{width:180px}col.target{width:18%}col.requirements{width:170px}td,th{padding:13px 14px;text-align:left;vertical-align:top;border-bottom:1px solid #e0e6ed;overflow-wrap:anywhere;word-break:break-word;white-space:normal}th{background:#0071c5;color:white;font-size:12px;letter-spacing:.2px}td{font-size:13px}tbody tr:nth-child(even){background:#f8fafc}tbody tr:hover{background:#f0f6ff}.compatibility{border-radius:5px;padding:5px;font-size:11px}.current-value{width:220px;min-width:220px;max-width:220px;overflow-wrap:anywhere;word-break:break-word;white-space:normal}.current-value code{display:block;width:100%;max-width:100%;white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word;font:12px/1.6 ui-monospace,SFMono-Regular,Consolas,monospace}tr[hidden]{display:none}.empty{text-align:center;padding:24px;color:#64748b}
@media(min-width:2400px){main{padding:32px 48px}td{padding:15px 18px;font-size:14px}.current-value code{font-size:13px}}
@media(max-width:1350px){.suggestions{grid-template-columns:repeat(2,minmax(0,1fr))}main{padding:20px}.metrics{gap:8px}}
@media(max-width:700px){main{padding:12px}header,article{padding:16px}.metrics,.suggestions{grid-template-columns:repeat(2,minmax(0,1fr))}h1{font-size:23px}.table-tools{display:block}input{width:100%;margin-top:12px}}
@media print{input{display:none}body{background:white}main{padding:0;max-width:none}header,article{break-inside:avoid}table{min-width:0}.scroll{overflow:visible}td,th{padding:6px;font-size:10px}col.current{width:110px;min-width:110px;max-width:110px}.current-value{width:110px;min-width:110px;max-width:110px}col.status{width:100px}col.requirements{width:90px}.current-value code{font-size:9px}.suggestions{grid-template-columns:repeat(2,minmax(0,1fr))}}
</style></head><body><main>
<header><h1>$(Encode $label) DDM migration assessment</h1><p class="meta">Tenant: $(Encode $Assessment.tenantId) · $(Encode $Assessment.assessedAt) · v$(Encode $Assessment.toolVersion)</p>
<div class="metrics"><button type="button" class="metric" data-group="all" aria-pressed="true"><strong>$($Assessment.profiles.Count)</strong><span>Profiles assessed · $($Assessment.settings.Count) settings</span></button><button type="button" class="metric green" data-group="candidates" aria-pressed="false"><strong>$($candidates.Count)</strong><span>Migration candidates · review required</span></button><button type="button" class="metric amber" data-group="retain" aria-pressed="false"><strong>$($partial.Count+$retained.Count)</strong><span>Partial mappings / settings to retain</span></button><button type="button" class="metric red" data-group="review" aria-pressed="false"><strong>$($review.Count)</strong><span>Unresolved settings · investigate</span></button></div>
<div class="statuses">$counts</div><p class="legend"><span class="badge green">Green</span> DDM identified or a mapping candidate <span class="badge amber">Amber</span> Partial / retain <span class="badge red">Red</span> Review / unsupported / deprecated. Colours indicate assessment status, not deployment readiness.</p></header>
<article><h2>Suggested next steps</h2><p class="legend">Actions are based on the settings and compatibility evidence in this assessment.</p><div class="suggestions">$($suggestions -join '')</div><details><summary>Assessment scope and review boundaries</summary><ul>$limitations</ul><p>Inventory complete: $(Encode $Assessment.inventoryComplete). Settings Catalog instances and custom payload keys are assessed as configured. Legacy default-valued properties are excluded unless explicit export evidence confirms them. Review legacy coverage against configured intent in Intune. No source policy replacement or removal is approved.</p></details></article>
<article><h2>Configuration profiles — DDM coverage</h2><p class="legend">Percentage = mapping candidates plus existing DDM settings ÷ assessed configured settings. Click a profile to filter its settings. This is coverage, not confirmed deployment compatibility; legacy coverage is indicative.</p><div class="scroll"><table class="profile-table"><thead><tr><th>Configuration profile</th><th>DDM coverage</th><th>Assessment notes</th></tr></thead><tbody>$($profileBody -join '')</tbody></table></div></article>
<div class="table-tools"><h2>Configured settings</h2><button type="button" id="clear-filters" class="clear-filters">Clear filters</button><input id="filter" aria-label="Filter settings" placeholder="Filter profiles, settings or recommendations"></div>
<p id="filter-state" class="filter-state" aria-live="polite"></p><div class="scroll"><table id="settings-table"><colgroup><col class="profile"><col class="setting"><col class="current"><col class="status"><col class="target"><col class="requirements"><col></colgroup><thead><tr><th>Profile</th><th>Setting / mechanism</th><th>Current</th><th>Classification</th><th>Proposed target</th><th>Apple requirements</th><th>Recommendation</th></tr></thead><tbody>$($body -join '')</tbody></table></div>
<p id="no-results" class="empty" hidden>No settings match your filter.</p>
<script>
(function(){
const search=document.getElementById('filter'),rows=Array.from(document.querySelectorAll('#settings-table .setting-row'));
let profile='',status='',group='all';
const groups={candidates:['DDM_DIRECT','DDM_SEMANTIC'],retain:['DDM_PARTIAL','LEGACY_RETAIN','MODERN_MDM_RETAIN']};
function apply(){
 const q=search.value.toLowerCase();let visible=0;
 rows.forEach(r=>{const c=r.dataset.status;const matchesGroup=group==='all'||(group==='review'?!['ALREADY_DDM','DDM_DIRECT','DDM_SEMANTIC','DDM_PARTIAL','LEGACY_RETAIN','MODERN_MDM_RETAIN'].includes(c):groups[group].includes(c));
 r.hidden=!(matchesGroup&&(!profile||r.dataset.profile===profile)&&(!status||c===status)&&r.textContent.toLowerCase().includes(q));if(!r.hidden)visible++;});
 document.querySelectorAll('[data-group],[data-status],[data-profile]').forEach(b=>{if(b.tagName!=='BUTTON')return;const active=b.hasAttribute('data-group')?(!status&&b.dataset.group===group):b.hasAttribute('data-status')?b.dataset.status===status:b.dataset.profile===profile;b.setAttribute('aria-pressed',String(active));});
 document.getElementById('no-results').hidden=visible!==0;
 document.getElementById('filter-state').textContent=visible+' of '+rows.length+' configured settings shown'+(profile?' · profile filter active':'')+(status?' · '+status:group!=='all'?' · '+group:'');
}
document.addEventListener('click',function(e){const b=e.target.closest('button');if(!b)return;
 if(b.hasAttribute('data-group')){group=b.dataset.group;status='';if(group==='all'){profile='';}}
 else if(b.hasAttribute('data-status')){status=status===b.dataset.status?'':b.dataset.status;group='all';}
 else if(b.hasAttribute('data-profile')){profile=profile===b.dataset.profile?'':b.dataset.profile;}
 else if(b.id==='clear-filters'){profile='';status='';group='all';search.value='';}else{return;}apply();});
search.addEventListener('input',apply);apply();
})();
</script></main></body></html>
"@
    Set-Content -LiteralPath (Join-Path $OutputPath ($reportName+'.html')) -Value $html -Encoding utf8
}
Export-ModuleMember -Function Connect-DDMGraph,Get-DDMInventory,Invoke-DDMAssessment,Export-DDMReport,Get-DDMInstanceLeaves,Write-DDMJson
