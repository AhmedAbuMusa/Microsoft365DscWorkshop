# Getting started with Azure-provisioned lab agents

This guide sets up the workshop using Azure PowerShell and the Bicep template to create the build-agent VMs in Azure. It does not use AutomatedLab. Use it instead of the AutomatedLab preparation and VM-creation steps in [GettingStarted.md](GettingStarted.md).

The VM agents run the workshop pipelines and apply the DSC configuration to their corresponding tenants. Azure resources such as the VMs, managed disks, NAT Gateway, and public IP incur charges while they exist.

## Prerequisites

- An Azure DevOps organization and a project where you can create pipelines, environments, and an agent pool.
- An Azure subscription and tenant for each environment you want to configure. You need sufficient permissions to create app registrations and grant tenant permissions, and to create the Azure resources and role assignments used by the agents.
- A Windows machine with PowerShell 7.6.10 or later and Git. The preparation and bootstrap scripts run from a fresh elevated PowerShell session.
- Permission to create a PAT for the Azure DevOps organization with the scopes needed to create projects and repositories, push code, and manage pipelines, environments, and agent pools. The bootstrap opens the PAT page for the configured organization and validates the token before saving it.
- The Bicep CLI when creating new VMs. The automated bootstrapper checks PATH and common per-user install locations before using `winget`, then verifies the CLI version.

## Automated bootstrap

`lab/Start Azure Lab.ps1` is parameterless. It reads non-secret project settings from `source/Global/ProjectSettings.yml`, and reads tenant environments from `source/Global/Azure.yml`. Before contacting Azure DevOps, it signs in to the configured `CredentialVaultEnvironment`, creates or reuses that environment's Key Vault, and opens the PAT management page for `OrganizationName`. Enter the PAT at the secure prompt; the bootstrap validates it against that organization and stores it in Key Vault. The build-agent password is also collected securely and stored in the same vault. Neither credential is written to YAML. The bootstrap then imports the public GitHub repository into Azure DevOps, clones it locally, restores dependencies with PSResourceGet, and runs the Azure preparation, app registration, connection test, project configuration, VM creation, and agent setup scripts in order. Start it from a fresh elevated PowerShell 7 session; it stops before doing setup if Az.Accounts or its assembly is already loaded.

The credential bootstrap can also be run separately with `lab/Azure/04 Setup Project Settings Key Vault.ps1`. Run it before the import-and-clone step so the PAT and build-agent password are already in Key Vault. The import-and-clone stage can then be run with `lab/Azure/05 Import GitHub Repository.ps1`; it loads the PAT from Key Vault, imports the GitHub repository into Azure DevOps, and creates the configured local checkout without continuing to tenant or VM setup. Restore the source checkout dependencies first:

If the deterministic Key Vault name is soft-deleted or identifies a vault using legacy access policies, setup does not recover, reuse, or modify that vault. It generates the next deterministic name, creates a new, empty vault, and records the selected name as a tag on the dedicated credentials resource group so later scripts continue to find it. Re-enter or recreate credentials that existed only in the old vault. The setup also grants `Reader` on that resource group to principals that need to resolve the name; this does not grant access to the vault's secrets.

```powershell
pwsh -NoLogo -NoProfile -File .\Resolve-Dependency.ps1 -UsePSResourceGet -WithYAML
& '.\lab\Azure\04 Setup Project Settings Key Vault.ps1'
& '.\lab\Azure\05 Import GitHub Repository.ps1'
```

The bootstrap restores dependencies by running `Resolve-Dependency.ps1` directly in a fresh PowerShell process. This avoids loading the YAML parser through `build.ps1` before the restore. If `PowerShell-Yaml` is already installed in `output/RequiredModules`, the bootstrap reuses it rather than replacing files that another open PowerShell session may have loaded. To refresh it manually, close all sessions using the module and rerun the dependency command with `-WithYAML`.

The bootstrapper prints a numbered phase heading before each major operation. It also prints the full path of each script or build command as it starts, followed by a completion message when that step succeeds. Long Azure DevOps project-creation and GitHub-import waits report elapsed time every 30 seconds. If an operation fails, the terminal reports the active phase; script failures also identify the file that failed.

Environment-specific operations print `[Environment: Dev]`-style context headers with the current operation and tenant domain. Once discovered, tenant ID, subscription ID, and Key Vault name are included. Headers identify environment switches during credential access, application registration, connection tests, VM provisioning, agent setup, and worker lifecycle operations. Initial configuration validation also lists each environment's tenant and enabled workloads. These messages never print PATs, passwords, application secrets, or certificate material.

