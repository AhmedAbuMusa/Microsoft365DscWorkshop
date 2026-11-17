# Getting started with Azure-provisioned lab agents

This guide sets up the workshop using Azure PowerShell and the Bicep template to create the build-agent VMs in Azure. It does not use AutomatedLab. Use it instead of the AutomatedLab preparation and VM-creation steps in [GettingStarted.md](GettingStarted.md).

The VM agents run the workshop pipelines and apply the DSC configuration to their corresponding tenants. Azure resources such as the VMs, managed disks, NAT Gateway, and public IP incur charges while they exist.

## Prerequisites

- An Azure DevOps organization and a project where you can create pipelines, environments, and an agent pool.
- An Azure subscription and tenant for each environment you want to configure. You need sufficient permissions to create app registrations and grant tenant permissions, and to create the Azure resources and role assignments used by the agents.
- A Windows machine with PowerShell 7.6.10 or later and Git. The preparation and bootstrap scripts run from an elevated PowerShell session.
- An Azure DevOps PAT with permissions to create projects and repositories, push code, and manage pipelines, environments, and agent pools.
- The Bicep CLI when creating new VMs. The automated bootstrapper installs it with `winget` if needed.

## Automated bootstrap

`lab/Start Azure Lab.ps1` is parameterless. It reads the project, repository, clone, Git author, PAT, and build-agent settings from `source/Global/ProjectSettings.yml`, and reads tenant environments from `source/Global/Azure.yml`. The bootstrapper imports the public GitHub repository into Azure DevOps, clones it locally, restores dependencies with PSResourceGet, and runs the Azure preparation, app registration, connection test, project configuration, VM creation, and agent setup scripts in order.

The import-and-clone stage can also be run separately with `lab/Azure/05 Import GitHub Repository.ps1`. It reads the same local project settings, imports the GitHub repository into Azure DevOps, and creates the configured local checkout without continuing to tenant or VM setup. Restore the source checkout dependencies first:

```powershell
pwsh -NoLogo -NoProfile -File .\build.ps1 -UsePSResourceGet -ResolveDependency
& '.\lab\Azure\05 Import GitHub Repository.ps1'
```

The bootstrapper prints a numbered phase heading before each major operation. It also prints the full path of each script or build command as it starts, followed by a completion message when that step succeeds. Long Azure DevOps project-creation and GitHub-import waits report elapsed time every 30 seconds. If an operation fails, the terminal reports the active phase; script failures also identify the file that failed.

After a failure, rerun `lab/Start Azure Lab.ps1` to resume automatically: successfully completed stages are skipped and the interrupted stage is retried. The initial dependency restore and local configuration validation run again as preflight. Checkpoint data is stored under the current user's local application data and is bound to the checkout path and non-secret project/tenant settings; it does not contain credentials. Use `-Restart` to discard the saved progress and start the workflow over. A stage interrupted mid-operation is retried from its beginning, so its underlying operation may have partially completed before the failure.

Before running it:

- Review `OrganizationName`, `ProjectName`, `RepositoryName`, `GitHubRepositoryUrl`, `LocalPath`, `GitUserName`, and `GitUserEmail` in `ProjectSettings.yml`. This checkout has defaults for the repository name, sibling clone path, Git identity, and a generated Datum-protected lab password. Set `PersonalAccessToken`, `AgentPoolName`, and the remaining `BuildAgents` values (`UserName`, `AzureLocation`, and `AzureRoleSize`) as needed.
- Configure the tenant IDs, tenant names, subscription IDs, service flags, and identities for each environment in `Azure.yml`.
- Publish the updated bootstrap and Azure scripts on the GitHub repository's default branch before running the bootstrapper. The GitHub-to-Azure-DevOps import is a snapshot: an already completed import is reused, not refreshed. If the Azure DevOps repository was imported before the latest scripts were published, update that repository from the current GitHub version (or configure a fresh project/repository) before running the bootstrapper. Keep tenant and project-specific settings local; the bootstrapper copies the two YAML configuration files from your checkout into a newly cloned Azure DevOps repository.

The script protects an unprotected PAT or VM password in `ProjectSettings.yml` before copying it. Do not publish plaintext credentials. If bootstrap stops because an imported Azure script is missing, refresh the Azure DevOps repository from the current GitHub default branch and use an empty clone path before retrying. Run elevated PowerShell 7 from the workshop checkout:

```powershell
& '.\lab\Start Azure Lab.ps1'
```

Tenant administrator sign-in and consent remain interactive during app registration. The bootstrapper does not queue the DSC push pipeline; review and run tenant-changing pipelines explicitly.

The PAT is read from the protected Datum value in `ProjectSettings.yml` and Git authentication is scoped to the required clone/push operations; credentials are not embedded in the clone URL. The VM password is protected in the file and passed to the VM script as a `SecureString`. App credentials generated by the setup scripts are protected in `Azure.yml`. The scripts may push the protected configuration and pipeline updates to the Azure DevOps repository.

