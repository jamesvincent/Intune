# Apple DDM Migration Analyser — iOS/iPadOS + macOS v0.2.4

A PowerShell tool that inventories Intune Apple configuration profiles, assesses separate, versioned sets of iOS and macOS migration mappings and produces HTML, CSV and JSON reports. It also generates draft Settings Catalog policies from reviewed tenant-exported DDM scaffolds, with an optional separate command to create them unassigned.

**Start with the offline example. Live assessment is read-only. Select `-Platform iOS`, `-Platform macOS` or `-Platform All` (default: iOS). No existing policy is modified, deleted, disabled or reassigned.**

## Profile-focused assessment — v0.2.4

The opening report lists each configuration profile and its DDM coverage percentage: mapped candidates plus existing DDM, divided by assessed configured settings. An empty profile shows Not assessed rather than a misleading percentage. This is setting coverage, not device deployment approval; legacy percentages are indicative because Graph does not record explicit/default intent per property.

Click summary cards or classification badges to filter, click a profile name to select that profile, and combine these with text search. Clear filters resets the view. The report contains configuration profiles and their settings only; setting definitions are lookup metadata, never standalone report rows.

Settings Catalog uses policy setting instances, and custom mobileconfig uses payload keys. Legacy resources return default properties as well as configured values: the default view excludes false, zero, empty collections/strings and default/not-configured enums. If a reviewed export confirms a default-valued setting was explicitly configured, supply `configuredSettingKeys` on that legacy profile (a list of keys to assess), or `settingsProvenance: "explicit"` for a sparse export containing only configured properties. Do not mark a full Graph resource explicit. This avoids treating every returned property as configured, while preserving confirmed false/zero intent. Metadata fields and profiles with no extracted settings do not produce artificial setting rows.

## HTML report layout — v0.2.3

The report uses a fixed 220px Current column with wrapped JSON, text, URLs and unbroken identifiers. It is designed for 1920×1080, expands up to 3000px on wider displays, and scrolls horizontally on smaller screens. The opening screen includes filled red/amber/green summary cards, labelled status badges and suggestions derived from the assessment. Green indicates a mapping candidate or existing DDM, amber indicates partial/retained coverage, and red indicates review-required findings; these colours do not imply deployment approval.

After updating, rerun the assessment to regenerate your tenant HTML report. Existing HTML files are static and do not pick up changes to the script automatically.

## macOS and combined Apple assessment — v0.2.2

Run a live macOS assessment with optional managed-device compatibility evidence:

```powershell
.\Invoke-AppleDDMMigrationAssessment.ps1 `
    -Live `
    -TenantId 'YOUR-TENANT-GUID' `
    -Platform macOS `
    -IncludeDeviceInventory `
    -OutputPath .\MacResults

Invoke-Item .\MacResults\macOS-DDM-Assessment.html
```

For both Apple platforms in one report, use `-Platform All`. It produces `Apple-DDM-Assessment.html`, `.csv` and `.json`. The combined table labels each profile with its platform; mappings and prerequisites never cross between iOS and macOS.

`-IncludeDeviceInventory` requests the additional read permission **DeviceManagementManagedDevices.Read.All**. Without it, policy discovery works as before and device compatibility is explicitly marked **Not assessed**. The collector retrieves only device IDs, OS, OS version, supervision evidence and enrolment type; it does not require device write permissions.

Compatibility results count **passed / blocked / unknown** OS and supervision checks against the platform-wide managed-device inventory. They **do not resolve profile assignments**, user groups, device filters, exclusions or effective policy applicability. No percentage represents deployment approval. Enrolment mode, device/user channel, scope, hardware, actual MDM availability and workload-specific requirements still need pilot validation. Graph supervision evidence can be incomplete for Macs; the tool preserves unknown evidence rather than inventing supervision.

The report independently indicates whether the mapped DDM target definition can be verified in the exported Intune definitions. Apple protocol support alone never establishes current tenant availability. Native choice values are decoded only when the actual definition supplies the selected option and its underlying value; unresolved options require review.

### Initial macOS mapping coverage

| Area | Behaviour |
| --- | --- |
| Password / passcode | Required, length, complexity, attempts, failed-login reset, age, history, alphanumeric and lock/grace mappings; OS and value-range checks |
| Update deferrals | Separate major, minor and system periods; macOS 15+ and supervision prerequisites; custom enable-flag checks |
| Generic update mode / delay | Review-required; a generic delay is not expanded to every update type |
| PPPC, FileVault, firewall, Gatekeeper | Retained; no native DDM replacement is asserted by this catalogue |
| System/kernel extensions, Wi-Fi, VPN, certificates, login window | Known custom Apple payload families retained; unrelated unknown keys remain review-required |
| Custom profiles | XML `.mobileconfig` payload settings extracted and compared; opaque/signed/binary payloads require review |
| Existing DDM | Classified from declaration identity; known target requirements compared to optional device evidence |

This is a conservative initial catalogue, not a universal conversion of every macOS setting. Password rules start at macOS 13, with some keys requiring 13.1; review the requirement on each row. Screensaver/lock behaviour and password-policy merging need explicit validation.

### Offline macOS and combined examples

```powershell
.\Invoke-AppleDDMMigrationAssessment.ps1 `
    -InputFile .\samples\macos-tenant-export.json `
    -Platform macOS `
    -OutputPath .\MacResults

.\Invoke-AppleDDMMigrationAssessment.ps1 `
    -InputFile .\samples\apple-tenant-export.json `
    -Platform All `
    -OutputPath .\AppleResults
