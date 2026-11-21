# Managing workshop credentials

Tenant IDs, subscription IDs, application credentials, certificate material, the Azure DevOps PAT, and the build-agent password are stored in Azure Key Vault. They must not be added to `source/Global/Azure.yml` or `source/Global/ProjectSettings.yml`, even as Datum-encrypted values.

On the first run, `lab/Start Azure Lab.ps1` initializes the Key Vault selected by `CredentialVaultEnvironment`, opens the PAT page for the configured Azure DevOps organization, validates the PAT, and stores it with the build-agent password. To run that step by itself, use:

```powershell
& '.\lab\Azure\04 Setup Project Settings Key Vault.ps1'
```

Later lab scripts retrieve the credentials from Key Vault using the signed-in operator. Azure DevOps build agents use their managed identity for Key Vault access to tenant configuration. Keep only the `OrganizationName`, `CredentialVaultEnvironment`, project defaults, and non-secret settings in the public templates.

If a PAT or application credential was previously committed, replace or rotate it. Removing a value from the current YAML does not remove it from Git history; coordinate history cleanup if the repository was public. Do not copy the ignored local `ProjectSettings.private.yml` or `Azure.private.yml` backups into the repository.