## Manual setup

The following steps remain available when you prefer to run each stage yourself.

### 1. Import and clone the repository

In Azure DevOps, create a project, open **Repos**, select **Import**, and import `https://github.com/dsccommunity/Microsoft365DscWorkshop.git`. Clone the imported repository to your machine, then open a PowerShell session at the repository root.

```powershell
git clone "https://dev.azure.com/ORGANIZATION/PROJECT/_git/REPOSITORY" "C:\path\to\local\repository"
Set-Location "C:\path\to\local\repository"
```

The preparation script expects the repository's `origin` remote to be an Azure DevOps HTTPS URL.

### 2. Prepare the machine for the Azure path

Run the Azure-specific preparation script from an elevated PowerShell session:

```powershell
& '.\lab\Azure\00 Prep.ps1'
```

This installs the pinned `VSTeam` and `Az.Accounts` modules, sets the project name in `source/Global/ProjectSettings.yml`, and configures the Azure PowerShell defaults used by the lab scripts. It does not install AutomatedLab or enable lab-host remoting.

### 3. Restore dependencies and build

Run dependency restoration from a fresh PowerShell 7 process at the repository root, so modules loaded in the setup session do not keep package files locked:

```powershell
.\build.ps1 -UsePSResourceGet -ResolveDependency
```

The initial restore downloads the dependencies in `RequiredModules.psd1` and can take 15–20 minutes. If PSResourceGet repeatedly fails, close other PowerShell sessions that may have loaded modules from `output/RequiredModules`, then retry. ModuleFast is an alternative:

```powershell
.\build.ps1 -UseModuleFast -ResolveDependency
```

After the build succeeds, open a fresh PowerShell session at the repository root and initialize its modules:

```powershell
.\build.ps1 -Tasks init
```

### 4. Configure the tenant and environment

Edit [Azure.yml](../source/Global/Azure.yml). For each environment you intend to use, set `AzTenantId`, `AzTenantName`, and `AzSubscriptionId`. Start with one environment, such as `Dev`, and remove the unused environments and their corresponding folders under `source/BuildAgents`.

The setup scripts populate the application IDs, secrets, and certificate thumbprints. Do not copy real credentials into an example or commit unprotected secrets. See [the existing guide's tenant configuration section](GettingStarted.md#14-set-your-azure-tenant-details) for the example structure and notes about `HasExchangeOnline` and `HasSharePointOnline`.

### 5. Set up application registrations and test access

Create the required applications and the environment credential Key Vault using the Azure-specific script:

```powershell
& '.\lab\Azure\10 Setup App Registrations.ps1'
```

Review the local changes to `source/Global/Azure.yml`; the script does not commit or push them. Then test the configured connections:

```powershell
& '.\lab\Azure\11 Test Connection.ps1'
```

For credential rotation, cleanup behavior, and tenant-service requirements, see [the application-registration section in the existing guide](GettingStarted.md#142-10-setup-app-registrationsps1).

### 6. Configure the Azure DevOps project

Run the project setup script and provide the Azure DevOps organization, a PAT with the permissions needed to manage the project, and the project and agent-pool names:

```powershell
& '.\lab\Azure\20 Configure AzDo Project.ps1'
```

The script creates the agent pool, environments, and workshop pipelines in Azure DevOps.

### 7. Create the Azure build-agent VMs

Install the Bicep CLI if it is not already available:

```powershell
winget install --exact --id Microsoft.Bicep --source winget --accept-source-agreements --accept-package-agreements
```

Review the agent settings in [ProjectSettings.yml](../source/Global/ProjectSettings.yml), then run the Azure-specific VM creation script:

```powershell
& '.\lab\Azure\30 Create Agent VMs.ps1'
```

It creates one VM per configured environment, using the editable [Bicep template](../lab/templates/buildAgent.bicep). The script assigns a user-assigned managed identity and creates the supporting Azure resources. It adopts an existing VM with the expected name instead of creating a duplicate. The default configuration uses a NAT Gateway and public IP for outbound access; these incur recurring charges. A password entered at the secure prompt is used only in memory and is not written to `ProjectSettings.yml`.

### 8. Configure and verify the agents

Use Azure VM Run Command to install and configure the Azure DevOps agent on each VM:

```powershell
& '.\lab\Azure\31 Agent Setup.ps1'
```

Confirm that the agents appear in the configured Azure DevOps agent pool and that each has a `BuildEnvironment` capability matching its environment.

### 9. Run the pipelines

The project setup creates the `M365DSC build`, `M365DSC deltaReport`, `M365DSC export`, `M365DSC push`, `M365DSC reapply`, and `M365DSC test` pipelines. For pipeline permissions, first-run approvals, and pipeline behavior, follow [Running the Pipeline](GettingStarted.md#15-running-the-pipeline).

To start, stop, or remove the Azure agents later, use the Azure-specific scripts under [lab/Azure](../lab/Azure/). Removing agents and their resources can incur data loss; review the cleanup behavior before running a removal script.
