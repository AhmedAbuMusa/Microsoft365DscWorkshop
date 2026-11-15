# Upstream change register

This register records compatibility changes needed by this repository's pinned
dependencies. Findings are version-specific; verify them against the current
upstream source before proposing a change. Items marked as investigations are
not confirmed defects and should not be changed without reproducing the issue.

## Sampler.DscPipeline

### SDP-1: Filter composite resource discovery

- **Problem:** The pipeline's `CompileRootConfiguration` enumerates DSC resources across the full module path before selecting the composites used by this project. With class-based Microsoft365DSC resources, that imports every composite and repeatedly parses the Microsoft365DSC classes.
- **Evidence:** Only the configurations present in the RSOP are needed for compilation. Looking up composite schema files by name avoids loading unrelated resources.
- **Proposed upstream change:** Discover only the requested composite resources before loading their schemas.
- **Local workaround:** `.build/DscCompileHelpers.ps1`, `source/CompileRootConfiguration.ps1`, and `source/RootConfiguration.ps1`.
- **Removal:** Remove the overrides when the pipeline provides equivalent filtered discovery and the default build remains green.

### SDP-2: Limit resource metadata initialization

- **Problem:** The pipeline initializes metadata for every resource in every module, although the compiled composites use only a small subset.
- **Evidence:** `Initialize-DscResourceMetaInfo` performs expensive class-resource property discovery; the project can derive the needed resources from its used composites.
- **Proposed upstream change:** Allow callers to initialize metadata for an explicit resource/type set, while preserving the existing full-scan behavior by default.
- **Local workaround:** `.build/DscCompileHelpers.ps1`, `.build/DscCompileTasks.ps1`, and `build.yaml`.
- **Removal:** Replace the private metadata seeding with the upstream resource-filtering API and verify the full build.

### SDP-3: Select resource modules without enumerating every resource

- **Problem:** `CompressModulesWithChecksum` uses `Get-DscResourceFromModuleInFolder` to identify resource modules. That enumerates resources and imports composites during packaging.
- **Evidence:** The required module's exported DSC resources and `DscResources` folder structure provide the selection criteria without importing each resource.
- **Proposed upstream change:** Select DSC resource modules from module metadata and folder structure, matching the engine's behavior.
- **Local workaround:** `.build/DscCompileHelpers.ps1` and `.build/DscCompileTasks.ps1`.
- **Removal:** Delete the task override when the upstream task selects the same module set without the full resource enumeration.

### SDP-4: Ensure a single DSC engine is selected

- **Problem:** The build can auto-load the Microsoft365DSC compatibility engine before importing the pinned `PSDesiredStateConfiguration` module. The pipeline later sees two modules with the same name.
- **Evidence:** The `PSDesiredStateConfiguration` and `M365DSC.PSDesiredStateConfiguration` modules both export DSC engine commands. Auto-loading the first matching module on `PSModulePath` can select the compatibility engine.
- **Proposed upstream change:** Make the pipeline's DSC engine selection explicit before resource discovery and require one loaded module with the selected name.
- **Local workaround:** `.build/DscCompileHelpers.ps1`, `.build/DscCompileTasks.ps1`, and `build.yaml`.
- **Removal:** Remove the engine-selection helper when the pipeline explicitly loads and validates the configured DSC engine.

## DscBuildHelpers

### DBH-1: Initialize metadata for selected composite resources

- **Problem:** `Initialize-DscResourceMetaInfo` scans the complete module path, which is slow for class-based Microsoft365DSC and can make DscConfig.M365 tests unnecessarily expensive.
- **Evidence:** The generated composite schemas identify the wrapped resource names and their imported modules. The current helper uses DscBuildHelpers' private metadata functions and variables to seed only the resources used by the build.
- **Proposed upstream change:** Expose supported resource filtering for metadata initialization instead of requiring callers to populate private module state.
- **Local workaround:** `.build/DscCompileHelpers.ps1`, `.build/DscCompileTasks.ps1`, and `build.yaml`.
- **Removal:** Replace the private-state workaround when DscBuildHelpers exposes a supported targeted initialization API.

### DBH-2: Investigate remaining metadata initialization behavior

- **Problem:** A separate DscBuildHelpers investigation was recorded, but the available repository evidence does not establish a reproducible defect or a proposed implementation.
- **Evidence:** The investigation is listed as pending in the project notes; no local workaround or failure case is currently tied to this ID.
- **Proposed upstream change:** Reproduce and document the behavior against the current upstream source before proposing a change.
- **Local workaround:** none; investigation only.
- **Removal:** Close this entry when the investigation is reproduced and either tracked as a confirmed change or ruled out.

### DBH-3: Apply the verified helper correction

- **Problem:** A small DscBuildHelpers correction was identified during upstream comparison, but the current repository evidence does not identify its target function or provide enough detail to restate the change safely.
- **Evidence:** The project notes record a verified diff against upstream `main`; no active local workaround is marked for this ID.
- **Proposed upstream change:** Reconfirm the original diff against the current upstream revision and document the affected behavior before opening a change.
- **Local workaround:** none; the change is not represented by a current code marker.
- **Removal:** Close this entry after the upstream change is merged or the comparison shows it is no longer needed.

### DBH-4: Unwrap nullable CIM property types