```

The samples deliberately contain a supported Mac, an older Mac and unknown device evidence. Samples and generated sample reports contain demo data only.

### macOS draft generation

Use the existing template export and binding workflow, selecting a **macOS** DDM scaffold from the same tenant. Source and scaffold platforms must match. An offline demonstration:

```powershell
.\New-AppleDDMMigrationPolicy.ps1 `
    -Assessment .\MacResults\macOS-DDM-Assessment.json `
    -SourcePolicyId 'mac-password' `
    -Template .\samples\macos-demo-template.json `
    -Bindings .\samples\macos-demo-bindings.json `
    -AllowPartial `
    -OutputPath .\MacDraft
```

The optional publisher now accepts iOS and macOS and validates live definition applicability against the generated platform. All drafts remain unassigned; source configuration is never changed. Demo IDs cannot be used to create a real tenant policy.

Live tenant integration and device delivery still need acceptance testing in a development tenant. Offline and mocked Graph checks cover both platforms.

## Requirements

- PowerShell 7.2 or newer (`pwsh`), on Windows, macOS or Linux. Windows PowerShell 5.1 is not supported.
- Offline assessment and generation require no additional modules.
- Live operations require `Microsoft.Graph.Authentication`, an active Intune tenant, appropriate Intune RBAC and consent for the requested Graph permission.
- This release targets the global Microsoft Graph cloud and uses `/beta` endpoints. It does not support sovereign clouds.

## 1. Run the included example

Extract the ZIP, open PowerShell 7 and change directory into `AppleDDMMigrator`:

```powershell
Set-Location 'C:\Tools\AppleDDMMigrator'

.\Invoke-AppleDDMMigrationAssessment.ps1 `
    -InputFile .\samples\tenant-export.json `
    -OutputPath .\Results

Invoke-Item .\Results\iOS-DDM-Assessment.html
```

For macOS/Linux, use the equivalent extracted directory and open the HTML report with your browser. The sample is clearly labelled `DEMO-OFFLINE` and contains no tenant data.

Expected sample assessment:

| Classification | Settings |
| --- | ---: |
| DDM_DIRECT | 5 |
| DDM_SEMANTIC | 1 |
| DDM_PARTIAL | 1 |
| LEGACY_RETAIN | 3 |
| REQUIRES_REVIEW | 1 |

The report includes a search field, source values, proposed Apple paths, prerequisites and recommendations. `coveragePercent` measures mapping coverage, not readiness to remove a source policy.

## 2. Assess a real Intune tenant

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

.\Invoke-AppleDDMMigrationAssessment.ps1 `
    -Live `
    -TenantId 'YOUR-TENANT-GUID' `
    -OutputPath .\TenantResults
```

For device-code sign-in:

```powershell
.\Invoke-AppleDDMMigrationAssessment.ps1 `
    -Live `
    -TenantId 'YOUR-TENANT-GUID' `
    -DeviceCode `
    -OutputPath .\TenantResults
