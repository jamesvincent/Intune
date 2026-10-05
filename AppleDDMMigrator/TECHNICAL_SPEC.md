# Technical specification — v0.2.0

## Outcome

An iOS/iPadOS or macOS consultant/admin can run read-only discovery, re-run the resulting inventory offline, inspect setting-level migration candidates and generate a traceable unassigned policy draft. Optional live creation is isolated from analysis.

## Components

| Component | Responsibility |
| --- | --- |
| `Invoke-AppleDDMMigrationAssessment.ps1` | Live/offline entry point and report orchestration |
| `src/AppleDDM.psm1` | Graph reads, pagination, normalization, classification and reports |
| `mappings/ios.json` / `mappings/macos.json` | Versioned setting-specific source aliases, target paths, transformations, Apple prerequisites and evidence |
| `Export-AppleDDMTemplate.ps1` | Extract native Settings Catalog structure from an inventory |
| `New-AppleDDMMigrationPolicy.ps1` | Apply reviewed source/target bindings; emit JSON and provenance manifest |
| `Publish-AppleDDMMigrationPolicy.ps1` | Confirm and create a single unassigned profile with live definition checks |
| `tests/Run-Tests.ps1` | Executable functional and mocked-boundary checks |

## Input contract

Inventory `schemaVersion: 1` has `policies`, optional `definitions`, `tenantId`, `collectedAt` and `complete`. Every policy has a unique `id`, `sourceKind` (`legacy` or `settingsCatalog`), native Graph fields and optional `assignments`. Catalog profiles include their complete `settings` relationship. Definitions retain native `id`, `baseUri`, `offsetUri`, applicability and options. The tool's live collector emits this contract.

Existing native backup files require an adapter to this envelope. The tool does not pretend an arbitrary JSON backup matches this contract.

## Normalization and classification

Legacy derived-resource properties are represented as source keys and values; metadata is excluded. Settings Catalog and custom payloads preserve configured false/zero. Legacy default-valued properties are excluded unless a reviewed configuredSettingKeys list or settingsProvenance=explicit confirms configured intent. Legacy coverage percentages are indicative. Nested legacy objects are retained as one review item rather than misinterpreted. XML custom payload keys are namespaced by Apple payload type. Settings Catalog groups and choice children are traversed recursively, retaining IDs and paths.

Canonical Apple declaration identity establishes existing DDM for the supported family list. Unsupported or opaque metadata never establishes DDM. Catalogue rules match exact source keys; transforms and type/range checks gate proposed values. A false or absent update-deferral enable flag blocks the deferral candidate. Known retained Settings Catalog settings are labelled `MODERN_MDM_RETAIN`.

Classification vocabulary supports `DDM_DIRECT`, `DDM_SEMANTIC`, `DDM_PARTIAL`, `MODERN_MDM_RETAIN`, `LEGACY_RETAIN`, `NOT_SUPPORTED`, `DEPRECATED`, `REQUIRES_REVIEW` and `ALREADY_DDM`. Not every state has a rule in this initial catalogue.

## Generation contract

Generation needs the assessment, source policy ID, native target scaffold and explicit reviewed bindings. Each binding matches exactly one candidate source and one target ID, and its target path must equal the assessed target path. Choice mappings are explicit. Unbound ordinary scaffold values, repeated IDs and unsupported collections fail. Explicit structural choice parents may remain to enable mapped children.

No unmapped source item disappears from the manifest. Partial generation is opt-in. Read-only IDs and template instance references are removed. Assignments are omitted. Source-replacement approval remains false even for full mapping coverage.

## Write boundary

The publisher requires explicit prerequisite review, same-tenant provenance, an unchanged generated policy and an allowlisted policy envelope. `ShouldProcess` runs before authentication; `-WhatIf` is offline. It checks live platform applicability, canonical DDM path evidence and choice availability. One POST creates the new policy; no writes are retried, and no source/assignment write methods exist. A receipt preserves the created ID. Intune performs final request validation.

## Deferred work

1. Development-tenant acceptance: authentication, endpoint responses, schema binding and successful unassigned creation.
2. Captured real-definition fixtures, per-setting enrolment/applicability validation and Graph choice decoding.
3. Wider setting catalogue and strict intent-aware conflict analysis with assignment filters/exclusions and group overlap.
4. Assignment-resolved device compatibility and pilot cohort recommendations.
5. iOS enforcement policy redesign workflow, then macOS reuse.

Acceptance for this build is offline execution and mocked discovery, not a production migration certification.

## macOS extension and compatibility contract

Live discovery accepts iOS, macOS or All and annotates every profile with its platform. Offline selection uses explicit platform or native Graph metadata; mixed-platform input with unknown platform is refused. Platform is not counted as a legacy setting. Each row uses only its platform catalogue and carries minimumOS, platform, targetDefinitionIds, Intune availability evidence and compatibilityEvidence.

Optional managed-device inventory adds a separate read scope. All compatibility counts are platform-wide and check minimum OS plus supervision where required. Invalid/missing OS versions or supervision evidence produce Unknown. Results do not resolve assignments, enrolment applicability or scope; ChecksPassed is never source removal approval.

Known macOS MDM payload families are retained. Password settings are value-mapped with separate OS minima. Explicit update deferrals retain major/minor/system intent; generic delay policies remain review-required. Generation and publishing accept a matching macOS scaffold while preserving the existing no-assignment/no-source-mutation boundary.

The report lists profile DDM coverage (candidates plus already DDM / assessed settings), with Not assessed for zero extracted settings. Summary/status/profile buttons combine with search to filter only setting rows. Empty profiles create no artificial setting rows.