Interactive Azure sign-in is reused per tenant. Before authenticating, the helper uses the same non-WAM login mode as machine preparation, scoped to the current process, so preparation does not switch authentication modes after the first sign-in. The lab saves named `M365DscWorkshop-<tenant>` user contexts through Az.Accounts' standard current-user context/token cache, so isolated PowerShell processes can reuse the same authenticated session and selected subscription. It validates the cached token and tenant domain before reuse, and does not reuse service-principal contexts for interactive administrator work. Graph and delegated Exchange Online connections use tokens from that Azure session rather than starting separate credential prompts. Lab service disconnects retain the Azure sign-in; calling `Disconnect-M365Dsc` without `-KeepAzureContext` still explicitly signs out. No administrator password or custom token file is created. A revoked/expired session, Conditional Access/MFA challenge, or new consent requirement can still require authentication; an explicitly reported interactive-authentication requirement triggers a fresh sign-in, while unrelated token/network failures stop the operation.

Updates to the lab's named Azure contexts do not require overwrite confirmation. The `-EnvironmentName` array filter remains separate from each scalar environment name used for app registration, logging, and Key Vault metadata loading.

After granting operator access to a credential Key Vault, both project-credential setup and tenant app registration verify secret-list access before proceeding. Azure RBAC changes are not immediately visible to the Key Vault data plane. The readiness check retries authorization failures every ten seconds for up to 61 probes (ten minutes of waits), showing the environment and vault on each retry. Other HTTP failures and explicit firewall/private-connection denials stop immediately. If access still fails, the error preserves Azure's original details and points to the role assignment, deny assignments, and network access for investigation; no additional roles or credentials are granted automatically.

If Azure reports `Public network access is disabled`, waiting or signing in again will not fix it. Run the provisioning machine with connectivity to the vault's approved private endpoint (for example, inside its connected virtual network or over an approved VPN) and ensure the vault hostname resolves to that endpoint's private IP. Ask the subscription administrator to review Key Vault networking and Azure Policy if needed. The bootstrap does not enable public access, weaken firewall rules, or bypass policy; Azure's trusted-services option does not automatically admit a local PowerShell session.

### Automated Key Vault private endpoints

Configure the existing, reachable endpoint subnet for each private environment in your **local** `source/Global/ProjectSettings.yml` (do not publish subscription-specific settings):

```yaml
KeyVaultNetworking:
  Stage:
    PrivateEndpointSubnetId: /subscriptions/<subscription>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<endpoint-subnet>
    # Optional connected VNets that use Azure-provided DNS:
    DnsVirtualNetworkIds:
      - /subscriptions/<subscription>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<provisioning-vnet>
```

Use real resource IDs, repeat the entry for each environment that needs private connectivity, and leave public-only environments absent to preserve their existing behavior. The subnet and linked VNets must already exist in that environment's subscription. Reserve enough free subnet addresses for the endpoint and ensure subnet delegations/NSGs/route policies allow private endpoints and HTTPS. The endpoint is deployed in the subnet's region, which may differ from the vault's region.

On vault creation **or reuse**, the bootstrap registers `Microsoft.Network` if needed, deploys a stable per-subnet private endpoint for the vault's `vault` service, checks connection approval, and provisions `privatelink.vaultcore.azure.net`, VNet links, and a private DNS zone group (Azure maintains the A record). The deployment is incremental and never deletes existing network resources. It also repairs configured project-credential connectivity before reading the PAT on resume. The operator needs deployment permissions in the vault resource group, subnet join permissions, VNet/DNS link permissions, and permission to approve the vault's private endpoint connection. Pending/rejected connections and policy failures stop explicitly.

Provisioning verifies that the **actual vault hostname** resolves to an allocated endpoint IP from the local machine and that TCP 443 is reachable before accessing secrets. Creating a DNS link does not create routes: an on-premises machine still needs an approved VPN/ExpressRoute connection and conditional DNS forwarding for `privatelink.vaultcore.azure.net` through an Azure DNS Private Resolver or suitable DNS forwarder. Additional DNS-linked VNets must be routed to the endpoint subnet. No VPN, address ranges, peering, hosts-file overrides, firewall exceptions, or DNS servers are invented automatically.

Worker creation/adoption and agent setup also provision an endpoint in an otherwise isolated agent VM VNet, with a separate private DNS zone in the agent resource group. This prevents an isolated worker from resolving an unreachable provisioning-endpoint IP. Workers already in the configured or explicitly DNS-linked VNet reuse its endpoint/DNS path; those VNets must have routing in place. Workers with multiple NICs/subnets require an explicit topology and are rejected rather than guessed. DNS zones remain associated with their VNet, so do not link two zones of the same name to one VNet.

New worker subnets explicitly disable private-endpoint network policies so their deny-inbound worker NSG does not block the vault endpoint. Existing/customer subnets and their security policies are not modified automatically; ensure their policies allow the endpoint traffic before adoption.