```

If your organisation uses its own approved public-client app registration, add `-ClientId 'YOUR-APP-GUID'`. Configure the app for the chosen interactive/device-code flow. No secret is required or accepted. Conditional Access and tenant consent policies still apply.

Assessment fix in v0.2.2: profiles with zero, one or multiple extracted settings retain an array shape. Empty profiles remain visible in the profile list rather than failing on `.Count`; v0.2.4 removes artificial setting rows. This applies to iOS, macOS and combined assessments.

Authentication fix in v0.2.1: repeated commands in the same PowerShell session reuse an existing delegated Graph connection when its tenant, explicit client ID, global cloud and permissions match. Interactive and device-code connections can both be reused. A missing connection, different tenant/client/cloud, or additional permission triggers authentication. Configuration read permission does not grant publishing rights; an existing configuration write permission can also satisfy a configuration read.

New connections remain process-scoped. Keep using the same PowerShell window to reuse them. Starting a new PowerShell process requires a new connection. To deliberately switch accounts, run `Disconnect-MgGraph` before the next command. Conditional Access or the SDK may still require reauthentication when a session becomes invalid.

Read permission: `DeviceManagementConfiguration.Read.All`. The tool connects when needed and then reads:

```text
GET /beta/deviceManagement/configurationPolicies
GET /beta/deviceManagement/configurationPolicies/{id}/settings
GET /beta/deviceManagement/configurationPolicies/{id}/assignments
GET /beta/deviceManagement/deviceConfigurations
GET /beta/deviceManagement/deviceConfigurations/{id}
GET /beta/deviceManagement/deviceConfigurations/{id}/assignments
GET /beta/deviceManagement/configurationSettings
```

It follows every collection's `@odata.nextLink`, filters for iOS, fetches full legacy resources and fails the run if discovery is incomplete. There are bounded retries for transient read failures. It does not call any assignment or source-policy write endpoint.

Outputs:

- `iOS-DDM-Assessment.html`: readable, searchable assessment.
- `iOS-DDM-Assessment.csv`: setting-level export, with formula-like cells protected.
- `iOS-DDM-Assessment.json`: structured assessment and original assignment metadata.
- `tenant-export.json`: re-runnable inventory, including policy definitions and assignments (live mode only).

Treat the export and reports as tenant configuration data. They can include custom payload values, identifiers and network/security settings. This PoC preserves raw source values locally; it is not a sanitisation tool. Authentication tokens are not exported.

Disconnect the process-scoped Graph session when finished:

```powershell
Disconnect-MgGraph
```

## 3. Generate an offline example draft

The included IDs are deliberately fabricated `DEMO_ONLY_*` fixtures. They illustrate JSON structure and cannot be used in Intune.

```powershell
.\New-AppleDDMMigrationPolicy.ps1 `
    -Assessment .\Results\iOS-DDM-Assessment.json `
    -SourcePolicyId 'demo-passcode' `
    -Template .\samples\demo-template.json `
    -Bindings .\samples\demo-bindings.json `
    -AllowPartial `
    -OutputPath .\Draft
```

This writes `proposed-policy.json` and `migration-manifest.json`. Five omitted source settings are explicitly listed. Without `-AllowPartial`, this example fails because it intentionally maps only two of the source profile's seven settings.

## 4. Prepare a real DDM scaffold

1. In a development Intune tenant, create an **unassigned iOS/iPadOS or macOS Settings Catalog** profile containing only the intended settings from the **Declarative Device Management** category. This is a reviewed schema scaffold, not a migrated source policy.
2. Run live assessment again so `tenant-export.json` contains that profile and the current definitions.
3. Find the scaffold's policy ID and export it:

```powershell
$inventory = Get-Content .\TenantResults\tenant-export.json -Raw |
    ConvertFrom-Json -AsHashtable

$inventory.policies |
    Where-Object { $_.sourceKind -eq 'settingsCatalog' } |
    ForEach-Object { [pscustomobject]@{ Id = $_.id; Name = $_.name } } |
    Format-Table -AutoSize

