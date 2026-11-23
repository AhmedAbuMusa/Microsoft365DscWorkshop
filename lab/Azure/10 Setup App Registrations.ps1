[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName,

    [Parameter()]
    [switch]$RotateCredentials
)

$ErrorActionPreference = 'Stop'
$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules -ErrorAction Stop).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $requiredModulesPath
}

Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml -ErrorAction Stop
if ((Get-M365DscSecretBackend -Datum $datum) -eq 'Kdbx')
{
    if ($RotateCredentials) { throw 'KDBX credential rotation requires a separate planned credential replacement; existing recovery records are not overwritten.' }
    & "$PSScriptRoot\..\Secrets\Kdbx\Register Applications.ps1" -EnvironmentName $EnvironmentName
    return
}
$environments = @($datum.Global.Azure.Environments.Keys)
if ($EnvironmentName)
{
    $unknownEnvironments = @($EnvironmentName | Where-Object { $_ -notin $environments })
    if ($unknownEnvironments)
    {
        throw "Unknown environment(s): $($unknownEnvironments -join ', ')."
    }
    $environments = @($environments | Where-Object { $_ -in $EnvironmentName })
}

if (-not $environments)
{
    throw "No environments are defined in 'source/Global/Azure.yml'."
}

$identityDefinitions = @(
    @{
        Name             = 'M365DscSetupApplication'
        CredentialType   = 'secret'
        AddGlobalAdmin   = $true
    }
    @{
        Name           = 'M365DscLcmApplication'
        CredentialType = 'certificate'
    }
    @{
        Name           = 'M365DscExportApplication'
        CredentialType = 'certificate'
    }
)