- **Problem:** `Write-CimPropertyValue` treats `System.Nullable[System.Boolean]` properties on embedded class-based resources as nested instances. It can emit invalid configuration text such as `Nullable`1 { }`.
- **Evidence:** A scratch build using the Microsoft365DSC 2.x `DefaultUserRolePermissions` embedded property failed to parse the generated block. Unwrapping the nullable type with `[System.Nullable]::GetUnderlyingType()` allowed the generated MOFs to compile.
- **Proposed upstream change:** Unwrap nullable property types before selecting the CIM value-writing behavior.
- **Local workaround:** none; the affected `DefaultUserRolePermissions` settings remain commented out until the composite dependency exposes them.
- **Removal:** No local workaround is active. Re-test when the settings are enabled with a compatible DscConfig.M365 release.

## DscConfig.M365

### DC365-1: Update composites for Microsoft365DSC 2.x properties

- **Problem:** The current composites do not expose all properties in Microsoft365DSC 2.x. In particular, `AADAuthorizationPolicy` replaces three `DefaultUserRoleAllowedTo*` properties with `DefaultUserRolePermissions`; `SPOAccessControlSettings` and `SPOTenantSettings` no longer expose `Ensure`.
- **Evidence:** Comparing the shipped composites with Microsoft365DSC 2.x schemas found removed and added properties. The three authorization settings are retained as comments until the composite is updated.
- **Proposed upstream change:** Regenerate and publish composites against the supported Microsoft365DSC 2.x schema, preserving compatible configuration behavior where possible.
- **Local workaround:** `source/1-AllTenantsConfig/AzureAd/cAADAuthorizationPolicy.yml`, `source/1-AllTenantsConfig/SharePoint/cSPOAccessControlSettings.yml`, and `source/1-AllTenantsConfig/SharePoint/cSPOTenantSettings.yml`.
- **Removal:** Restore the commented settings and remove compatibility comments after consuming a regenerated release and verifying the configuration/MOF output.

### DC365-2: Investigate DscConfig.M365 repository metadata

- **Problem:** The published package metadata and the upstream source repository identity do not agree.
- **Evidence:** The project notes identify `raandree/DscConfig.M365` as the source, while the package manifest names `dsccommunity/DscConfig.M365`; the latter source URL was reported as unavailable during investigation.
- **Proposed upstream change:** Confirm the canonical repository and correct the package metadata and release links if the mismatch remains.
- **Local workaround:** none; investigation only.
- **Removal:** Close after the canonical repository and package metadata are verified.

### DC365-3: Investigate composite generation against Microsoft365DSC 2.x

- **Problem:** The available DscConfig.M365 source and generated release were found to target an older Microsoft365DSC schema, and regeneration against 2.x was not completed.
- **Evidence:** The project notes record that the source `main` targeted Microsoft365DSC 1.26.819.1 while the tested 2.x release had substantial composite drift. A generator run was stopped before completion.
- **Proposed upstream change:** Reproduce generation with bounded output and current parameters, then update the generator and publish composites only after validating the complete resource set.
- **Local workaround:** none; the active configuration adjustments are tracked under DC365-1.
- **Removal:** Close after a complete reproducible generation and schema/configuration validation.

## Microsoft365DSC engine

### M365DSC-1: Preserve omitted AADGroupsSettings values

- **Problem:** `AADGroupsSettings` parses optional boolean values without checking for missing directory-setting entries and calls `.ToString()` on nullable configuration values. It also discards the result when creating a missing `Group.Unified` policy.
- **Evidence:** The pinned `Microsoft365DSC` class implementation can fail when `EnableMIPLabels` or another optional value is omitted, and the same null-unsafe branches are present in current upstream source.
- **Proposed upstream change:** Treat omitted optional properties as unmanaged, tolerate missing nullable values, and retain the object returned by policy creation.
- **Local workaround:** `pipelines/scripts/PatchMicrosoft365DscAADGroupsSettings.ps1` and `.build/DscConfigurationTasks.ps1`.
- **Removal:** Remove the patch after an upstream release handles omitted values without changing existing tenant policy, then verify both existing-policy and missing-policy deployments.

### M365PSDSC-1: Avoid a competing DSC engine module

- **Problem:** Microsoft365DSC 2.x brings `M365DSC.PSDesiredStateConfiguration`, which registers a compatibility module also named `PSDesiredStateConfiguration`. Loading it before the pinned DSC engine can leave two same-named modules in the session.
- **Evidence:** The build's module path can auto-load the compatibility engine first; a later import of the pinned engine then produces duplicate module results and breaks pipeline code that expects one module.
- **Proposed upstream change:** Provide a supported way for consumers to select one DSC engine, or prevent the compatibility engine from registering a competing module name when it is not required.
- **Local workaround:** `.build/DscCompileHelpers.ps1`, `.build/DscCompileTasks.ps1`, and `build.yaml`.
- **Removal:** Remove the explicit engine-selection helper once the engine and pipeline no longer load competing same-named modules.

### M365PSDSC-2: Investigate class-resource compilation performance

- **Problem:** Repeated imports of composites containing `Import-DscResource -ModuleName Microsoft365DSC` repeatedly parse the class-based resource definitions.
- **Evidence:** Measurements in the project notes found that each import reparses the class files; the engine's fast host does not support composite resources.
- **Proposed upstream change:** Investigate caching or another supported compilation path that avoids repeated parsing while retaining composite-resource support.
- **Local workaround:** none; the active compile-time workarounds are tracked under SDP-1, SDP-2, and SDP-3.
- **Removal:** Close when an upstream-supported path is available and its output is equivalent in a full build.

### M365PSDSC-3: Investigate generated schema compatibility

- **Problem:** Compatibility between Microsoft365DSC 2.x class schemas and composites generated by DscConfig.M365 has not been fully established.
- **Evidence:** The project notes record schema drift between the tested engine and the available composite release; resource-level differences are tracked separately under DC365-1.
- **Proposed upstream change:** Confirm the supported schema-generation contract and publish compatibility guidance or tests for generated composites.
- **Local workaround:** none; no engine-specific code workaround is currently marked.
- **Removal:** Close after the supported contract is documented and validated against the composite release.