.\Export-AppleDDMTemplate.ps1 `
    -InventoryFile .\TenantResults\tenant-export.json `
    -PolicyId 'SCAFFOLD-POLICY-GUID' `
    -OutputFile .\ddm-template.json
```

4. Inspect actual instance IDs and native values:

```powershell
Import-Module .\src\AppleDDM.psm1 -Force
$template = Get-Content .\ddm-template.json -Raw | ConvertFrom-Json -AsHashtable
$template.settings | ForEach-Object {
    Get-DDMInstanceLeaves $_.settingInstance
} | ForEach-Object {
    [pscustomobject]@{ DefinitionId = $_.key; NativeValue = $_.value; Path = $_.path }
} | Format-Table -Wrap
```

5. Create `bindings.json`, using the structure in `samples/demo-bindings.json`. Replace every demo ID and choice option with actual values from your export and definitions. Each binding supplies:

| Field | Meaning |
| --- | --- |
| `sourceKey` | Exact key from the source setting in the assessment |
| `targetDefinitionId` | Actual target instance's `settingDefinitionId` |
| `targetPath` | Exact Apple target path reported by the assessment |
| `optionMap` | For choice targets only: proposed values mapped to actual Graph option item IDs |

For boolean choice settings, the option-map keys are `true` and `false`. Do not assume that a suffix such as `_0` means false. Inspect the actual definition's `options` and the scaffold created through Intune.

```powershell
$definition = $inventory.definitions |
    Where-Object { $_.id -eq 'ACTUAL-TARGET-DEFINITION-ID' }
$definition | ConvertTo-Json -Depth 100
```

Choice parents that only enable mapped children may be explicitly reviewed in `structuralDefinitionIds`. Unbound ordinary values are refused. Repeated target IDs and collection conversion are refused in this release.

6. Generate the real draft:

```powershell
.\New-AppleDDMMigrationPolicy.ps1 `
    -Assessment .\TenantResults\iOS-DDM-Assessment.json `
    -SourcePolicyId 'SOURCE-POLICY-GUID' `
    -Template .\ddm-template.json `
    -Bindings .\bindings.json `
    -OutputPath .\RealDraft
```

Use `-AllowPartial` only when deliberately creating a limited draft while retaining the source. No generated manifest ever approves removal of the source policy.

## 5. Optional: create an unassigned profile

The publishing command requires `DeviceManagementConfiguration.ReadWrite.All`, explicit prerequisite review and confirmation. Source tenant IDs must match. It checks the generated JSON hash, policy envelope, live platform definition applicability, bound target paths and choice-option availability before its single creation request. Hashes detect accidental edits; they are not digital signatures.

First preview the requested operation:

```powershell
.\Publish-AppleDDMMigrationPolicy.ps1 `
    -PolicyFile .\RealDraft\proposed-policy.json `
    -ManifestFile .\RealDraft\migration-manifest.json `
    -TenantId 'YOUR-TENANT-GUID' `
    -ReviewedRequirements `
    -WhatIf
```

`-WhatIf` makes no network calls. It is a local preview, not service-side validation.

After reviewing source defaults, OS versions, supervision, enrolment type, Shared iPad exclusions, binding semantics and omitted settings, remove `-WhatIf` to authenticate and create the profile. The command asks for confirmation, creates **one unassigned policy**, and writes `creation-receipt.json`. It never copies assignments.

The API performs final service-side validation. Definition metadata that cannot be verified fails closed. No Intune tenant was available during development, so live authentication, discovery and creation still need a development-tenant acceptance test. A successful POST alone does not prove successful device delivery.

If the creation response is lost, inspect Intune before retrying. Writes are not retried automatically. If the receipt already exists, the command stops to avoid accidental duplicate creation. If you want to delete a generated draft, use its recorded ID in Intune after confirming it remains unassigned; the tool does not automate deletion.

## What the initial catalogue covers

| Workload | Implemented behaviour |
| --- | --- |
| Passcode | Required, length, complex/simple inversion for plist, failed attempts, inactivity, grace period, age, history and alphanumeric mappings; target type/range validation |
| Software update deferral | iOS `CombinedPeriodInDays`, iOS 18+, supervised; requires an enabled legacy delay flag |
| Software update scheduling | Review-required: recurring windows do not establish a target version and a local enforcement deadline |
| Safari | Generic restrictions retained; no fabricated equivalence to extension declarations |
| Restrictions | Selected known restrictions retained; all unknown keys require review |
| Existing DDM | Marked from known declaration identity in definition metadata; not merely from Settings Catalog membership |
| Custom profiles | XML plist extraction without external DTD resolution; binary/signed/opaque payloads require review |