foreach ($envName in $environments)
{
    $environment = $datum.Global.Azure.Environments[$envName]
    if ([string]::IsNullOrWhiteSpace([string]$environment.AzTenantName))
    {
        $environment.AzTenantName = Read-Host -Prompt "Tenant domain for environment '$envName'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$environment.AzTenantName))
    {
        throw "A tenant domain is required for environment '$envName'."
    }

    Write-M365DscEnvironmentContext -EnvironmentName $envName -TenantName $environment.AzTenantName -Operation 'Signing in to register tenant applications'
    $context = Connect-M365DscEnvironmentContext -TenantName $environment.AzTenantName
    $tenantId = [string]$context.Tenant.Id
    $subscriptionId = [string]$context.Subscription.Id

    $skipExchangeOnline = $environment.HasExchangeOnline -eq $false
    $connectionParameters = @{
        TenantId         = $tenantId
        TenantName       = $environment.AzTenantName
        SubscriptionId   = $subscriptionId
        SkipExchangeOnline = $skipExchangeOnline
    }
    Connect-M365Dsc @connectionParameters -ErrorAction Stop
    if (-not (Test-M365DscConnection `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -SkipExchangeOnline:$skipExchangeOnline))
    {
        throw "The interactive connection does not match environment '$envName'."
    }

    $networkParameters = Get-M365DscKeyVaultNetworkParameters -Datum $datum -EnvironmentName $envName
    $vault = Initialize-M365DscKeyVault `
        -ProjectName $datum.Global.ProjectSettings.ProjectName `
        -EnvironmentName $envName `
        -TenantId $tenantId `
        -SubscriptionId $subscriptionId `
        -Location $datum.Global.ProjectSettings.BuildAgents.AzureLocation `
        @networkParameters `
        -ErrorAction Stop
    if ($null -eq $vault)
    {
        throw "Failed to initialize the credential Key Vault for environment '$envName'."
    }

    Write-M365DscEnvironmentContext -EnvironmentName $envName -TenantName $environment.AzTenantName `
        -TenantId $tenantId -SubscriptionId $subscriptionId -KeyVaultName $vault.VaultName `
        -Operation 'Configuring tenant applications and credential storage'

    $operatorAccount = (Get-MgContext -ErrorAction Stop).Account
    if ([string]::IsNullOrWhiteSpace([string]$operatorAccount))
    {
        throw 'The interactive Microsoft Graph session did not identify the signed-in operator.'
    }
    $operator = Get-MgUser -UserId $operatorAccount -ErrorAction Stop
    if (-not $operator.Id)
    {
        throw 'Could not resolve the signed-in operator to an Entra user object.'
    }
    Ensure-M365DscKeyVaultRoleAssignment `
        -VaultResourceId $vault.ResourceId `
        -PrincipalId $operator.Id `
        -RoleDefinitionName 'Key Vault Secrets Officer'

    Wait-M365DscKeyVaultAccess -VaultName $vault.VaultName -EnvironmentName $envName -ErrorAction Stop

    foreach ($identityDefinition in $identityDefinitions)
    {
        $identityName = $identityDefinition.Name
        Write-Host "[Environment: $envName] Reconciling application '$identityName' in tenant '$($environment.AzTenantName)'." -ForegroundColor Magenta

        $identity = New-M365DscIdentity -Name $identityName -PassThru

        if (-not $identity -or -not $identity.AppId)
        {
            throw "Could not create or uniquely resolve application '$identityName' in environment '$envName'."
        }

        if ($identityDefinition.AddGlobalAdmin)
        {
            Add-M365DscIdentityPermission -Identity $identity -AccessType Update -AddToGlobalAdminRole
        }
        else
        {
            Add-M365DscIdentityPermission -Identity $identity -AccessType Update
        }

        $applicationIdSecretName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'application-id'
        Set-M365DscKeyVaultSecret `
            -VaultName $vault.VaultName `
            -Name $applicationIdSecretName `
            -SecretValue (ConvertTo-M365DscSecureString -Value $identity.AppId) `
            -ContentType 'text/plain' `
            -Overwrite

        if ($identityDefinition.CredentialType -eq 'secret')
        {
            $secretName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType secret
            $secretExists = Test-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $secretName
            if ($RotateCredentials -or -not $secretExists)
            {
                $identity = New-M365DscIdentity -Name $identityName -GenereateAppSecret -PassThru
                if (-not $identity.Secret)
                {
                    throw "Failed to generate the application secret for '$identityName'."
                }
                Set-M365DscKeyVaultSecret `
                    -VaultName $vault.VaultName `
                    -Name $secretName `
                    -SecretValue (ConvertTo-M365DscSecureString -Value $identity.Secret) `
                    -ContentType 'text/plain' `
                    -Overwrite:$RotateCredentials
            }
        }
        else
        {
            $pfxName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType pfx
            $pfxPasswordName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType pfx-password
            $pfxExists = Test-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $pfxName
            $pfxPasswordExists = Test-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $pfxPasswordName
            if (-not $RotateCredentials -and $pfxExists -ne $pfxPasswordExists)
            {
                throw "Key Vault contains only part of the certificate material for '$identityName'. Review the vault and rerun with -RotateCredentials to replace the certificate pair."
            }
            if ($RotateCredentials -or -not ($pfxExists -and $pfxPasswordExists))
            {
                $identity = New-M365DscIdentity -Name $identityName -GenereateCertificate -PassThru
                if (-not $identity.CertificateThumbprint)
                {
                    throw "Failed to generate the certificate for '$identityName'."
                }

                $certificate = Get-Item -Path "Cert:\LocalMachine\My\$($identity.CertificateThumbprint)" -ErrorAction Stop
                if (-not $certificate.HasPrivateKey)
                {
                    throw "Generated certificate '$($identity.CertificateThumbprint)' for '$identityName' has no private key."
                }
                $pfxPassword = [Guid]::NewGuid().ToString('N')
                $pfxBase64 = [Convert]::ToBase64String($certificate.Export('Pfx', $pfxPassword))
                Set-M365DscKeyVaultSecret `
                    -VaultName $vault.VaultName `
                    -Name $pfxName `
                    -SecretValue (ConvertTo-M365DscSecureString -Value $pfxBase64) `
                    -ContentType 'application/x-pkcs12' `
                    -Overwrite:$RotateCredentials
                Set-M365DscKeyVaultSecret `
                    -VaultName $vault.VaultName `
                    -Name $pfxPasswordName `
                    -SecretValue (ConvertTo-M365DscSecureString -Value $pfxPassword) `
                    -ContentType 'text/plain' `
                    -Overwrite:$RotateCredentials
            }
            else
            {
                $pfxBase64 = ConvertTo-M365DscPlainText -Value (Get-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $pfxName)
                $pfxPassword = ConvertTo-M365DscPlainText -Value (Get-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $pfxPasswordName)
                $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                    [Convert]::FromBase64String($pfxBase64),
                    $pfxPassword,
                    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
                )
                if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date))
                {
                    throw "The stored certificate for '$identityName' is expired or has no private key. Rerun with -RotateCredentials."
                }
                $identity.CertificateThumbprint = $certificate.Thumbprint
            }

            $thumbprintSecretName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'certificate-thumbprint'
            Set-M365DscKeyVaultSecret `
                -VaultName $vault.VaultName `
                -Name $thumbprintSecretName `
                -SecretValue (ConvertTo-M365DscSecureString -Value $identity.CertificateThumbprint) `
                -ContentType 'text/plain' `
                -Overwrite
        }
    }

    $metadataIdentities = foreach ($identityDefinition in $identityDefinitions)
    {
        $identityName = $identityDefinition.Name
        $applicationId = ConvertTo-M365DscPlainText -Value (
            Get-M365DscKeyVaultSecret `
                -VaultName $vault.VaultName `
                -Name (Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'application-id')
        )
        $metadataIdentity = [ordered]@{
            Name          = $identityName
            ApplicationId = $applicationId
        }
        if ($identityDefinition.CredentialType -eq 'certificate')
        {
            $metadataIdentity.CertificateThumbprint = ConvertTo-M365DscPlainText -Value (
                Get-M365DscKeyVaultSecret `
                    -VaultName $vault.VaultName `
                    -Name (Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'certificate-thumbprint')
            )
        }
        [pscustomobject]$metadataIdentity
    }

    Set-M365DscEnvironmentMetadata `
        -VaultName $vault.VaultName `
        -TenantId $tenantId `
        -TenantName $environment.AzTenantName `
        -SubscriptionId $subscriptionId `
        -Identities $metadataIdentities

    Write-Host "Key Vault '$($vault.VaultName)' is configured for environment '$envName'. Tenant IDs, subscription IDs, application IDs, and credentials were not written to Azure.yml." -ForegroundColor Green
    Disconnect-M365Dsc -KeepAzureContext
}

Write-Host 'Finished bootstrapping tenant application identities and Key Vault metadata.' -ForegroundColor Green
