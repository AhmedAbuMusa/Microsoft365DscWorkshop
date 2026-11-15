# Copilot instructions

## Project model

- This is a Windows PowerShell DSC control repository, not a standalone service. YAML desired state under `source/` is resolved by Datum, compiled by the Sampler/Invoke-Build workflows into MOF artifacts, and applied to Microsoft 365 tenants by Azure DevOps agents using Microsoft365DSC.
- `source/Datum.yml` defines the configuration stores and precedence: node/build-agent settings, environment-specific settings in `2-EnvironmentConfig`, shared tenant settings in `1-AllTenantsConfig`, then LCM defaults in `0-DscConfiguration`. `source/Global/` holds project and Azure environment settings.
- Each service area's `Configurations.yml` selects which DSC configurations/resources are included. Related resource YAML files provide their properties and `Items`. Datum's `lookup_options` in `source/Datum.yml` controls how those values merge; preserve the declared merge behavior, including the keyed merges for group `MailNickname` and conditional-access policy `DisplayName`.
- `HasExchangeOnline` and `HasSharePointOnline` in `source/Global/Azure.yml` control whether those service layers resolve to their normal configuration or the corresponding disabled layer.
- `azure-pipelines.yml` is the Azure DevOps pipeline entry point; pipeline templates live in `pipelines/`. The `lab/` scripts provision the Azure DevOps project, app registrations, and build-agent VMs.

## Build and test

Run commands from the repository root in PowerShell:

```powershell
# Restore dependencies without running build tasks
.\build.ps1 -ResolveDependency -Tasks noop

# Default workflow: build and pack DSC artifacts
.\build.ps1

# Validate configuration data and compile the Datum RSOP
.\build.ps1 -Tasks rsop

# Run one Pester test file (after dependencies are restored)
Invoke-Pester -Path .\tests\ConfigData\AzHelpers.Tests.ps1

# Lint PowerShell files with the repository's DSC-specific analyzer settings
Invoke-ScriptAnalyzer -Path .\lab -Settings .\.vscode\analyzersettings.psd1
```

The `build` and `rsop` workflows require PowerShell 7 or later. The `startConfiguration` and `testConfiguration` workflows require Windows PowerShell 5.1. The default build runs configuration-data and DSC-resource checks; packing generates artifacts and runs acceptance checks. Restore dependencies before linting so PSScriptAnalyzer and the custom DSC rules in `.vscode/analyzersettings.psd1` are available. See [tests/README.md](../tests/README.md) for the role of the control-repository tests and [docs/GettingStarted.md](../docs/GettingStarted.md) for setup details.

## Repository conventions

- Treat YAML in `source/` as the desired-state source of truth. Resource property names and shapes must match the pinned Microsoft365DSC resource schema; use the build to catch schema mismatches.
- Keep Microsoft365DSC and its generated dependency pins in `RequiredModules.psd1` consistent; follow the update procedure documented in that manifest rather than changing transitive pins independently.
- Keep protected values in the repository's Datum ProtectedData format; do not replace protected tokens with plaintext secrets.