Apple prerequisites are stored independently from Intune capability. A catalogue-level supported declaration does not establish that the exact target setting is exposed in your tenant. That is why generation uses a real reviewed scaffold.

`DDM_DIRECT` means a value-level mapping candidate. It does not mean 100% deployment confidence. User Enrollment can change Settings Catalog delivery, legacy Graph resources can include default false/zero values, and passcode keys can implicitly require a passcode. These all require review before replacement.

## Deliberate limitations

- No full Apple payload taxonomy or universal legacy converter.
- No automatic choice decoding for legacy Settings Catalog IDs. If metadata or value semantics are unclear, the setting stays `REQUIRES_REVIEW`.
- No assignment-resolved device compatibility, group overlap analysis, effective conflict detection or migration-readiness score. Optional device inventory provides platform-wide OS/supervision evidence only.
- No compliance, enrolment, app-configuration, app-protection or app-deployment policy assessment.
- No automatic assignments, source mutation, decommissioning or rollback.
- No automatic enforcement deadline generation from a deferral or recurring schedule.
- No tenant-tested assertion that all Graph schemas are accepted by the service. The `/beta` contract can change.

## Tests

```powershell
.\tests\Run-Tests.ps1
```

Tests cover real PowerShell execution of offline assessment, nested instances, XML parsing, value ranges, false/zero retention, unknown mappings, HTML escaping, CSV safety, partial-generation blocking, explicit choice mapping, hash protection, WhatIf and mocked paginated GET-only discovery. No external testing framework is needed.

## Authoritative references — reviewed 29 September 2026

- [Microsoft Apple configuration reference](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/ref-apple-settings)
- [Microsoft Settings Catalog and User Enrollment delivery](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/)
- [Apple passcode declaration schema](https://github.com/apple/device-management/blob/release/declarative/declarations/configurations/passcode.settings.yaml)
- [Apple software update settings schema](https://github.com/apple/device-management/blob/release/declarative/declarations/configurations/softwareupdate.settings.yaml)
- [Apple specific software update enforcement schema](https://github.com/apple/device-management/blob/release/declarative/declarations/configurations/softwareupdate.enforcement.specific.yaml)
- [Graph macOS legacy configuration properties](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macosgeneraldeviceconfiguration?view=graph-rest-beta)
- [Graph managed-device inventory](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-list?view=graph-rest-1.0)
- [Graph iOS legacy configuration properties](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-iosgeneraldeviceconfiguration?view=graph-rest-beta)
- [Graph setting definition discovery](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfigv2-devicemanagementconfigurationsettingdefinition-list?view=graph-rest-beta)
- [Graph Settings Catalog policy creation](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicy-create?view=graph-rest-beta)
- [Graph choice option definitions](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfigv2-devicemanagementconfigurationoptiondefinition?view=graph-rest-beta)

## Report presentation update — v0.1.1

The HTML report uses a fixed 220-pixel Current column with wrapping for JSON, long URLs and unbroken strings. Other columns expand with the available screen width. The layout targets 1920×1080 and supports wider desktop screens; narrower screens scroll the table horizontally.

Red/amber/green badges and summary cards distinguish unresolved settings, partial/retained settings and DDM identities or migration candidates. Labels remain visible so meaning does not depend on colour. Green is not deployment approval. Suggested next steps are generated from the actual results, including unresolved settings, candidates, retained coverage, update prerequisites and inventory completeness. Scope details can be expanded below the suggestions.

To update an existing assessment without interrogating the tenant again, run:

```powershell
Import-Module .\src\AppleDDM.psm1 -Force
$assessment = Get-Content .\TenantResults\iOS-DDM-Assessment.json -Raw |
    ConvertFrom-Json -AsHashtable
Export-DDMReport -Assessment $assessment -OutputPath .\TenantResults
```

Or re-run the normal live/offline assessment command with the updated package.
