#Requires -Version 7.2
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/AppleDDM.psm1') -Force
$script:Passed=0
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"};$script:Passed++;Write-Host "PASS: $Message"}
function Throws([scriptblock]$Action,[string]$Message){$thrown=$false;try{& $Action}catch{$thrown=$true};Assert $thrown $Message}
function Copy-Json($Value){ConvertTo-Json -InputObject $Value -Depth 100 | ConvertFrom-Json -AsHashtable}
$work=Join-Path ([IO.Path]::GetTempPath()) ('ddm-test-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $work
try {
    # Syntax is validated for every PowerShell source, including optional writer.
    foreach($file in Get-ChildItem $root -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}) {
        $parseErrors=$null;$tokens=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0) "Syntax: $($file.Name)"
    }
    # Authentication boundary: no SDK or tenant credentials needed.
    $authModule=Get-Module AppleDDM
    $auth=& $authModule {
        function Get-Module { param($ListAvailable,$Name) return $true }
        function Import-Module { param($Name) }
        $script:AuthCalls=0
        $script:AuthArgs=@{}
        $script:AuthContext=$null
        function Get-MgContext { return $script:AuthContext }
        function Connect-MgGraph {
            param($Scopes,$ContextScope,$NoWelcome,$Environment,$TenantId,$ClientId,$UseDeviceAuthentication)
            $script:AuthCalls++
            $script:AuthArgs=@{Scopes=$Scopes;ContextScope=$ContextScope;DeviceCode=$UseDeviceAuthentication}
            if($script:FailAuth){throw 'Mock sign-in failed'}
            $script:AuthContext=[pscustomobject]@{TenantId=$TenantId;ClientId=$ClientId;Environment=$Environment;AuthType='Delegated';Account='test@example.invalid';Scopes=$Scopes}
            if($script:WrongTenant){$script:AuthContext.TenantId='wrong-tenant'}
        }
        $script:FailAuth=$false;$script:WrongTenant=$false
        $results=@{}
        Connect-DDMGraph -TenantId tenant -ClientId client -DeviceCode
        $results.first=($script:AuthCalls -eq 1 -and $script:AuthArgs.DeviceCode -and $script:AuthArgs.ContextScope -eq 'Process')
        Connect-DDMGraph -TenantId tenant -ClientId client -DeviceCode
        Connect-DDMGraph -TenantId tenant -ClientId client
        $results.repeat=($script:AuthCalls -eq 1)
        Connect-DDMGraph -TenantId tenant -ClientId client -IncludeDeviceInventory
        $results.inventory=($script:AuthCalls -eq 2 -and $script:AuthArgs.Scopes -contains 'DeviceManagementManagedDevices.Read.All')
        Connect-DDMGraph -TenantId tenant -ClientId client -IncludeDeviceInventory
        $results.inventoryRepeat=($script:AuthCalls -eq 2)
        Connect-DDMGraph -TenantId tenant -ClientId client -Write
        $results.write=($script:AuthCalls -eq 3 -and $script:AuthArgs.Scopes -contains 'DeviceManagementConfiguration.ReadWrite.All')
        Connect-DDMGraph -TenantId tenant -ClientId client
        $results.writeReuse=($script:AuthCalls -eq 3)
        Connect-DDMGraph -TenantId other-tenant -ClientId client
        $results.tenant=($script:AuthCalls -eq 4)
        Connect-DDMGraph -TenantId other-tenant -ClientId other-client
        $results.client=($script:AuthCalls -eq 5)
        $script:AuthContext.Environment='USGov'
        Connect-DDMGraph -TenantId other-tenant -ClientId other-client
        $results.cloud=($script:AuthCalls -eq 6)
        $script:AuthContext.AuthType='AppOnly'
        Connect-DDMGraph -TenantId other-tenant -ClientId other-client
        $results.appOnly=($script:AuthCalls -eq 7)
        $script:AuthContext=[pscustomobject]@{TenantId='other-tenant'}
        Connect-DDMGraph -TenantId other-tenant -ClientId other-client
        $results.incomplete=($script:AuthCalls -eq 8)
        $script:AuthContext=$null;$script:WrongTenant=$true
        try {Connect-DDMGraph -TenantId tenant -ClientId client;$results.wrongTenant=$false} catch {$results.wrongTenant=$true}
        $script:AuthContext=$null;$script:WrongTenant=$false;$script:FailAuth=$true
        try {Connect-DDMGraph -TenantId tenant -ClientId client;$results.failure=$false} catch {$results.failure=$true}
        return $results
    }
    Assert $auth.first 'Fresh authentication uses process scope and the selected device-code flow'
    Assert $auth.repeat 'Repeated interactive/device-code assessments reuse a suitable session without another sign-in'
    Assert $auth.inventory 'Device inventory requests additional permission when missing'
    Assert $auth.inventoryRepeat 'Repeated inventory assessment reuses its consented session'
    Assert $auth.write 'Read-only session cannot skip authentication for write permission'
    Assert $auth.writeReuse 'Configuration read can reuse an existing configuration write permission'
    Assert $auth.tenant 'A different requested tenant requires authentication'
    Assert $auth.client 'A different requested client requires authentication'
    Assert $auth.cloud 'A non-global cloud session is not reused'
    Assert $auth.appOnly 'App-only context is not reused for delegated authentication'
    Assert $auth.incomplete 'Incomplete SDK context triggers authentication safely'
    Assert $auth.wrongTenant 'Unexpected tenant after sign-in is rejected before discovery'
    Assert $auth.failure 'Authentication failures propagate without retrying sign-in'
    # Live Graph can return profiles with no extractable settings.
    foreach($platform in @('iOS','macOS')) {
        foreach($kind in @('settingsCatalog','legacy')) {
            foreach($count in @(0,1,2)) {
                $policy=@{id="shape-$platform-$kind-$count";platform=$platform;sourceKind=$kind;settingsProvenance='explicit'}
                if($kind -eq 'settingsCatalog') {
                    $policy.settings=@(for($i=0;$i -lt $count;$i++) {@{settingInstance=@{settingDefinitionId="unknown-$i";simpleSettingValue=@{value=$i}}}})
                } else {
                    for($i=0;$i -lt $count;$i++) {$policy["unknown-$i"]=$i}
                }
                $shapeAssessment=Invoke-DDMAssessment -Inventory @{schemaVersion=1;policies=@($policy);definitions=@()} -Platform All
                $expected=$count
                Assert ($shapeAssessment.settings.Count -eq $expected -and $shapeAssessment.profiles[0].settings -eq $expected) "$platform $kind retains array shape with $count extracted settings in All mode"
                if($count -eq 0) {
                    Assert ($shapeAssessment.profiles.Count -eq 1 -and $null -eq $shapeAssessment.profiles[0].ddmApplicabilityPercent) 'Empty profile is listed without artificial setting rows or a misleading percentage'
                    Export-DDMReport $shapeAssessment (Join-Path $work "$platform-$kind-empty")
                    Assert (Test-Path (Join-Path $work "$platform-$kind-empty/Apple-DDM-Assessment.html")) 'Empty-profile assessment renders its combined HTML report'
                }
            }
        }
    }
    $defaultProfile=@{id='defaults';platform='macOS';sourceKind='legacy';passwordRequired=$true;passwordMinimumLength=8;cameraBlocked=$false;zeroValue=0;emptyText='';emptyList=@();mode='notConfigured';browser='browserDefault';name='Metadata name';isAssigned=$true}
    $configuredOnly=Invoke-DDMAssessment -Inventory @{schemaVersion=1;policies=@($defaultProfile);definitions=@()} -Platform All
    Assert ($configuredOnly.settings.Count -eq 2) 'Legacy defaults, empty values and metadata are excluded from configured setting rows'
    Assert ($configuredOnly.profiles[0].ddmApplicabilityPercent -eq 100) 'Profile DDM percentage uses assessed configured settings as the denominator'
    $defaultProfile.configuredSettingKeys=@('cameraBlocked','zeroValue')
    $confirmed=Invoke-DDMAssessment -Inventory @{schemaVersion=1;policies=@($defaultProfile);definitions=@()} -Platform All
    Assert ($confirmed.settings.Count -eq 2 -and @($confirmed.settings | Where-Object {$_.currentValue -ceq $false -or $_.currentValue -ceq 0}).Count -eq 2) 'Reviewed configured keys preserve explicit false and zero while excluding other returned fields'
    $inventory=Get-Content (Join-Path $root 'samples/tenant-export.json') -Raw | ConvertFrom-Json -AsHashtable
    $a=Invoke-DDMAssessment $inventory
    Assert ($a.settings.Count -eq 11) 'All sample settings, including true/false, are retained'
    Assert (@($a.settings | Where-Object classification -eq 'DDM_DIRECT').Count -eq 5) 'Five passcode candidates are classified'
    Assert (@($a.settings | Where-Object classification -eq 'DDM_SEMANTIC').Count -eq 1) 'Enabled iOS deferral maps semantically'
    Assert (($a.summary | Measure-Object count -Sum).Sum -eq 11) 'Summary counts equal the setting count'
    Assert ($a.profiles[0].assignments -is [array]) 'Empty assignment arrays stay arrays'
    $copy=Copy-Json $inventory; $copy.policies[1].softwareUpdatesForceDelayed=$false
    $disabled=Invoke-DDMAssessment $copy
    Assert (($disabled.settings | Where-Object sourceKey -eq 'softwareUpdatesEnforcedDelayInDays').classification -eq 'REQUIRES_REVIEW') 'Disabled deferral does not generate a target delay'
    $copy=Copy-Json $inventory;$copy.policies[0].passcodeMinimumLength=100
    Assert (((Invoke-DDMAssessment $copy).settings | Where-Object sourceKey -eq 'passcodeMinimumLength').classification -eq 'REQUIRES_REVIEW') 'Out-of-range passcode is blocked'
    $copy=Copy-Json $inventory;$copy.policies[0].passcodeMinimumLength=0
    Assert (((Invoke-DDMAssessment $copy).settings | Where-Object sourceKey -eq 'passcodeMinimumLength').currentValue -ceq 0) 'Zero is retained'
    $copy=Copy-Json $inventory;$copy.policies[0].passcodeMinimumLength='8'
    Assert (((Invoke-DDMAssessment $copy).settings | Where-Object sourceKey -eq 'passcodeMinimumLength').classification -eq 'REQUIRES_REVIEW') 'String numbers are not silently coerced'
    $unknown=@{schemaVersion=1;policies=@(@{id='catalog';name='Unknown';sourceKind='settingsCatalog';settings=@(@{settingInstance=@{settingDefinitionId='unknown-id';simpleSettingValue=@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue';value=8}}})});definitions=@()}
    Assert ((Invoke-DDMAssessment $unknown).settings[0].classification -eq 'REQUIRES_REVIEW') 'Unknown Settings Catalog metadata stays unknown'
    $unknown.definitions=@(@{id='unknown-id';baseUri='com.apple.configuration.passcode.settings';offsetUri='MinimumLength'})
    Assert ((Invoke-DDMAssessment $unknown).settings[0].classification -eq 'ALREADY_DDM') 'Authoritative declaration identity marks an existing DDM setting'
    $group=@{settingDefinitionId='group';groupSettingCollectionValue=@(@{children=@(@{settingDefinitionId='child';choiceSettingValue=@{value='enabled';children=@(@{settingDefinitionId='grandchild';simpleSettingValue=@{value=8}})}})})}
    $leaves=@(Get-DDMInstanceLeaves $group)
    Assert ($leaves.Count -eq 2 -and $leaves[1].key -eq 'grandchild') 'Nested groups and choice children are traversed'
    $plist='<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>PayloadContent</key><array><dict><key>PayloadType</key><string>com.apple.mobiledevice.passwordpolicy</string><key>minLength</key><integer>8</integer><key>allowSimple</key><false/></dict></array></dict></plist>'
    $custom=@{schemaVersion=1;policies=@(@{id='custom';displayName='XML';sourceKind='legacy';payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plist))})}
    $customAssessment=Invoke-DDMAssessment $custom
    Assert ($customAssessment.settings.Count -eq 2) 'XML mobileconfig extracts payload settings without fetching its DTD'
    Assert (($customAssessment.settings | Where-Object sourceKey -like '*/allowSimple').proposedValue -ceq $true) 'AllowSimple false is inverted to RequireComplexPasscode true'
    $custom.policies[0].payload='NOT BASE64'
    Assert ((Invoke-DDMAssessment $custom).settings[0].classification -eq 'REQUIRES_REVIEW') 'Opaque custom payload is reported'
    $copy=Copy-Json $inventory;$copy.policies[0].displayName='<script>alert(1)</script>';$copy.policies[0].unknownSetting='=CMD()';$copy.policies[0].longValue=('https://example.invalid/'+('unbrokenvalue'*200))
    $report=Invoke-DDMAssessment $copy;Export-DDMReport $report $work
    $html=Get-Content (Join-Path $work 'iOS-DDM-Assessment.html') -Raw
    Assert (-not $html.Contains('<script>alert(1)</script>') -and $html.Contains('&lt;script&gt;')) 'HTML escapes tenant content'
    Assert ($html.Contains('table-layout:fixed') -and $html.Contains('col.current{width:220px;min-width:220px;max-width:220px}') -and $html.Contains('overflow-wrap:anywhere')) 'Current column is fixed-width and wraps long content'
    Assert ($html.Contains('Suggested next steps') -and $html.Contains('Review DDM migration candidates (6)')) 'Suggestions are derived from actual candidate counts'
    Assert ($html.Contains('badge green') -and $html.Contains('badge amber') -and $html.Contains('badge red')) 'RAG status badges have readable text labels'
    Assert ($html.Contains('colours indicate assessment status') -or $html.Contains('Colours indicate assessment status')) 'RAG legend distinguishes status from deployment readiness'
    Assert ($html.Contains($copy.policies[0].longValue)) 'Very long unbroken Current value is preserved in the report'
    Assert ($html.Contains('.metric.green{border-left-color:#258350;background:#eaf6ed') -and $html.Contains('.metric.amber{border-left-color:#c08713;background:#fff6df') -and $html.Contains('.metric.red{border-left-color:#c13c41;background:#fceced')) 'RAG summary fills override the default metric background'
    $csv=Import-Csv (Join-Path $work 'iOS-DDM-Assessment.csv')
    Assert (($csv | Where-Object sourceKey -eq 'unknownSetting').currentValue.StartsWith("'=")) 'CSV protects formula-like values'
    $empty=Invoke-DDMAssessment @{schemaVersion=1;policies=@();definitions=@()};Export-DDMReport $empty (Join-Path $work 'empty')
    Assert ($empty.settings.Count -eq 0 -and $empty.profiles.Count -eq 0) 'Empty tenant produces an empty valid assessment'
    Throws {Invoke-DDMAssessment @{policies=@()}} 'Malformed inventory is rejected'
    # Template generation uses mock IDs on purpose; no sample can be published.
    $assessmentPath=Join-Path $work 'assessment.json';Write-DDMJson $a $assessmentPath
    $params=@{Assessment=$assessmentPath;SourcePolicyId='demo-passcode';Template=(Join-Path $root 'samples/demo-template.json');Bindings=(Join-Path $root 'samples/demo-bindings.json');OutputPath=(Join-Path $work 'draft')}
    Throws {& (Join-Path $root 'New-AppleDDMMigrationPolicy.ps1') @params} 'Partial generation is refused by default'
    & (Join-Path $root 'New-AppleDDMMigrationPolicy.ps1') @params -AllowPartial
    $draft=Get-Content (Join-Path $params.OutputPath 'proposed-policy.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($draft.settings[0].settingInstance.simpleSettingValue.value -eq 8) 'Generation applies assessed integer value'
    Assert ($draft.settings[1].settingInstance.choiceSettingValue.value -eq 'DEMO_ONLY_true') 'Generation uses an explicit reviewed choice option'
    Assert (-not $draft.ContainsKey('assignments') -and -not $draft.settings[0].ContainsKey('id')) 'Generated JSON excludes assignments and read-only setting IDs'
    $manifest=Get-Content (Join-Path $params.OutputPath 'migration-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($manifest.omittedSettings.Count -eq 5 -and -not $manifest.sourceReplacementApproved) 'Partial output lists every omitted source setting'
    $publish=@{PolicyFile=(Join-Path $params.OutputPath 'proposed-policy.json');ManifestFile=(Join-Path $params.OutputPath 'migration-manifest.json');TenantId='real-tenant';ReviewedRequirements=$true;WhatIf=$true}
    Throws {& (Join-Path $root 'Publish-AppleDDMMigrationPolicy.ps1') @publish} 'Offline demos cannot be published to a real tenant'
    $publish.TenantId='DEMO-OFFLINE'
    & (Join-Path $root 'Publish-AppleDDMMigrationPolicy.ps1') @publish
    Assert $true 'WhatIf returns before authentication or any Graph call'
    $draft['assignments']=@();Write-DDMJson $draft $publish.PolicyFile
    Throws {& (Join-Path $root 'Publish-AppleDDMMigrationPolicy.ps1') @publish} 'Policy edits invalidate the manifest hash'
    # Mock the Graph boundary to verify pagination, platform filtering and GET-only discovery.
    $module=Get-Module AppleDDM
    $discovered=& $module {
        $script:Calls=[Collections.Generic.List[string]]::new()
        function Invoke-MgGraphRequest {
            param($Method,$Uri,$OutputType)
            if($Method -ne 'GET'){throw 'Read-only inventory issued a write.'}
            $script:Calls.Add($Uri)
            switch -Regex ($Uri) {
                'configurationPolicies\?page=2$' {return @{value=@(@{id='ios';name='iOS';platforms='iOS';technologies='mdm'})}}
                'configurationPolicies$' {return @{value=@(@{id='windows';platforms='windows10'});'@odata.nextLink'='https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?page=2'}}
                'configurationPolicies/ios/settings$' {return @{value=@()}}
                '/assignments$' {return @{value=@()}}
                'deviceConfigurations$' {return @{value=@(@{id='legacy';'@odata.type'='#microsoft.graph.iosGeneralDeviceConfiguration'},@{id='mac';'@odata.type'='#microsoft.graph.macOSGeneralDeviceConfiguration'})}}
                'deviceConfigurations/legacy$' {return @{id='legacy';displayName='Legacy';'@odata.type'='#microsoft.graph.iosGeneralDeviceConfiguration';passcodeRequired=$true}}
                'configurationSettings$' {return @{value=@(@{id='def';applicability=@{platform='iOS'}},@{id='windef';applicability=@{platform='windows10'}})}}
                default {throw "Unexpected mock URL $Uri"}
            }
        }
        function Get-MgContext {return @{TenantId='mock-tenant'}}
        $result=Get-DDMInventory
        return @{inventory=$result;calls=$script:Calls.ToArray()}
    }
    Assert ($discovered.inventory.policies.Count -eq 2) 'Graph discovery paginates and filters out non-iOS profiles'
    Assert ($discovered.inventory.definitions.Count -eq 1) 'Graph definitions are filtered by applicability'
    Assert ($discovered.calls.Count -eq 8) 'Discovery fetches detail and assignments with GET only'
    $rejected=& $module {try{Invoke-DDMGraphGet 'https://example.com/beta/deviceManagement/configurationPolicies';$false}catch{$true}}
    Assert $rejected 'Foreign pagination host is refused'

    $macInventory=Get-Content (Join-Path $root 'samples/macos-tenant-export.json') -Raw | ConvertFrom-Json -AsHashtable
    $mac=Invoke-DDMAssessment -Inventory $macInventory -Platform macOS
    Assert ($mac.settings.Count -eq 15 -and $mac.profiles.Count -eq 3) 'macOS profiles are normalized without counting platform metadata'
    Assert (@($mac.settings | Where-Object {$_.classification -eq 'DDM_DIRECT'}).Count -eq 6) 'macOS password rules have separate platform mappings'
    $major=$mac.settings | Where-Object sourceKey -eq 'softwareUpdateMajorOSDeferredInstallDelayInDays'
    Assert ($major.targetPath.EndsWith('/MajorPeriodInDays') -and $major.minimumOS -eq '15.0') 'macOS major update maps to its own DDM period and OS prerequisite'
    Assert ($major.compatibilityEvidence.passed -eq 1 -and $major.compatibilityEvidence.blocked -eq 1 -and $major.compatibilityEvidence.unknown -eq 1) 'Compatibility counts supported, older and unknown device evidence'
    Assert ($major.compatibilityStatus -eq 'Mixed' -and $major.estateCompatibility.Contains('platform-wide')) 'Platform-wide compatibility never claims assignment targeting was resolved'
    Assert (($mac.settings | Where-Object sourceKey -eq 'softwareUpdatesEnforcedDelayInDays').classification -eq 'REQUIRES_REVIEW') 'Generic macOS delay is not expanded to every update type'
    Assert (($mac.settings | Where-Object sourceKey -eq 'privacyAccessControls').classification -eq 'LEGACY_RETAIN') 'PPPC workload is retained'
    $noDevices=Copy-Json $macInventory;$noDevices.deviceInventoryIncluded=$false
    Assert (((Invoke-DDMAssessment -Inventory $noDevices -Platform macOS).settings | Where-Object sourceKey -eq 'passwordRequired').compatibilityStatus -eq 'NotAssessed') 'Missing device inventory never reports compatibility'
    $notSupervised=Copy-Json $macInventory;$notSupervised.devices=@(@{id='unsupervised';operatingSystem='macOS';osVersion='15.2';isSupervised=$false})
    Assert (((Invoke-DDMAssessment -Inventory $notSupervised -Platform macOS).settings | Where-Object sourceKey -eq 'softwareUpdateMajorOSDeferredInstallDelayInDays').compatibilityStatus -eq 'Blocked') 'OS alone does not pass a supervision-required mapping'
    $allInventory=Get-Content (Join-Path $root 'samples/apple-tenant-export.json') -Raw | ConvertFrom-Json -AsHashtable
    $all=Invoke-DDMAssessment -Inventory $allInventory -Platform All
    Assert ($all.settings.Count -eq 26 -and $all.profiles.Count -eq 6) 'Combined assessment contains both platforms once'
    Assert ((Invoke-DDMAssessment -Inventory $allInventory -Platform iOS).settings.Count -eq 11) 'iOS selection excludes Mac settings'
    Assert ((Invoke-DDMAssessment -Inventory $allInventory -Platform macOS).settings.Count -eq 15) 'macOS selection excludes iOS settings'
    $macPath=Join-Path $work 'mac-assessment';Export-DDMReport $mac $macPath
    Assert ((Test-Path (Join-Path $macPath 'macOS-DDM-Assessment.html')) -and -not (Test-Path (Join-Path $macPath 'iOS-DDM-Assessment.html'))) 'Report names follow macOS platform selection'
    $macHtml=Get-Content (Join-Path $macPath 'macOS-DDM-Assessment.html') -Raw
    Assert ($macHtml.Contains('macOS DDM migration assessment') -and $macHtml.Contains('Check macOS update prerequisites') -and $macHtml.Contains('Review device compatibility')) 'macOS report displays platform-specific recommendations and compatibility'
    $allPath=Join-Path $work 'all';Export-DDMReport $all $allPath
    Assert (Test-Path (Join-Path $allPath 'Apple-DDM-Assessment.html')) 'Combined report uses Apple filename'
    $badPlatform=Copy-Json $macInventory;$badPlatform.policies[0].platform='iOS'
    Assert ((Invoke-DDMAssessment -Inventory $badPlatform -Platform macOS).profiles.Count -eq 2) 'Explicit platform metadata controls filtering'
    $macParams=@{Assessment=(Join-Path $macPath 'macOS-DDM-Assessment.json');SourcePolicyId='mac-password';Template=(Join-Path $root 'samples/macos-demo-template.json');Bindings=(Join-Path $root 'samples/macos-demo-bindings.json');AllowPartial=$true;OutputPath=(Join-Path $work 'mac-draft')}
    & (Join-Path $root 'New-AppleDDMMigrationPolicy.ps1') @macParams
    $macDraft=Get-Content (Join-Path $macParams.OutputPath 'proposed-policy.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($macDraft.platforms -eq 'macOS' -and $macDraft.settings[0].settingInstance.simpleSettingValue.value -eq 12) 'macOS draft generation preserves platform and assessed values'
    $macParams.Template=Join-Path $root 'samples/demo-template.json'
    Throws {& (Join-Path $root 'New-AppleDDMMigrationPolicy.ps1') @macParams} 'Cross-platform scaffolds are rejected'
    # Retained custom Mac families are classified from native Apple metadata.
    $catalogMac=@{schemaVersion=1;policies=@(@{id='pppc';platforms='macOS';sourceKind='settingsCatalog';name='PPPC';settings=@(@{settingInstance=@{settingDefinitionId='pppc-id';simpleSettingValue=@{value='allow'}}})});definitions=@(@{id='pppc-id';baseUri='com.apple.TCC.configuration-profile-policy';offsetUri='Services';applicability=@{platform='macOS'}})}
    Assert ((Invoke-DDMAssessment -Inventory $catalogMac -Platform macOS).settings[0].classification -eq 'MODERN_MDM_RETAIN') 'Settings Catalog PPPC retains the modern MDM classification'
    $targetDefinition=@{id='target';baseUri='com.apple.configuration.passcode.settings';offsetUri='MinimumLength';applicability=@{platform='macOS'}}
    $available=Copy-Json $macInventory;$available.definitions=@($targetDefinition)
    Assert (((Invoke-DDMAssessment -Inventory $available -Platform macOS).settings | Where-Object sourceKey -eq 'passwordMinimumLength').intuneSupport -eq 'Target definition verified in inventory') 'Intune target availability is verified independently from Apple support'
    $definitionAbsent=Copy-Json $macInventory
    Assert (((Invoke-DDMAssessment -Inventory $definitionAbsent -Platform macOS).settings | Where-Object sourceKey -eq 'passwordMinimumLength').intuneSupport.Contains('not resolved')) 'Absent Intune target definition is not advertised as tenant-supported'

    $choiceMac=@{schemaVersion=1;policies=@(@{id='password-choice';platforms='macOS';sourceKind='settingsCatalog';name='Password';settings=@(@{settingInstance=@{settingDefinitionId='mdm-min';choiceSettingValue=@{value='option-eight';children=@()}}})});definitions=@(@{id='mdm-min';baseUri='com.apple.mobiledevice.passwordpolicy';offsetUri='minLength';applicability=@{platform='macOS'};options=@(@{itemId='option-eight';optionValue=@{value=8}})})}
    $decoded=(Invoke-DDMAssessment -Inventory $choiceMac -Platform macOS).settings[0]
    Assert ($decoded.proposedValue -eq 8 -and $decoded.currentValue -eq 'option-eight' -and $decoded.classification -eq 'DDM_DIRECT') 'Actual Graph choice metadata is decoded without losing native source value'
    $shared=@{schemaVersion=1;policies=@(@{id='ddm-password';platforms='macOS';sourceKind='settingsCatalog';settings=@(@{settingInstance=@{settingDefinitionId='target';simpleSettingValue=@{value=12}}})});definitions=@($targetDefinition);deviceInventoryIncluded=$true;devices=@(@{operatingSystem='macOS';osVersion='12.7'})}
    $existing=(Invoke-DDMAssessment -Inventory $shared -Platform macOS).settings[0]
    Assert ($existing.classification -eq 'ALREADY_DDM' -and $existing.minimumOS -eq '13.0' -and $existing.compatibilityStatus -eq 'Blocked') 'Existing known DDM configurations receive macOS prerequisite checks'
    $customMac=@{schemaVersion=1;policies=@(@{id='custom-mac';platform='macOS';sourceKind='legacy';payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plist))})}
    Assert ((Invoke-DDMAssessment -Inventory $customMac -Platform macOS).settings.Count -eq 2) 'macOS custom mobileconfig payloads are extracted using the shared parser'
    # Expand Graph boundary mock to include macOS Catalog and managed devices.
    $macDiscovery=& $module {
        $script:MacCalls=[Collections.Generic.List[string]]::new()
        function Invoke-MgGraphRequest {
            param($Method,$Uri,$OutputType)
            if($Method -ne 'GET'){throw 'Discovery attempted a write'};$script:MacCalls.Add($Uri)
            switch -Regex ($Uri) {
                'configurationPolicies$' {return @{value=@(@{id='mac-catalog';platforms='macOS'},@{id='ios';platforms='iOS'})}}
                '/settings$' {return @{value=@()}}
                '/assignments$' {return @{value=@()}}
                'deviceConfigurations$' {return @{value=@(@{id='mac-legacy';'@odata.type'='#microsoft.graph.macOSGeneralDeviceConfiguration'},@{id='ios-legacy';'@odata.type'='#microsoft.graph.iosGeneralDeviceConfiguration'})}}
                'deviceConfigurations/mac-legacy$' {return @{id='mac-legacy';'@odata.type'='#microsoft.graph.macOSGeneralDeviceConfiguration';passwordRequired=$true}}
                'configurationSettings$' {return @{value=@(@{id='macdef';applicability=@{platform='macOS'}})}}
                'managedDevices\?' {return @{value=@(@{id='mac';operatingSystem='macOS';osVersion='15.2';isSupervised=$true},@{id='ios';operatingSystem='iOS';osVersion='18.5';isSupervised=$true})}}
                default {throw "Unexpected URL $Uri"}
            }
        }
        function Get-MgContext {return @{TenantId='mock-mac-tenant'}}
        $inventory=Get-DDMInventory -Platform macOS -IncludeDeviceInventory
        return @{inventory=$inventory;calls=$script:MacCalls.ToArray()}
    }
    Assert ($macDiscovery.inventory.policies.Count -eq 2 -and $macDiscovery.inventory.devices.Count -eq 1) 'Live macOS discovery filters profiles and managed devices correctly'
    Assert ($macDiscovery.inventory.deviceInventoryIncluded -and $macDiscovery.inventory.policies[0].platform -eq 'macOS') 'Live inventory retains compatibility inclusion and platform provenance'
    Assert ($macDiscovery.calls.Count -eq 8) 'Live macOS compatibility discovery remains GET-only'
    Write-Host "SUCCESS: $script:Passed assertions passed. Live Intune creation is not tested."
} finally {Remove-Item -LiteralPath $work -Recurse -Force}
