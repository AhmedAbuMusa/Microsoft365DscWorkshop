# Pre-commit summary

This is a snapshot of the current working tree for review before committing. At the time it was prepared, no changes were staged; the working tree contains both tracked edits and untracked files. Run `git status --short` again before committing.

## Change overview

- **Build and dependency management:** Pin module versions more consistently, update Microsoft365DSC and related Graph/DSC dependencies, add Azure Compute, and make module initialization fail explicitly when pinned versions cannot be loaded. Dependency restoration adds longer timeouts, retry handling for transient PSResourceGet failures, and fallback from ModuleFast timeouts. The build also disables HTTP/3 for ModuleFast and stops if dependency resolution fails.
- **DSC compilation:** Add compile helpers and task overrides to reduce repeated discovery and loading of class-based DSC resources, select the DSC engine explicitly, and add compile preparation to the workflow. A deployment-validation task checks generated MOFs against target nodes and waits for active LCM operations to finish.
- **Azure DevOps pipelines:** Replace hard-coded environment lists with an environment-matrix stage driven by pipeline parameters. Update build, export, delta-report, initialization, push, reapply, and test templates to use the matrix and environment-specific artifacts. Add runtime preflight, AAD groups compatibility patching, and WinRM diagnostics tooling.
- **Microsoft 365 configuration and export:** Update the export resource list and add guidance for managing it and the Microsoft365DSC version. Comment out configuration properties that are incompatible with the current Microsoft365DSC 2.x composites, with references to the upstream compatibility register.
- **Lab provisioning and scripts:** Move the existing scripts and helper modules from `lab/` into `lab/AutomatedLab/`; add Azure-specific provisioning, lifecycle, pipeline-management, and troubleshooting scripts under `lab/Azure/`, plus a Bicep build-agent template and Azure bootstrap script. Add distinct Azure copies of the connection-test, project-setup, and helper scripts/modules. Update script imports, relative paths, and documentation links for the two layouts. The bootstrapper prints numbered phases, active file paths, step completions, and elapsed time while waiting for Azure DevOps operations; it also validates imported files and explains when an Azure DevOps repository snapshot is missing the current Azure scripts.
- **Tests and repository documentation:** Expand Azure helper tests and add tests for DSC compilation, dependency pins, and upstream-workaround tracking. Add Azure setup, export, and upstream-compatibility guides, a work report, Copilot instructions, and updated project memory-bank notes.
- **Configuration and local settings:** Update tenant, project, build-agent, and service configuration; update Summit test-account script paths; add a policy-audit CSV and `testResults.xml`.

## Review before publishing

- `source/Global/Azure.yml` and `source/Global/ProjectSettings.yml` now contain environment-specific values rather than placeholders. They include tenant/application identifiers, protected credential values, and local identity/path settings; `ProjectSettings.yml` also contains a plaintext build-agent password. Remove or replace anything that should not be published, and rotate any credentials that may have been exposed. No credential values are reproduced in this summary.
- `.vscode/settings.json` enables Autopilot and sets approvals to `allowAll`. Confirm that this workspace behavior should be shared in the repository.
- Review `.work/reporting/AzurePolicyAudit-20261105-233035.csv` and `testResults.xml`; both are currently untracked generated files and may not belong in the commit.

## Validation noted during this session

PowerShell parser checks passed for the lab scripts, updated guide links and script paths resolved, and `git diff --check` passed for the files changed in the lab-path updates. A full build and full test suite were not run as part of preparing this summary.
