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

`lab/Start Azure Lab.ps1` asks which secret backend to use on every run, including resumes. Press **Enter** for **Kdbx**, or select **KeyVault** when public endpoint access is permitted for every configured environment. The default is always KDBX, regardless of the previously saved choice. The legacy `-SecretBackend` argument is accepted for compatibility but does not bypass or answer the question. The non-secret selection is saved as `SecretStorage` in `source/Global/ProjectSettings.yml` for standalone scripts. One backend applies to the whole deployment; failures never silently switch backends.

Key Vault mode retains the existing application, credential, and managed-identity pipeline workflow. It signs in to `CredentialVaultEnvironment`, creates or reuses the project vault, validates the securely entered PAT, and stores the PAT and worker password there. The bootstrap now selects public-only networking: disabled or unverified public access stops with guidance to select KDBX explicitly. It does not create a private endpoint, enable public access on a restricted vault, or bypass Azure Policy. Public access still requires permitted firewall rules and RBAC.

KDBX mode keeps private project settings, credentials, environment metadata, and portable PFX certificates in an external encrypted database. It uses separate application-registration/certificate-delivery code and separate native Azure DevOps pipelines. Jobs receive authorized Secure Files and secret variables, never the operator database or its passphrase. See [secret backend setup and recovery](SecretStorage.md).

Both modes import the public GitHub repository into Azure DevOps, clone it locally, restore dependencies, and provision agents. Start from a fresh elevated PowerShell 7 session; loaded Az.Accounts assemblies are rejected before setup. Commit and push the implementation to your configured GitHub default branch before running the import.

```powershell
# Prompt every time; Enter selects KDBX:
& '.\lab\Start Azure Lab.ps1'
# Optional custom KDBX location:
& '.\lab\Start Azure Lab.ps1' -SecretStorePath 'C:\PrivateWorkshop\Secrets\operator.kdbx'
```

The credential bootstrap can also be run separately with `lab/Azure/04 Setup Project Settings Key Vault.ps1`. Run it before the import-and-clone step so the PAT and build-agent password are already in Key Vault. The import-and-clone stage can then be run with `lab/Azure/05 Import GitHub Repository.ps1`; it loads the PAT from Key Vault, imports the GitHub repository into Azure DevOps, and creates the configured local checkout without continuing to tenant or VM setup. Restore the source checkout dependencies first:

If the deterministic Key Vault name is soft-deleted or identifies a vault using legacy access policies, setup does not recover, reuse, or modify that vault. It generates the next deterministic name, creates a new, empty vault, and records the selected name as a tag on the dedicated credentials resource group so later scripts continue to find it. Re-enter or recreate credentials that existed only in the old vault. The setup also grants `Reader` on that resource group to principals that need to resolve the name; this does not grant access to the vault's secrets.

```powershell
pwsh -NoLogo -NoProfile -File .\Resolve-Dependency.ps1 -UsePSResourceGet -WithYAML
& '.\lab\Azure\04 Setup Project Settings Key Vault.ps1'
& '.\lab\Azure\05 Import GitHub Repository.ps1'
```

The bootstrap restores dependencies by running `Resolve-Dependency.ps1` directly in a fresh PowerShell process. This avoids loading the YAML parser through `build.ps1` before the restore. If `PowerShell-Yaml` is already installed in `output/RequiredModules`, the bootstrap reuses it rather than replacing files that another open PowerShell session may have loaded. To refresh it manually, close all sessions using the module and rerun the dependency command with `-WithYAML`.

All 13 bootstrap phases print a numbered heading, an `Intent` describing the expected work, a start timestamp, and a finish timestamp with `Completed`, `Failed`, or `Skipped` status and elapsed seconds. Each phase closes with a `Result` describing its outcome. Durations use a monotonic stopwatch, include checkpoint/dependency work, and are reported even when a phase fails or is skipped on resume. Timestamps include the local UTC offset.

The terminal shows phase summaries, environment milestones, authentication instructions, actionable warnings, and errors. Routine script/build output, Git progress, module-import chatter, and troubleshooting details are written to a per-run UTF-8 log under `%LOCALAPPDATA%\Microsoft365DscWorkshop\AzureLabBootstrap\Logs`; its exact path is printed at startup and completion. The log file is readable only by the current Windows user and SYSTEM. Treat logs as private operational data, do not commit them, and remove old logs manually when no longer needed.

Secure input prompts remain interactive in both the bootstrap and its child PowerShell processes. Prompt responses are not captured in the detailed log; device-login codes in recognized sign-in instructions are omitted from it. Warnings about unapproved module verbs and obsolete TFS support are retained only in the detailed log. Other warnings remain visible. Failed scripts retain their terminating error and do not mark the phase complete.