The ARM template runs using the already pinned `Az.Accounts` and `Az.Resources` dependencies. No `Az.Network`, `Az.PrivateDns`, Bicep CLI, or new module versions are required during the early credential bootstrap. Existing module restore installs these prerequisites normally. Private endpoints have Azure costs; resource cleanup remains an explicit administrator action.

Preparation errors are terminating: the bootstrapper will not mark the machine-preparation phase complete or continue to dependency restoration if the preparation script detects a loaded Az.Accounts assembly or another failure.

The imported Azure build initialization runs the dedicated `azureinit` workflow in a separate no-profile PowerShell process. It loads configuration and Azure build settings without reusing loaded YAML/Datum modules or running the shared `init` workflow, which also performs AutomatedLab-specific initialization. Before tenant or DevOps changes, the bootstrap validates that the imported checkout contains the Azure workflow and build-failure reporting, then imports its pinned Az.Compute module. A failed build or module import leaves initialization incomplete and prevents later stages from running.

After a failure, rerun `lab/Start Azure Lab.ps1` to resume automatically. Repository synchronization and import verification run on every start, even when previously completed. If the synchronized GitHub commit is unchanged, other completed stages are skipped and the interrupted stage is retried. If the commit changes (or an older checkpoint has no recorded commit), completed downstream stages are invalidated so preparation, dependency restore, build initialization, and subsequent provisioning run using the updated code. Credential-vault setup remains completed. Dependency restore is skipped when every required package version is already present; otherwise it runs before the workflow resumes. Local configuration validation still runs on each start. Checkpoint data is stored under the current user's local application data and is bound to the checkout path and public project/environment settings; it does not contain tenant IDs, subscription IDs, or credentials. Use `-Restart` to discard saved progress and start over; it does not force package refresh. Use `-ForceDependencyRestore` only when installed dependency packages need to be refreshed. Restarting from scratch may repeat previously completed tenant or DevOps operations. A stage interrupted mid-operation is retried from its beginning, so its underlying operation may have partially completed before the failure.

When resuming from an older checkpoint, stages that could have reported preparation or build failures as successes are revalidated and retried. Other completed stages, including tenant and DevOps setup, are preserved.

If the local Azure DevOps checkout is missing the required Azure scripts or has outdated parameters, the bootstrap fetches its tracked upstream branch and validates the latest scripts before asking whether to refresh the checkout. Approving overwrites tracked local changes and commits, but preserves `source/Global/ProjectSettings.yml` and `source/Global/Azure.yml`; untracked files remain. Declining leaves the checkout unchanged.

Before running it:

- Review the non-secret settings in `ProjectSettings.yml`, including `OrganizationName`, `ProjectName`, `RepositoryName`, `GitHubRepositoryUrl`, `LocalPath`, and `CredentialVaultEnvironment`. Set `CredentialVaultEnvironment` to an environment from `Azure.yml`; that environment's Key Vault holds the project PAT and build-agent password. Keep the PAT and password placeholders as-is. Update the agent pool and VM sizing settings as needed.
- Configure the tenant domain and service flags for each environment in `Azure.yml`. Tenant/subscription IDs and application credentials are discovered during sign-in and stored in Key Vault.
- Publish the updated bootstrap and Azure scripts on the GitHub repository's default branch before running the bootstrapper. The initial GitHub-to-Azure-DevOps import is a snapshot; subsequent runs reuse the project/repository and automatically fast-forward that default branch from GitHub into Azure DevOps and the configured local checkout. The import script can also be run separately to synchronize without provisioning. This is provisioning-time synchronization, not a background webhook: committing locally is insufficient, and a GitHub push does not update Azure DevOps until the script runs. Only the default branch is synchronized; other branches and tags are not mirrored or deleted.
- Keep tenant and project-specific settings local. The bootstrapper copies the two YAML configuration files into a new checkout and preserves existing local configuration bytes during updates. Synchronization refuses staged changes, other tracked local edits, local-only commits, and non-fast-forward Azure DevOps updates. Commit or stash conflicting edits before retrying; do not force-push over Azure DevOps changes. Untracked files are retained, and Git stops if an update would overwrite them. The local checkout must be on GitHub's default branch. The Key Vault PAT needs Azure DevOps Code read/write permission and permission to contribute to that branch; branch policies can reject direct synchronization pushes.

The project PAT and build-agent password are stored in Azure Key Vault, not protected or written back to `ProjectSettings.yml`. Run elevated PowerShell 7 from the updated workshop checkout; repository synchronization uses the PAT from Key Vault:

```powershell
& '.\lab\Start Azure Lab.ps1'
```

Tenant administrator sign-in and consent remain interactive during app registration. The bootstrapper does not queue the DSC push pipeline; review and run tenant-changing pipelines explicitly.

