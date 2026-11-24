# Side-by-side secret backends

## Choose deliberately

Run the Azure bootstrap from a fresh elevated PowerShell 7.6.10+ session:

```powershell
& '.\lab\Start Azure Lab.ps1'
```

Before dependency restoration, choose:

- **1 / KeyVault**: use existing Azure Key Vault credentials and managed-identity
  pipelines when public endpoint access is permitted in every environment.
- **2 / Kdbx**: use a portable password-encrypted operator/recovery database and
  native Azure DevOps secret variables/Secure Files, without Key Vault.

Enter keeps the saved `SecretStorage` choice; the default for older configuration
is KeyVault. `-SecretBackend KeyVault` or `-SecretBackend Kdbx` avoids the prompt.
The selector alone is written to public YAML, not KDBX private settings.

The backend is deployment-wide, not an automatic per-environment fallback.
If policy or firewall rules block Key Vault, investigate or explicitly select
KDBX. Neither option weakens Azure Policy or public-access restrictions.
Changing backend starts independent checkpoint history; a new KDBX deployment
identity cannot inherit another database's completed work.

Use a separate Azure DevOps project when provisioning another backend. Existing
pipeline definitions with the same names but a different backend YAML path are
rejected rather than silently redirected. Existing vaults, credentials, and
applications are not migrated or removed by selecting KDBX.

## Code boundaries

- `lab/Secrets/SecretBackend.psm1`: the small shared selector/router.
- `lab/Azure/AzHelpers.psm1`: existing Key Vault implementation and common Azure
  helpers; original Key Vault APIs remain available.
- `lab/Secrets/KeyVault/PublicEndpoint.psm1`: public-only readiness guard.
- `lab/Secrets/Kdbx/`: KDBX dependency restore, operator database, registration,
  protected worker certificate delivery, and native pipeline publishing.
- `pipelines/`: existing Key Vault pipelines.
- `pipelines/Kdbx/`: separate KDBX-delivery pipelines.

Shared VM, agent installation, repository import, and lifecycle scripts call
the neutral router. They do not duplicate the storage implementations.
AutomatedLab remains on its existing path.

Bootstrap verifies imported PowerShell scripts separately from pipeline/build
YAML compatibility checks. Compatibility failures report the missing requirement
before offering a clone refresh; pipeline YAML is not parsed as PowerShell.

## Key Vault mode

Continue configuring the existing public project settings and
`CredentialVaultEnvironment` in `source/Global/ProjectSettings.yml`.
The PAT and worker password stay as placeholders and are securely collected.
`source/Global/Azure.yml` contains tenant domains and workload flags.

The bootstrap selects public-only Key Vault regardless of a legacy private
endpoint setting. `KeyVaultPublicOnly: true` also selects that behavior for
standalone scripts. A private-only vault stops before endpoint discovery.
Public network access does not remove the need for permitted firewall access,
secret-list readiness, role-assignment rights, and workload consent.

Legacy private-endpoint helpers are retained for existing explicitly administered
workflows, not invoked automatically by this selection.

## KDBX mode

```powershell
& '.\lab\Start Azure Lab.ps1' -SecretBackend Kdbx
```

The default database path is:

```text
%LOCALAPPDATA%\Microsoft365DscWorkshop\Secrets\operator.kdbx
```

Select another dedicated external directory with `-SecretStorePath` or the
non-secret `M365DSC_SECRET_STORE` path environment variable. Git checkout paths,
symbolic links/junctions, and directories containing unrelated files are refused.
The directory ACL is restricted to the current Windows user and SYSTEM.

Initialization prompts for a passphrase of at least 16 characters and always
securely prompts for a bootstrap PAT; a PAT in YAML is never used. Available
project/worker settings in `ProjectSettings.yml` are reused, including a configured
VM administrator password. Missing or placeholder values are prompted for.
Prefer keeping passwords out of YAML and entering them at the secure prompt.
These values are saved in encrypted storage, not written back to YAML. Existing
databases are unlocked, never overwritten or populated from Key Vault.
For this mode, leave actual private values out of public project YAML; use
placeholders. Tenant `*.onmicrosoft.com` domains remain public configuration.