Environment-specific operations print `[Environment: Dev]`-style context headers with the current operation and tenant domain. Once discovered, tenant ID, subscription ID, and Key Vault name are included. Headers identify environment switches during credential access, application registration, connection tests, VM provisioning, agent setup, and worker lifecycle operations. Initial configuration validation also lists each environment's tenant and enabled workloads. These messages never print PATs, passwords, application secrets, or certificate material.

Interactive Azure sign-in is reused per tenant. Before authenticating, the helper uses the same non-WAM login mode as machine preparation, scoped to the current process, so preparation does not switch authentication modes after the first sign-in. The lab saves named `M365DscWorkshop-<tenant>` user contexts through Az.Accounts' standard current-user context/token cache, so isolated PowerShell processes can reuse the same authenticated session and selected subscription. It validates the cached token and tenant domain before reuse, and does not reuse service-principal contexts for interactive administrator work. Graph and delegated Exchange Online connections use tokens from that Azure session rather than starting separate credential prompts. Lab service disconnects retain the Azure sign-in; calling `Disconnect-M365Dsc` without `-KeepAzureContext` still explicitly signs out. No administrator password or custom token file is created. A revoked/expired session, Conditional Access/MFA challenge, or new consent requirement can still require authentication; an explicitly reported interactive-authentication requirement triggers a fresh sign-in, while unrelated token/network failures stop the operation.

Updates to the lab's named Azure contexts do not require overwrite confirmation. The `-EnvironmentName` array filter remains separate from each scalar environment name used for app registration, logging, and Key Vault metadata loading.

After granting operator access to a credential Key Vault, both project-credential setup and tenant app registration verify secret-list access before proceeding. Azure RBAC changes are not immediately visible to the Key Vault data plane. The readiness check retries authorization failures every ten seconds for up to 61 probes (ten minutes of waits), showing the environment and vault on each retry. Other HTTP failures and explicit firewall/private-connection denials stop immediately. If access still fails, the error preserves Azure's original details and points to the role assignment, deny assignments, and network access for investigation; no additional roles or credentials are granted automatically.

If Azure reports `Public network access is disabled`, waiting or signing in again will not fix it. For this bootstrap, select KDBX explicitly and use its independent deployment workflow. Existing private-vault workflows still require approved private routing/DNS administered separately, as described below. The bootstrap does not enable public access, weaken firewall rules, or bypass policy; Azure's trusted-services option does not automatically admit a local PowerShell session.

### Legacy private endpoint workflow (not selected by the bootstrap)

The helpers below remain available for separately administered legacy setups with `KeyVaultPublicOnly: false` and no `M365DSC_KEYVAULT_PUBLIC_ONLY` process flag. The interactive bootstrap deliberately selects public-only Key Vault or KDBX instead. The following network operations are not performed when either bootstrap option is selected.

The bootstrap can discover networking during the environment's Azure sign-in; no Azure login is needed in the editor session. For a vault with public access disabled, it first reads a previously verified `M365DscPrivateEndpointSubnetId` vault tag, then queries the vault's existing private endpoints for their subnet IDs. If neither exists, it enumerates the active subscription's existing VNet subnets, excluding delegated subnets and reserved gateway/firewall/Bastion/Route Server subnets. It selects a subnet only when exactly one candidate exists. Multiple candidates are listed and require an explicit choice. If no candidate exists, it creates a dedicated `<vault-name>-vnet` in the credentials resource group, with a `private-endpoints` subnet and disabled private-endpoint network policies, then provisions the endpoint/DNS path. A unique or newly created subnet does not guarantee routing: local DNS and TCP connectivity must still pass.

After successful local connectivity validation, the subnet ID is remembered in a vault tag for future runs and credential hydration. Tenant-specific IDs are not written into Git or copied between checkouts. Existing endpoints are reused without changing their private-link connections; their DNS zone groups and links are discovered, missing VNet links are added to the existing zone, and a missing zone group is provisioned. Existing conflicting DNS zones or unapproved connections still require administrator action. Agent setup uses discovered networking too.

Automatic network creation selects the first non-overlapping `/24` starting at `10.41.0.0/24` (up to `10.255.255.0/24`) and places a `/27` endpoint subnet inside it. This avoids existing IPv4 VNet ranges in the active subscription and the worker template's `10.40.0.0/16`; it does **not** check on-premises or other subscriptions' address spaces. The chosen range and network are printed before deployment. Existing VNets are not resized or replaced. Use an explicit, administrator-approved subnet when connecting networks that might overlap; VPN, peering, DNS forwarding, and deployment/endpoint costs remain your responsibility.