The PAT is validated for the configured Azure DevOps organization and stored in Key Vault; Git authentication is scoped to the required clone/push operations, and credentials are not embedded in clone URLs. The build-agent password is retrieved from Key Vault only when needed. Tenant IDs, subscriptions, application credentials, the PAT, and the worker password are not written to the public YAML manifests.

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
pwsh -NoLogo -NoProfile -File .\Resolve-Dependency.ps1 -UsePSResourceGet -WithYAML
```

The initial restore downloads the dependencies in `RequiredModules.psd1` and can take 15–20 minutes. If PSResourceGet repeatedly fails, close other PowerShell sessions that may have loaded modules from `output/RequiredModules`, then retry. ModuleFast is an alternative:

```powershell
.\build.ps1 -UseModuleFast -ResolveDependency
```

After the build succeeds, open a fresh PowerShell session at the repository root and initialize its modules:

```powershell
.\build.ps1 -Tasks azureinit
```

### 4. Configure the tenant and environment

Edit [Azure.yml](../source/Global/Azure.yml). For each environment you intend to use, set `AzTenantName` and the service flags. During setup, sign in to the tenant and select the subscription to associate with that environment. Start with one environment, such as `Dev`, and remove unused environments and their corresponding folders under `source/BuildAgents`.

The bootstrap stores tenant and subscription IDs, application IDs, secrets, and certificate material in Key Vault. Do not add these values to the tracked manifest. See [the tenant configuration section](GettingStarted.md#14-set-your-azure-tenant-details) for the manifest shape and service-flag notes.

### 5. Set up application registrations and test access

Create the required applications and the environment credential Key Vault using the Azure-specific script:

```powershell
& '.\lab\Azure\10 Setup App Registrations.ps1'
```

The script does not write credentials or tenant identifiers to `source/Global/Azure.yml`. Then test the configured connections:

```powershell
& '.\lab\Azure\11 Test Connection.ps1'
```

For credential rotation, cleanup behavior, and tenant-service requirements, see [the application-registration section in the existing guide](GettingStarted.md#142-10-setup-app-registrationsps1).

### 6. Configure the Azure DevOps project

Run the project credential bootstrap first if you have not already stored the PAT and build-agent password in Key Vault. It opens the configured Azure DevOps organization to create a PAT and validates it before storage:

```powershell
& '.\lab\Azure\04 Setup Project Settings Key Vault.ps1'
```

Then configure the Azure DevOps project:

```powershell
& '.\lab\Azure\20 Configure AzDo Project.ps1'
```

The script creates the agent pool, environments, and workshop pipelines in Azure DevOps.

### 7. Create the Azure build-agent VMs

Install the Bicep CLI if it is not already available to your PowerShell session:

```powershell
winget install --exact --id Microsoft.Bicep --source winget --accept-source-agreements --accept-package-agreements
```

The bootstrapper also detects existing installs in `%LOCALAPPDATA%\Programs\Bicep CLI` and `%LOCALAPPDATA%\Microsoft\WinGet\Links`, adding the executable's directory to the current process PATH before checking it. It won't treat Winget's “no available upgrade” response as a failure if the existing CLI is available and passes `bicep --version`.

Review the agent settings in [ProjectSettings.yml](../source/Global/ProjectSettings.yml), then run the Azure-specific VM creation script:

```powershell
& '.\lab\Azure\30 Create Agent VMs.ps1'
```

It creates one VM per configured environment, using the editable [Bicep template](../lab/templates/buildAgent.bicep). The script assigns a user-assigned managed identity and creates the supporting Azure resources. It adopts an existing VM with the expected name instead of creating a duplicate. The default configuration uses a NAT Gateway and public IP for outbound access; these incur recurring charges. The build-agent password is retrieved from Key Vault and is not written to `ProjectSettings.yml`.

### 8. Configure and verify the agents

Use Azure VM Run Command to install and configure the Azure DevOps agent on each VM:

```powershell
& '.\lab\Azure\31 Agent Setup.ps1'
```

Confirm that the agents appear in the configured Azure DevOps agent pool and that each has a `BuildEnvironment` capability matching its environment.

### 9. Run the pipelines

The project setup creates the `M365DSC build`, `M365DSC deltaReport`, `M365DSC export`, `M365DSC push`, `M365DSC reapply`, and `M365DSC test` pipelines. For pipeline permissions, first-run approvals, and pipeline behavior, follow [Running the Pipeline](GettingStarted.md#15-running-the-pipeline).

To start, stop, or remove the Azure agents later, use the Azure-specific scripts under [lab/Azure](../lab/Azure/). `96 Remove Workers.ps1` also unregisters offline Azure DevOps agents whose names match the selected environment's generated VM computer name; it leaves online agents and unrelated pool members untouched. Removing agents and their resources can incur data loss; review the cleanup behavior before running a removal script.