Only one writer holds the database lock. KDBX uses Argon2id. Saves verify a
temporary encrypted database before atomic replacement; the previous encrypted
version is retained as `.bak`. Failed saves revert the in-memory record change.

VM provisioning in KDBX mode does not query Key Vault or configure its private
endpoints. A retry reuses any worker VM created before a later step failed.

KDBX applications use deployment-specific names and certificates for Setup,
LCM, and Export. PFX attachments and their passwords are encrypted together.
Export gets read permissions; Setup/LCM get their required update permissions.
Azure Owner is not granted merely to retrieve credentials; subscription Reader
supports connection validation. Tenant administrator consent is still needed.

Workers receive only LCM/Export PFX material through protected Run Command
parameters. Temporary PFX files and credential-bearing command resources are
cleaned up; installed worker keys remain for autonomous DSC.

For manual operations, initialize/unlock the same database first:

```powershell
$env:M365DSC_SECRET_BACKEND = 'Kdbx'
& '.\lab\Secrets\Kdbx\Initialize Operator.ps1'
& '.\lab\Azure\10 Setup App Registrations.ps1'
# Continue the documented Azure scripts in this session.
Close-M365DscSecretStore
```

Native pipeline publishing follows project/pipeline setup. Bootstrap publishes
each selected environment separately; a publication failure stops the
stage and is retried on resume.
The publisher reuses an already loaded Datum module rather than importing another
installed version. If an earlier run loaded multiple Datum versions, restart
PowerShell before resuming; the KDBX database and checkpoints are retained.
Only explicitly
trusted workshop pipeline IDs are authorized to use per-environment metadata,
PFX Secure Files and password variables. Secure Files have a 10 MB size limit.
Add production approvals/checks and restrict artifact retention/access.

```powershell
& '.\lab\Secrets\Kdbx\Publish Pipeline Secrets.ps1' -EnvironmentName Dev,Test
```

Each environment uses the variable group `M365DSC-<alias>-Kdbx` and matching
metadata/Export PFX Secure Files. Runtime tasks receive `BuildEnvironment`,
`M365DSC_METADATA_PATH`, and the Export PFX path/password only where needed.
Delta reports receive a JSON array of authorized metadata paths through
`M365DSC_METADATA_PATHS`. Private agent-pool selection comes from the native
group rather than being written into pipeline YAML.

No runtime KDBX bundle is needed: jobs do not need the operator password.
Azure DevOps job tokens remain preferable for supported pipeline operations;
tenant DSC/export still uses supported certificate authentication.

## Recovery and limits

Close the store before copying the encrypted database and backup. Transfer its
passphrase separately. On another supported machine, restore dependencies,
select the copied database, unlock it, and run registration/worker setup to
recover local certificates and pipeline delivery. Decryption does not depend on
the original Windows account or DPAPI key.

Keep the same database to resume a deployment. Do not create another database
while intending to recover existing application bindings.
Change the database password with a compatible KDBX editor while it is closed,
then verify it opens. Automatic KDBX certificate rotation is not provided:
plan credential replacement and validation explicitly; old recovery records
are not overwritten by `-RotateCredentials`.

Encryption protects stored data, not an unlocked or compromised process.
Avoid transcripts, environment dumps and unredacted exports. MOFs, RSOP and
reports can contain private identifiers: they require restricted artifact
access and are not automatically encrypted by KDBX.

KDBX has no per-secret/subscription usage fees. The separately restored
KeePassNetStandard library is GPL-licensed; retain applicable licenses/notices
and meet redistribution/source obligations if packaging it. The hash-pinned
dependency is restored under ignored `output/Tools/Kdbx`, not installed globally.
Its .NET 10 DataProtection dependencies are isolated from pinned Az assemblies.

Local encryption/recovery and mocked cloud delivery are testable offline.
Live Azure/DevOps provisioning, actual policy behavior, and second-machine
recovery still require validation in your environment.