An explicit setting takes precedence over discovery. For multiple candidates or a different desired network, configure the existing, reachable endpoint subnet in your **local** `source/Global/ProjectSettings.yml` in both existing checkouts (synchronization preserves each checkout's local settings; do not publish subscription-specific settings):

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

Provisioning verifies that the **actual vault hostname** resolves to an allocated endpoint IP from the local machine and that TCP 443 is reachable before accessing secrets. Creating a DNS link does not create routes: an on-premises machine still needs an approved VPN/ExpressRoute connection and conditional DNS forwarding for `privatelink.vaultcore.azure.net` through an Azure DNS Private Resolver or suitable DNS forwarder. Additional DNS-linked VNets must be routed to the endpoint subnet. No VPN, peering, hosts-file overrides, firewall exceptions, or DNS forwarding servers are created automatically. Only the documented dedicated VNet/subnet address range is selected when no existing subnet is available.

Worker creation/adoption and agent setup also provision an endpoint in an otherwise isolated agent VM VNet, with a separate private DNS zone in the agent resource group. This prevents an isolated worker from resolving an unreachable provisioning-endpoint IP. Workers already in the configured or explicitly DNS-linked VNet reuse its endpoint/DNS path; those VNets must have routing in place. Workers with multiple NICs/subnets require an explicit topology and are rejected rather than guessed. DNS zones remain associated with their VNet, so do not link two zones of the same name to one VNet.

New worker subnets explicitly disable private-endpoint network policies so their deny-inbound worker NSG does not block the vault endpoint. Existing/customer subnets and their security policies are not modified automatically; ensure their policies allow the endpoint traffic before adoption.

Remembering the subnet requires permission to update the vault's tags (`Microsoft.Resources/tags/write`). Network discovery requires read access to the vault's private connections, endpoints, and subscription VNets.

The ARM template runs using the already pinned `Az.Accounts` and `Az.Resources` dependencies. No `Az.Network`, `Az.PrivateDns`, Bicep CLI, or new module versions are required during the early credential bootstrap. Existing module restore installs these prerequisites normally. Private endpoints have Azure costs; resource cleanup remains an explicit administrator action.

Preparation errors are terminating: the bootstrapper will not mark the machine-preparation phase complete or continue to dependency restoration if the preparation script detects a loaded Az.Accounts assembly or another failure.

The imported Azure build initialization runs the dedicated `azureinit` workflow in a separate no-profile PowerShell process. It loads configuration and Azure build settings without reusing loaded YAML/Datum modules or running the shared `init` workflow, which also performs AutomatedLab-specific initialization. Before tenant or DevOps changes, the bootstrap validates that the imported checkout contains the Azure workflow and build-failure reporting, then imports its pinned Az.Compute module. A failed build or module import leaves initialization incomplete and prevents later stages from running.

Before creating or adopting VM resources in each environment, VM provisioning verifies `Microsoft.Compute`, `Microsoft.Network`, and `Microsoft.ManagedIdentity` registration in that environment's subscription. Already registered providers are left unchanged; missing registrations are requested and polled every five seconds for up to 60 probes (about five minutes). Registration already in progress is awaited without another request. Progress and the subscription ID remain visible in the terminal. Permission errors or a registration timeout stop provisioning before VM resources are touched.

Resource-provider registration and feature registration are distinct. During VM template deployment, the script catches `SubscriptionNotRegisteredForFeature`, requests registration of the exact feature named by Azure (for example, `Microsoft.Network/AllowBringYourOwnPublicIpAddress`), and waits for `Registered` for up to 60 probes, five seconds apart. It then refreshes the corresponding provider registration and retries the same deployment once. Already registering or approval-pending features are awaited without duplicate requests. Deployment errors naming an unregistered provider namespace also trigger a provider refresh and one retry. This template requests ordinary public IPs, not bring-your-own public IPs, but Azure can still report that feature as required.

Registration errors with no identifiable feature/provider, authorization failures, and unrelated deployment failures remain terminal. Feature registration may require Microsoft approval: a timeout reports the last state and advises Azure Support rather than provisioning without the feature or waiting indefinitely. After approval, rerun bootstrap. If the retry still fails, inspect the failed Azure deployment operations and contact Azure Support; automatic registration cannot override subscription restrictions.

Managed-identity assignment verifies the active Azure tenant and subscription for each environment before accessing resources. Identity lookup and creation use the existing `Az.Resources` ARM cmdlets instead of the pinned AutoRest managed-identity cmdlets, whose `DefaultProfile` parameter is nonfunctional. The returned identity resource ID must match the selected subscription, resource group, and identity name before assignment. This avoids depending on that module's authentication handling across tenant switches; authorization failures remain terminal.

After a failure, rerun `lab/Start Azure Lab.ps1` to resume automatically. Successful checkpoints are retained even after a fully completed run. A new GitHub commit no longer repeats successful application registration or other cloud provisioning just because code changed.

| Phase | Behavior on resume with the same deployment configuration |
| --- | --- |
| 01 - Source dependencies | Check required installed versions; skip restoration when satisfied (unless `-ForceDependencyRestore`). |
| 02 - Configuration | Always validate settings and unlock the secret store; these are required in each new session. |
| 03 - Credential storage | Skip if successful. |
| 04 - Repository synchronization | Always synchronize, so pending fixes and updates reach the imported checkout. |
| 05 - Import verification | Always run compatibility checks against the synchronized files. |
| 06 - Machine preparation | Skip if successful; repeat after a repository revision change. |
| 07 - Imported dependencies | Skip if successful; recheck after a repository revision change. |
| 08 - Build initialization | Skip if successful; repeat after a repository revision change. Required module imports still occur in each new session. |
| 09 - Tenant application registration | Skip if successful, including after a repository revision change. |
| 10 - Application connection tests | Skip if successful, including after a repository revision change. Later operations still establish their own connections. |
| 11 - Azure DevOps and pipeline secret delivery | Skip if successful, including after a repository revision change. |
| 12 - VM provisioning | Skip if successful, including after a repository revision change. |
| 13 - Agent configuration | Skip if successful, including after a repository revision change. |

If an older checkpoint has no recorded commit, local setup (phases 06-08) is revalidated while successful cloud provisioning remains completed. Checkpoints are completion records, not continuous cloud drift or credential-expiration checks. To apply changed provisioning code to already completed cloud phases, deliberately use `-Restart`; ordinary bug-fix commits still reach failed or pending phases without repeating successful ones.

Checkpoint data is stored under the current user's local application data and is bound to the checkout path and project/environment settings plus the selected backend/deployment identity; it does not contain tenant IDs, subscription IDs, or credentials. A change to these identity settings selects a separate checkpoint. Use `-Restart` to discard saved progress and start over; it does not force package refresh. Use `-ForceDependencyRestore` only when installed dependency packages need to be refreshed. Restarting from scratch may repeat previously completed tenant or DevOps operations. A stage interrupted mid-operation is retried from its beginning, so its underlying operation may have partially completed before the failure. Completion markers already discarded by an earlier bootstrap version cannot be recovered automatically.

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

## Manual Key Vault setup

The following steps describe the retained Key Vault path. For KDBX, initialize/unlock its operator database first and follow [the separate backend instructions](SecretStorage.md#kdbx-mode); common Azure scripts then route to the selected backend. Native pipeline publishing is required after project setup for KDBX.

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

Agent setup validates the environment's active tenant/subscription and reads the assigned identity through `Az.Resources`, avoiding the same AutoRest cross-tenant authentication path as VM provisioning. Resource-list discovery uses the cmdlet's default listing API; after verifying the identity resource ID, a separate resource-ID read uses the managed-identity API to retrieve expanded client/principal properties. Key Vault role assignment and worker `AZURE_CLIENT_ID` configuration use those verified values.

Worker Run Command creation, polling, and cleanup use `Invoke-AzRestMethod` rather than the generated Run Command cmdlets. Every request checks the VM resource ID against the active subscription and uses the VM's full ARM path. Credential values remain protected parameters; asynchronous execution, bounded polling, failure reporting, and cleanup are preserved. `-Restart` only resets provisioning checkpoints; it does not fix cross-tenant token errors and unnecessarily repeats successful phases.

```powershell
& '.\lab\Azure\31 Agent Setup.ps1'
```

Confirm that the agents appear in the configured Azure DevOps agent pool and that each has a `BuildEnvironment` capability matching its environment.

### 9. Run the pipelines

The project setup creates the `M365DSC build`, `M365DSC deltaReport`, `M365DSC export`, `M365DSC push`, `M365DSC reapply`, and `M365DSC test` pipelines. For pipeline permissions, first-run approvals, and pipeline behavior, follow [Running the Pipeline](GettingStarted.md#15-running-the-pipeline).

To start, stop, or remove the Azure agents later, use the Azure-specific scripts under [lab/Azure](../lab/Azure/). `96 Remove Workers.ps1` also unregisters offline Azure DevOps agents whose names match the selected environment's generated VM computer name; it leaves online agents and unrelated pool members untouched. Removing agents and their resources can incur data loss; review the cleanup behavior before running a removal script.
