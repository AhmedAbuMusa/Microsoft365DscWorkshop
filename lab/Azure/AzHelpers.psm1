Import-Module -Name $PSScriptRoot\CertHelpers.psm1 -Force

function Write-M365DscEnvironmentContext
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$SubscriptionId,

        [Parameter()]
        [string]$KeyVaultName
    )

    $fields = [ordered]@{
        Tenant            = $TenantName
        'Tenant ID'       = $TenantId
        'Subscription ID' = $SubscriptionId
        'Key Vault'       = $KeyVaultName
    }
    $details = foreach ($field in $fields.GetEnumerator())
    {
        if (-not [string]::IsNullOrWhiteSpace($field.Value))
        {
            '{0}: {1}' -f $field.Key, $field.Value
        }
    }
    Write-Host "[Environment: $EnvironmentName] $Operation | $($details -join ' | ')" -ForegroundColor Cyan
}

function Get-M365DscAgentResourceGroupName
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName
    )

    return "$ProjectName-$EnvironmentName-rg"
}

function Get-M365DscAgentVmName
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName
    )

    return "Lcm$ProjectName$EnvironmentName"
}

function Get-M365DscAgentIdentityName
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName
    )

    return "M365DscLcm${ProjectName}${EnvironmentName}Identity"
}

function Get-M365DscAgentVm
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName
    )

    $vmName = Get-M365DscAgentVmName -ProjectName $ProjectName -EnvironmentName $EnvironmentName
    $vms = @(Get-AzVM -Status -ErrorAction Stop | Where-Object Name -EQ $vmName)
    if ($vms.Count -le 1)
    {
        return $vms | Select-Object -First 1
    }

    $preferredResourceGroupNames = @(
        Get-M365DscAgentResourceGroupName -ProjectName $ProjectName -EnvironmentName $EnvironmentName
        "$ProjectName$EnvironmentName"
    )
    foreach ($preferredResourceGroupName in $preferredResourceGroupNames)
    {
        $preferredVms = @($vms | Where-Object ResourceGroupName -EQ $preferredResourceGroupName)
        if ($preferredVms.Count -eq 1)
        {
            $otherResourceGroups = @(
                $vms |
                    Where-Object ResourceGroupName -NE $preferredResourceGroupName |
                    Select-Object -ExpandProperty ResourceGroupName -Unique
            ) -join ', '
            Write-Warning "Found duplicate VM names; using '$preferredResourceGroupName' and leaving matching VM(s) in '$otherResourceGroups' untouched."
            return $preferredVms[0]
        }
    }

    $matchingResourceGroups = @($vms | Select-Object -ExpandProperty ResourceGroupName -Unique) -join ', '
    throw "Found more than one VM named '$vmName' and could not uniquely select the canonical or legacy resource group. Matching resource groups: $matchingResourceGroups."
}

function Get-M365DscKeyVaultName
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter()]
        [ValidateRange(0, 1000)]
        [int]$Generation = 0
    )

    $prefix = "$ProjectName-$EnvironmentName" -replace '[^a-zA-Z0-9-]', '-'
    $prefix = $prefix -replace '-{2,}', '-'
    $prefix = $prefix.Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($prefix))
    {
        throw 'The project and environment names must contain at least one alphanumeric character.'
    }

    if ($prefix.Length -gt 12)
    {
        $prefix = $prefix.Substring(0, 12).TrimEnd('-')
    }

    $hashInput = if ($Generation -eq 0)
    {
        [System.Text.Encoding]::UTF8.GetBytes("$TenantId|$SubscriptionId")
    }
    else
    {
        [System.Text.Encoding]::UTF8.GetBytes("$TenantId|$SubscriptionId|generation:$Generation")
    }
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $suffix = [System.BitConverter]::ToString($hash.ComputeHash($hashInput)).Replace('-', '').Substring(0, 8).ToLowerInvariant()
    }
    finally
    {
        $hash.Dispose()
    }

    return "kv-$prefix-$suffix"
}

function Resolve-M365DscKeyVaultName
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $context = Get-AzContext -ErrorAction Stop
    if (-not [string]::Equals($context.Subscription.Id, $SubscriptionId, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "The active Azure subscription '$($context.Subscription.Id)' does not match the Key Vault subscription '$SubscriptionId'."
    }

    $resourceGroupName = "$ProjectName-$EnvironmentName-credentials-rg" -replace '[^a-zA-Z0-9_.()-]', '-'
    $resourceGroups = @(Get-AzResourceGroup -Name $resourceGroupName -ErrorAction Stop)
    if ($resourceGroups.Count -gt 1)
    {
        throw "More than one resource group named '$resourceGroupName' was found in the active subscription."
    }

    $taggedVaultName = ''
    if ($resourceGroups.Count -gt 0 -and $resourceGroups[0].Tags)
    {
        $taggedVaultName = [string]$resourceGroups[0].Tags['M365DscKeyVaultName']
    }

    $candidateNames = @(
        for ($generation = 0; $generation -le 1000; $generation++)
        {
            Get-M365DscKeyVaultName `
                -ProjectName $ProjectName `
                -EnvironmentName $EnvironmentName `
                -TenantId $TenantId `
                -SubscriptionId $SubscriptionId `
                -Generation $generation
        }
    )
    if ($taggedVaultName -and $taggedVaultName -notin $candidateNames)
    {
        throw "The Key Vault name recorded on resource group '$resourceGroupName' is invalid."
    }

    $activeVaults = @(Get-AzKeyVault -ResourceGroupName $resourceGroupName -ErrorAction Stop)
    $activeCandidates = @(
        $activeVaults | Where-Object { $_.VaultName -in $candidateNames } | ForEach-Object {
            $vaults = @(Get-AzKeyVault `
                    -VaultName $_.VaultName `
                    -ResourceGroupName $resourceGroupName `
                    -ErrorAction Stop)
            if ($vaults.Count -ne 1)
            {
                throw "Could not uniquely resolve active Key Vault '$($_.VaultName)' in resource group '$resourceGroupName'."
            }

            $vaults[0]
        }
    )
    $taggedVaults = @($activeCandidates | Where-Object VaultName -IEQ $taggedVaultName)
    if ($taggedVaults.Count -gt 1)
    {
        throw "More than one active Key Vault named '$taggedVaultName' was found in resource group '$resourceGroupName'."
    }
    if ($taggedVaults.Count -eq 1 -and $taggedVaults[0].EnableRbacAuthorization -eq $true)
    {
        return $taggedVaultName
    }

    $rbacCandidates = @($activeCandidates | Where-Object EnableRbacAuthorization -EQ $true)
    if ($rbacCandidates.Count -gt 0)
    {
        $vault = $rbacCandidates |
            Sort-Object { [Array]::IndexOf([string[]]$candidateNames, [string]$_.VaultName) } -Descending |
            Select-Object -First 1
        return [string]$vault.VaultName
    }

    throw "No active RBAC Key Vault was found in resource group '$resourceGroupName'. Run the project credential bootstrap first."
}

function Get-M365DscKeyVaultSecretName
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$IdentityName,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'secret',
            'pfx',
            'pfx-password',
            'application-id',
            'certificate-thumbprint',
            'tenant-id',
            'tenant-name',
            'subscription-id',
            'personal-access-token',
            'build-agent-password'
        )]
        [string]$CredentialType
    )

    $identityToken = ($IdentityName -replace '[^a-zA-Z0-9-]', '-').Trim('-').ToLowerInvariant()
    $secretName = "$identityToken-$CredentialType"
    if ($secretName.Length -gt 127)
    {
        throw "The generated Key Vault secret name '$secretName' exceeds the 127-character limit."
    }

    return $secretName
}

function Initialize-M365DscKeyVault
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $defaultVaultName = Get-M365DscKeyVaultName `
        -ProjectName $ProjectName `
        -EnvironmentName $EnvironmentName `
        -TenantId $TenantId `
        -SubscriptionId $SubscriptionId
    $resourceGroupName = "$ProjectName-$EnvironmentName-credentials-rg" -replace '[^a-zA-Z0-9_.()-]', '-'
    $context = Get-AzContext -ErrorAction Stop
    if (-not [string]::Equals($context.Subscription.Id, $SubscriptionId, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "The active Azure subscription '$($context.Subscription.Id)' does not match the Key Vault subscription '$SubscriptionId'."
    }

    $keyVaultProvider = Get-AzResourceProvider -ProviderNamespace 'Microsoft.KeyVault' -ErrorAction Stop
    if ($keyVaultProvider.RegistrationState -ne 'Registered')
    {
        Register-AzResourceProvider -ProviderNamespace 'Microsoft.KeyVault' -ErrorAction Stop | Out-Null
        for ($attempt = 1; $attempt -le 12; $attempt++)
        {
            $keyVaultProvider = Get-AzResourceProvider -ProviderNamespace 'Microsoft.KeyVault' -ErrorAction Stop
            if ($keyVaultProvider.RegistrationState -eq 'Registered')
            {
                break
            }

            if ($attempt -eq 12)
            {
                throw "The Microsoft.KeyVault resource provider did not register in subscription '$SubscriptionId'."
            }

            Start-Sleep -Seconds 5
        }
    }

    $resourceGroups = @(Get-AzResourceGroup -ErrorAction Stop |
        Where-Object {
            [string]::Equals([string]$_.ResourceGroupName, $resourceGroupName, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($resourceGroups.Count -gt 1)
    {
        throw "More than one resource group named '$resourceGroupName' was found in subscription '$SubscriptionId'."
    }

    $resourceGroup = $resourceGroups | Select-Object -First 1
    if (-not $resourceGroup)
    {
        Write-Host "Creating credential resource group '$resourceGroupName' in '$Location'."
        $resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $Location -ErrorAction Stop
    }

    $vault = $null

    $candidateNames = @(
        for ($generation = 0; $generation -le 1000; $generation++)
        {
            Get-M365DscKeyVaultName `
                -ProjectName $ProjectName `
                -EnvironmentName $EnvironmentName `
                -TenantId $TenantId `
                -SubscriptionId $SubscriptionId `
                -Generation $generation
        }
    )
    $taggedVaultName = ''
    if ($resourceGroup.Tags)
    {
        $taggedVaultName = [string]$resourceGroup.Tags['M365DscKeyVaultName']
    }
    if ($taggedVaultName -and $taggedVaultName -notin $candidateNames)
    {
        throw "Resource group '$resourceGroupName' contains an unrecognized Key Vault name tag '$taggedVaultName'."
    }

    $activeVaults = @(Get-AzKeyVault -SubscriptionId $SubscriptionId -ErrorAction Stop)
    $deletedVaults = @(Get-AzKeyVault -InRemovedState -SubscriptionId $SubscriptionId -ErrorAction Stop)
    $activeCandidateSummaries = @(
        $activeVaults | Where-Object {
            $_.VaultName -in $candidateNames -and
            [string]::Equals([string]$_.ResourceGroupName, $resourceGroupName, [StringComparison]::OrdinalIgnoreCase)
        }
    )
    $activeCandidates = @(
        foreach ($candidate in $activeCandidateSummaries)
        {
            $vaults = @(Get-AzKeyVault `
                    -VaultName $candidate.VaultName `
                    -ResourceGroupName $resourceGroupName `
                    -ErrorAction Stop)
            if ($vaults.Count -ne 1)
            {
                throw "Could not uniquely resolve active Key Vault '$($candidate.VaultName)' in resource group '$resourceGroupName'."
            }

            $vaults[0]
        }
    )
    $taggedActiveVaults = @()
    if ($taggedVaultName)
    {
        $taggedActiveVaults = @($activeCandidates | Where-Object VaultName -IEQ $taggedVaultName)
    }

    if ($taggedActiveVaults.Count -gt 1)
    {
        throw "More than one active Key Vault named '$taggedVaultName' was found in subscription '$SubscriptionId'."
    }

    if ($taggedActiveVaults.Count -eq 1)
    {
        $vault = $taggedActiveVaults[0]
        $vaultName = $taggedVaultName
    }
    elseif ($activeCandidates.Count -gt 0)
    {
        $rbacCandidates = @($activeCandidates | Where-Object EnableRbacAuthorization -EQ $true)
        $selectableCandidates = if ($rbacCandidates.Count -gt 0) { $rbacCandidates } else { $activeCandidates }
        $vault = $selectableCandidates |
            Sort-Object { [Array]::IndexOf([string[]]$candidateNames, [string]$_.VaultName) } -Descending |
            Select-Object -First 1
        $vaultName = $vault.VaultName
    }
    else
    {
        $taggedVaultIsDeleted = $taggedVaultName -and
            @($deletedVaults | Where-Object VaultName -IEQ $taggedVaultName).Count -gt 0
        if ($taggedVaultName -and -not $taggedVaultIsDeleted)
        {
            $vaultName = $taggedVaultName
        }
        else
        {
            $vaultName = $null
            foreach ($candidateName in $candidateNames)
            {
                $isActive = @($activeVaults | Where-Object VaultName -IEQ $candidateName).Count -gt 0
                $isDeleted = @($deletedVaults | Where-Object VaultName -IEQ $candidateName).Count -gt 0
                if (-not ($isActive -or $isDeleted))
                {
                    $vaultName = $candidateName
                    break
                }
            }
            if (-not $vaultName)
            {
                throw "Could not generate an available Key Vault name for resource group '$resourceGroupName'."
            }
        }
    }

    $matchingVaults = @($activeVaults | Where-Object VaultName -IEQ $vaultName)
    if ($matchingVaults.Count -gt 1)
    {
        throw "More than one Key Vault named '$vaultName' was found in subscription '$SubscriptionId'."
    }
    if ($matchingVaults.Count -eq 1)
    {
        if (-not [string]::Equals($matchingVaults[0].ResourceGroupName, $resourceGroupName, [StringComparison]::OrdinalIgnoreCase))
        {
            throw "Key Vault '$vaultName' already exists in resource group '$($matchingVaults[0].ResourceGroupName)' instead of '$resourceGroupName'."
        }
        $vault = Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroupName -ErrorAction Stop
    }

    $legacyVaultName = $null
    if ($vault -and $vault.EnableRbacAuthorization -ne $true)
    {
        $legacyVaultName = $vaultName
        $currentGeneration = [Array]::IndexOf([string[]]$candidateNames, $vaultName)
        $vaultName = $null
        for ($generation = $currentGeneration + 1; $generation -lt $candidateNames.Count; $generation++)
        {
            $candidateName = $candidateNames[$generation]
            $isActive = @($activeVaults | Where-Object VaultName -IEQ $candidateName).Count -gt 0
            $isDeleted = @($deletedVaults | Where-Object VaultName -IEQ $candidateName).Count -gt 0
            if (-not ($isActive -or $isDeleted))
            {
                $vaultName = $candidateName
                break
            }
        }
        if (-not $vaultName)
        {
            throw "Could not generate an available RBAC Key Vault name to replace legacy vault '$legacyVaultName'."
        }

        Write-Host "Legacy Key Vault '$legacyVaultName' will not be reused or changed; creating '$vaultName'."
        $vault = $null
    }

    if (@($deletedVaults | Where-Object VaultName -IEQ $vaultName).Count -gt 0)
    {
        throw "The selected Key Vault name '$vaultName' is soft-deleted; refusing to recover or reuse it."
    }

    if (-not $vault)
    {
        if ($vaultName -ne $defaultVaultName -and -not $legacyVaultName)
        {
            Write-Host "Soft-deleted Key Vault '$defaultVaultName' will not be reused; creating '$vaultName'."
        }
        Write-Host "Creating Key Vault '$vaultName' in resource group '$resourceGroupName'."
        $vault = New-AzKeyVault `
            -VaultName $vaultName `
            -ResourceGroupName $resourceGroupName `
            -Location $Location `
            -EnablePurgeProtection `
            -DisableRbacAuthorization:$false `
            -ErrorAction Stop
    }
    if ($vault.EnableRbacAuthorization -ne $true)
    {
        throw "Key Vault '$vaultName' must use Azure RBAC authorization. Review the existing vault before changing its permission model."
    }
    if ($vault.EnablePurgeProtection -ne $true)
    {
        $vault = Update-AzKeyVault `
            -VaultName $vault.VaultName `
            -ResourceGroupName $vault.ResourceGroupName `
            -EnablePurgeProtection `
            -ErrorAction Stop
    }

    if ($taggedVaultName -ne $vaultName)
    {
        $resourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupName"
        Update-AzTag `
            -ResourceId $resourceGroupId `
            -Tag @{ M365DscKeyVaultName = $vaultName } `
            -Operation Merge `
            -Confirm:$false `
            -ErrorAction Stop | Out-Null
    }

    return $vault
}

function Ensure-M365DscKeyVaultRoleAssignment
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultResourceId,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Key Vault Secrets Officer', 'Key Vault Secrets User')]
        [string]$RoleDefinitionName
    )

    $vaults = @(
        Get-AzKeyVault -ErrorAction Stop |
            Where-Object ResourceId -EQ $VaultResourceId
    )
    if ($vaults.Count -ne 1)
    {
        throw "Could not uniquely resolve Key Vault '$VaultResourceId' to grant access to principal '$PrincipalId'."
    }

    $vault = $vaults[0]
    $vaultResource = Get-AzResource `
        -ResourceId $VaultResourceId `
        -ExpandProperties `
        -ErrorAction Stop
    $enableRbacAuthorization = $vaultResource.Properties.EnableRbacAuthorization
    if ($null -eq $enableRbacAuthorization)
    {
        $enableRbacAuthorization = $vault.EnableRbacAuthorization
    }
    if ($null -eq $enableRbacAuthorization)
    {
        throw "Could not determine the authorization model for Key Vault '$($vault.VaultName)'."
    }

    if ($enableRbacAuthorization -eq $true)
    {
        $resourceGroupScope = [regex]::Replace(
            $VaultResourceId,
            '/providers/Microsoft\.KeyVault/vaults/[^/]+$',
            '',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($resourceGroupScope -eq $VaultResourceId)
        {
            throw "Could not derive the resource group scope from Key Vault resource ID '$VaultResourceId'."
        }

        $readerAssignments = @(
            Get-AzRoleAssignment `
                -ObjectId $PrincipalId `
                -Scope $resourceGroupScope `
                -RoleDefinitionName 'Reader' `
                -ErrorAction Stop
        )
        if ($readerAssignments.Count -eq 0)
        {
            Write-Host "Assigning 'Reader' on the credential resource group to principal '$PrincipalId' so it can resolve the Key Vault name."
            New-AzRoleAssignment `
                -ObjectId $PrincipalId `
                -Scope $resourceGroupScope `
                -RoleDefinitionName 'Reader' `
                -ErrorAction Stop | Out-Null
        }
        $assignments = @(
            Get-AzRoleAssignment `
                -ObjectId $PrincipalId `
                -Scope $VaultResourceId `
                -RoleDefinitionName $RoleDefinitionName `
                -ErrorAction Stop
        )
        if ($assignments.Count -gt 0)
        {
            return
        }

        Write-Host "Assigning '$RoleDefinitionName' on Key Vault to principal '$PrincipalId'."
        New-AzRoleAssignment `
            -ObjectId $PrincipalId `
            -Scope $VaultResourceId `
            -RoleDefinitionName $RoleDefinitionName `
            -ErrorAction Stop | Out-Null
        return
    }

    $existingPolicy = @($vault.AccessPolicies | Where-Object ObjectId -EQ $PrincipalId)
    $requiredSecretPermissions = if ($RoleDefinitionName -eq 'Key Vault Secrets Officer')
    {
        @('Get', 'List', 'Set', 'Delete', 'Recover', 'Backup', 'Restore', 'Purge')
    }
    else
    {
        @('Get', 'List')
    }
    $existingSecretPermissions = @($existingPolicy | ForEach-Object PermissionsToSecrets)
    $secretPermissions = @(
        $existingSecretPermissions + $requiredSecretPermissions |
            Sort-Object -Unique
    )
    $policyParameters = @{
        VaultName          = $vault.VaultName
        ResourceGroupName  = $vault.ResourceGroupName
        ObjectId           = $PrincipalId
        PermissionsToSecrets = $secretPermissions
        ErrorAction        = 'Stop'
    }
    if ($existingPolicy.Count -gt 0)
    {
        $policy = $existingPolicy[0]
        if ($policy.PermissionsToKeys)
        {
            $policyParameters.PermissionsToKeys = @($policy.PermissionsToKeys)
        }
        if ($policy.PermissionsToCertificates)
        {
            $policyParameters.PermissionsToCertificates = @($policy.PermissionsToCertificates)
        }
        if ($policy.PermissionsToStorage)
        {
            $policyParameters.PermissionsToStorage = @($policy.PermissionsToStorage)
        }
    }

    Write-Host "Granting '$RoleDefinitionName' secret permissions through the existing access policy on Key Vault to principal '$PrincipalId'."
    Set-AzKeyVaultAccessPolicy @policyParameters | Out-Null
}

function Test-M365DscKeyVaultSecret
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $secretNames = @(
        Get-AzKeyVaultSecret -VaultName $VaultName -ErrorAction Stop |
            Select-Object -ExpandProperty Name
    )

    return $Name -in $secretNames
}

function Get-M365DscKeyVaultSecret
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop
    if ($null -eq $secret.SecretValue)
    {
        throw "Key Vault secret '$Name' in vault '$VaultName' has no value."
    }

    return $secret.SecretValue
}

function Wait-M365DscKeyVaultAccess
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName
    )

    $maximumAttempts = 61
    $retryIntervalSeconds = 10
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++)
    {
        try
        {
            Get-AzKeyVaultSecret -VaultName $VaultName -ErrorAction Stop | Out-Null
            Write-Host "[Environment: $EnvironmentName] Key Vault '$VaultName' access is ready." -ForegroundColor Green
            return
        }
        catch
        {
            $exception = $_.Exception
            $statusCode = 0
            while ($exception)
            {
                $responseProperty = $exception.PSObject.Properties['Response']
                if ($responseProperty -and $responseProperty.Value)
                {
                    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
                }
                else
                {
                    $statusProperty = $exception.PSObject.Properties['StatusCode']
                    if (-not $statusProperty)
                    {
                        $statusProperty = $exception.PSObject.Properties['Status']
                    }
                }
                if ($statusProperty -and $null -ne $statusProperty.Value)
                {
                    $statusCode = [int]$statusProperty.Value
                    break
                }
                $exception = $exception.InnerException
            }

            if ($_.Exception.Message -match 'ForbiddenByFirewall|ForbiddenByConnection|Public network access is disabled|Client address is not authorized')
            {
                throw [InvalidOperationException]::new(
                    "Environment '$EnvironmentName': network access to Key Vault '$VaultName' is blocked; waiting for RBAC propagation will not resolve this. Run provisioning from a host with connectivity and DNS resolution to the vault's approved private endpoint, or ask the subscription administrator to review the vault networking and applicable Azure Policy. $($_.Exception.Message)",
                    $_.Exception
                )
            }
            if ($statusCode -notin @(401, 403))
            {
                throw
            }
            if ($attempt -eq $maximumAttempts)
            {
                throw [InvalidOperationException]::new(
                    "Environment '$EnvironmentName': Key Vault '$VaultName' is still inaccessible after 61 attempts with ten minutes of propagation waits. Verify the operator's Key Vault Secrets Officer assignment, deny assignments, and network access. $($_.Exception.Message)",
                    $_.Exception
                )
            }

            Write-Host "[Environment: $EnvironmentName] Waiting for access to Key Vault '$VaultName' after role assignment (attempt $attempt/$maximumAttempts; retry in $retryIntervalSeconds seconds)." -ForegroundColor Yellow
            Start-Sleep -Seconds $retryIntervalSeconds
        }
    }
}

function Get-M365DscProjectSettingsFromKeyVault
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Datum,

        [Parameter()]
        [ValidateSet('personal-access-token', 'build-agent-password')]
        [string[]]$CredentialType = @('personal-access-token', 'build-agent-password')
    )

    $settings = $Datum.Global.ProjectSettings
    $environmentName = [string]$settings.CredentialVaultEnvironment
    if ([string]::IsNullOrWhiteSpace($environmentName))
    {
        throw "Set 'CredentialVaultEnvironment' in 'source/Global/ProjectSettings.yml' to an environment from 'source/Global/Azure.yml'."
    }

    $environment = $Datum.Global.Azure.Environments[$environmentName]
    if ($null -eq $environment)
    {
        throw "Credential vault environment '$environmentName' is not configured in 'source/Global/Azure.yml'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$environment.AzTenantName))
    {
        throw "Tenant domain for credential vault environment '$environmentName' is not configured."
    }

    $contextParameters = @{
        TenantName = [string]$environment.AzTenantName
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$environment.AzSubscriptionId))
    {
        $contextParameters.SubscriptionId = [string]$environment.AzSubscriptionId
    }
    Write-M365DscEnvironmentContext -EnvironmentName $environmentName -TenantName $environment.AzTenantName -Operation 'Signing in for project credential access'
    $context = Connect-M365DscEnvironmentContext @contextParameters
    $vaultName = Resolve-M365DscKeyVaultName `
        -ProjectName $settings.ProjectName `
        -EnvironmentName $environmentName `
        -TenantId $context.Tenant.Id `
        -SubscriptionId $context.Subscription.Id

    Write-M365DscEnvironmentContext -EnvironmentName $environmentName -TenantName $environment.AzTenantName `
        -TenantId $context.Tenant.Id -SubscriptionId $context.Subscription.Id -KeyVaultName $vaultName `
        -Operation 'Loading project credentials'

    $credentials = @(
        @{
            PropertyName  = 'PersonalAccessToken'
            CredentialType = 'personal-access-token'
        }
        @{
            PropertyName  = 'BuildAgents.Password'
            CredentialType = 'build-agent-password'
        }
    ) | Where-Object CredentialType -In $CredentialType
    foreach ($credential in $credentials)
    {
        $secretName = Get-M365DscKeyVaultSecretName `
            -IdentityName 'ProjectSettings' `
            -CredentialType $credential.CredentialType
        if (-not (Test-M365DscKeyVaultSecret -VaultName $vaultName -Name $secretName))
        {
            throw "Key Vault '$vaultName' is missing project setting secret '$secretName'. Run the project credential bootstrap first."
        }

        $secureValue = Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $secretName
        try
        {
            $plainValue = ConvertTo-M365DscPlainText -Value $secureValue
            if ([string]::IsNullOrWhiteSpace($plainValue))
            {
                throw "Key Vault secret '$secretName' is empty."
            }
            if ($credential.PropertyName -eq 'PersonalAccessToken')
            {
                $settings.PersonalAccessToken = $plainValue
            }
            else
            {
                $settings.BuildAgents.Password = $plainValue
            }
        }
        finally
        {
            $secureValue.Dispose()
        }
    }

    return $Datum
}

function Set-M365DscKeyVaultSecret
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [securestring]$SecretValue,

        [Parameter()]
        [string]$ContentType = 'application/octet-stream',

        [Parameter()]
        [switch]$Overwrite
    )

    if ((Test-M365DscKeyVaultSecret -VaultName $VaultName -Name $Name) -and -not $Overwrite)
    {
        return
    }

    Set-AzKeyVaultSecret `
        -VaultName $VaultName `
        -Name $Name `
        -SecretValue $SecretValue `
        -ContentType $ContentType `
        -ErrorAction Stop | Out-Null
}

function ConvertTo-M365DscPlainText
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [securestring]$Value
    )

    return [System.Net.NetworkCredential]::new('', $Value).Password
}

function ConvertTo-M365DscSecureString
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $secureValue = [securestring]::new()
    foreach ($character in $Value.ToCharArray())
    {
        $secureValue.AppendChar($character)
    }
    $secureValue.MakeReadOnly()

    return $secureValue
}

function Connect-M365DscEnvironmentContext
{
    [CmdletBinding(DefaultParameterSetName = 'Interactive')]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [Parameter(ParameterSetName = 'Interactive')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true, ParameterSetName = 'ManagedIdentity')]
        [switch]$ManagedIdentity
    )

    $cachedContext = $null
    if ($ManagedIdentity)
    {
        $managedIdentityClientId = [string]$env:AZURE_CLIENT_ID
        if ([string]::IsNullOrWhiteSpace($managedIdentityClientId))
        {
            throw 'Managed-identity Key Vault access requires AZURE_CLIENT_ID to be configured on the build agent. Run the agent setup script again.'
        }

        Connect-AzAccount -Identity -AccountId $managedIdentityClientId -ErrorAction Stop | Out-Null
    }
    else
    {
        if ((Get-AzConfig -EnableLoginByWam -ErrorAction Stop).Value)
        {
            Update-AzConfig -EnableLoginByWam $false -Scope Process -ErrorAction Stop | Out-Null
        }
        Enable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
        $contextName = "M365DscWorkshop-$($TenantName.ToLowerInvariant())"
        $cachedContexts = @(Get-AzContext -ListAvailable -ErrorAction Stop | Where-Object {
                $_.Account.Type -eq 'User' -and
                ($_.Name -eq $contextName -or
                    ($_.Name -like 'M365DscWorkshop-*' -and $_.Tenant.Id -eq $TenantName))
            })
        if ($cachedContexts.Count -gt 1)
        {
            throw "Multiple saved user contexts match tenant '$TenantName'. Remove the ambiguous workshop contexts before retrying."
        }
        if ($cachedContexts.Count -eq 1)
        {
            $cachedContext = $cachedContexts[0]
            $contextName = $cachedContext.Name
            Set-AzContext -Context $cachedContext -Scope Process -Force -ErrorAction Stop | Out-Null
            try
            {
                Get-AzAccessToken -TenantId $cachedContext.Tenant.Id -ResourceTypeName Arm -ErrorAction Stop | Out-Null
            }
            catch
            {
                $exception = $_.Exception
                $requiresSignIn = $false
                while ($exception)
                {
                    if ($exception.GetType().FullName -eq 'Microsoft.Identity.Client.MsalUiRequiredException')
                    {
                        $requiresSignIn = $true
                        break
                    }
                    $exception = $exception.InnerException
                }
                if (-not $requiresSignIn)
                {
                    throw
                }
                Write-Warning "The saved session for tenant '$TenantName' requires interactive authentication again."
                $cachedContext = $null
            }
        }
        if ($cachedContext)
        {
            if ($TenantName -ne $cachedContext.Tenant.Id)
            {
                $tenant = Get-AzTenant -TenantId $cachedContext.Tenant.Id -ErrorAction Stop
                if ($TenantName -notin $tenant.Domains)
                {
                    throw "Saved context '$contextName' does not belong to tenant domain '$TenantName'."
                }
            }
            Write-Host "Reusing Azure sign-in for tenant '$TenantName'." -ForegroundColor Green
        }
        else
        {
            Write-Host "Signing in to tenant '$TenantName'; later lab steps will reuse this session." -ForegroundColor Cyan
            Connect-AzAccount -Tenant $TenantName -Scope CurrentUser -ErrorAction Stop | Out-Null
        }
    }

    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Tenant.Id)
    {
        throw 'Azure sign-in completed without an active tenant context.'
    }

    $subscriptions = @(
        Get-AzSubscription -TenantId $context.Tenant.Id -ErrorAction Stop |
            Where-Object { $_.State -eq 'Enabled' }
    )
    $cachedSubscription = @($subscriptions | Where-Object {
            $cachedContext -and $_.Id -eq $cachedContext.Subscription.Id
        })
    if ($SubscriptionId)
    {
        $selectedSubscription = @(
            $subscriptions | Where-Object { $_.Id -eq $SubscriptionId }
        )
        if ($selectedSubscription.Count -ne 1)
        {
            throw "Subscription '$SubscriptionId' is not uniquely available in tenant '$($context.Tenant.Id)'."
        }
    }
    elseif ($subscriptions.Count -eq 1)
    {
        $selectedSubscription = $subscriptions
    }
    elseif ($cachedSubscription.Count -eq 1)
    {
        $selectedSubscription = $cachedSubscription
    }
    elseif ($subscriptions.Count -gt 1 -and -not $ManagedIdentity)
    {
        Write-Host 'Select the Azure subscription for this environment:'
        for ($index = 0; $index -lt $subscriptions.Count; $index++)
        {
            Write-Host ("[{0}] {1} ({2})" -f ($index + 1), $subscriptions[$index].Name, $subscriptions[$index].Id)
        }

        $selection = Read-Host -Prompt 'Subscription number'
        $selectionNumber = 0
        if (-not [int]::TryParse($selection, [ref]$selectionNumber) -or
            $selectionNumber -lt 1 -or
            $selectionNumber -gt $subscriptions.Count)
        {
            throw "The subscription selection '$selection' is invalid."
        }
        $selectedSubscription = @($subscriptions[$selectionNumber - 1])
    }
    elseif ($subscriptions.Count -gt 1)
    {
        $contextSubscription = @(
            $subscriptions | Where-Object { $_.Id -eq $context.Subscription.Id }
        )
        if ($contextSubscription.Count -ne 1)
        {
            throw "The managed identity has access to multiple subscriptions in tenant '$($context.Tenant.Id)'; configure an explicit subscription selection for this agent."
        }
        $selectedSubscription = $contextSubscription
    }
    else
    {
        throw "No enabled Azure subscriptions are available in tenant '$($context.Tenant.Id)'."
    }

    $contextParameters = @{
        TenantId       = $context.Tenant.Id
        SubscriptionId = $selectedSubscription[0].Id
        ErrorAction    = 'Stop'
    }
    if (-not $ManagedIdentity)
    {
        $contextParameters.Name = $contextName
        $contextParameters.Scope = 'CurrentUser'
        $contextParameters.Force = $true
    }
    Set-AzContext @contextParameters | Out-Null

    return Get-AzContext -ErrorAction Stop
}

function Set-M365DscEnvironmentMetadata
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [object[]]$Identities
    )

    $metadata = [ordered]@{
        '__environment|tenant-id'      = $TenantId
        '__environment|tenant-name'    = $TenantName
        '__environment|subscription-id' = $SubscriptionId
    }
    foreach ($identity in $Identities)
    {
        if (-not $identity.Name)
        {
            throw 'Cannot store Key Vault identity metadata without an identity name.'
        }

        if ($identity.ApplicationId)
        {
            $metadata["$($identity.Name)|application-id"] = [string]$identity.ApplicationId
        }
        if ($identity.ApplicationSecret)
        {
            $metadata["$($identity.Name)|secret"] = [string]$identity.ApplicationSecret
        }
        if ($identity.CertificateThumbprint)
        {
            $metadata["$($identity.Name)|certificate-thumbprint"] = [string]$identity.CertificateThumbprint
        }
    }

    foreach ($entry in $metadata.GetEnumerator())
    {
        $parts = $entry.Key -split '\|', 2
        $secretName = Get-M365DscKeyVaultSecretName -IdentityName $parts[0] -CredentialType $parts[1]
        Set-M365DscKeyVaultSecret `
            -VaultName $VaultName `
            -Name $secretName `
            -SecretValue (ConvertTo-M365DscSecureString -Value $entry.Value) `
            -ContentType 'text/plain' `
            -Overwrite
    }
}

function Get-M365DscEnvironmentFromKeyVault
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [Parameter()]
        [bool]$HasExchangeOnline = $false,

        [Parameter()]
        [bool]$HasSharePointOnline = $false,

        [Parameter()]
        [switch]$ManagedIdentity,

        [Parameter()]
        [switch]$IncludeCredentials,

        [Parameter()]
        [string[]]$CredentialIdentityName
    )

    $contextParameters = @{
        TenantName = $TenantName
    }
    if ($ManagedIdentity)
    {
        $contextParameters.ManagedIdentity = $true
    }
    Write-M365DscEnvironmentContext -EnvironmentName $EnvironmentName -TenantName $TenantName -Operation 'Signing in to load environment metadata'
    $context = Connect-M365DscEnvironmentContext @contextParameters
    $tenantId = [string]$context.Tenant.Id
    $subscriptionId = [string]$context.Subscription.Id
    $vaultName = Resolve-M365DscKeyVaultName `
        -ProjectName $ProjectName `
        -EnvironmentName $EnvironmentName `
        -TenantId $tenantId `
        -SubscriptionId $subscriptionId

    Write-M365DscEnvironmentContext -EnvironmentName $EnvironmentName -TenantName $TenantName `
        -TenantId $tenantId -SubscriptionId $subscriptionId -KeyVaultName $vaultName `
        -Operation 'Loading environment metadata'

    $metadata = [ordered]@{
        TenantId       = $tenantId
        TenantName     = $TenantName
        SubscriptionId = $subscriptionId
    }
    foreach ($metadataField in @('tenant-id', 'tenant-name', 'subscription-id'))
    {
        $secretName = Get-M365DscKeyVaultSecretName -IdentityName '__environment' -CredentialType $metadataField
        if (-not (Test-M365DscKeyVaultSecret -VaultName $vaultName -Name $secretName))
        {
            throw "Key Vault '$vaultName' is missing required environment metadata '$secretName'. Run the tenant bootstrap first."
        }

        $storedValue = ConvertTo-M365DscPlainText -Value (Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $secretName)
        $fieldName = switch ($metadataField)
        {
            'tenant-id' { 'TenantId' }
            'tenant-name' { 'TenantName' }
            'subscription-id' { 'SubscriptionId' }
        }
        if (-not [string]::Equals($storedValue, [string]$metadata[$fieldName], [StringComparison]::OrdinalIgnoreCase))
        {
            throw "The signed-in Azure context does not match '$fieldName' stored in Key Vault '$vaultName'."
        }
    }

    $identities = foreach ($identityName in 'M365DscSetupApplication', 'M365DscLcmApplication', 'M365DscExportApplication')
    {
        $applicationIdSecretName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'application-id'
        if (-not (Test-M365DscKeyVaultSecret -VaultName $vaultName -Name $applicationIdSecretName))
        {
            throw "Key Vault '$vaultName' is missing application metadata '$applicationIdSecretName'. Run the tenant bootstrap first."
        }

        $identity = [ordered]@{
            Name          = $identityName
            ApplicationId = ConvertTo-M365DscPlainText -Value (Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $applicationIdSecretName)
        }
        $thumbprintSecretName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'certificate-thumbprint'
        if (Test-M365DscKeyVaultSecret -VaultName $vaultName -Name $thumbprintSecretName)
        {
            $identity.CertificateThumbprint = ConvertTo-M365DscPlainText -Value (Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $thumbprintSecretName)
        }

        if ($IncludeCredentials -and
            (-not $CredentialIdentityName -or $identityName -in $CredentialIdentityName))
        {
            $applicationSecretName = Get-M365DscKeyVaultSecretName -IdentityName $identityName -CredentialType 'secret'
            if (Test-M365DscKeyVaultSecret -VaultName $vaultName -Name $applicationSecretName)
            {
                $identity.ApplicationSecret = ConvertTo-M365DscPlainText -Value (Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $applicationSecretName)
            }
        }

        [pscustomobject]$identity
    }

    return [pscustomobject][ordered]@{
        AzTenantId          = $tenantId
        AzTenantName        = $TenantName
        AzSubscriptionId    = $subscriptionId
        HasExchangeOnline   = $HasExchangeOnline
        HasSharePointOnline = $HasSharePointOnline
        KeyVaultName        = $vaultName
        Identities          = @($identities)
    }
}

function Update-M365DscDatumFromKeyVault
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Datum,

        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter()]
        [string[]]$EnvironmentName,

        [Parameter()]
        [switch]$ManagedIdentity,

        [Parameter()]
        [switch]$IncludeCredentials,

        [Parameter()]
        [string[]]$CredentialIdentityName
    )

    $environmentNames = @($Datum.Global.Azure.Environments.Keys)
    if ($EnvironmentName)
    {
        $unknownEnvironments = @($EnvironmentName | Where-Object { $_ -notin $environmentNames })
        if ($unknownEnvironments)
        {
            throw "Unknown environment(s): $($unknownEnvironments -join ', ')."
        }
        $environmentNames = @($environmentNames | Where-Object { $_ -in $EnvironmentName })
    }

    foreach ($envName in $environmentNames)
    {
        $manifest = $Datum.Global.Azure.Environments[$envName]
        $environmentParameters = @{
            ProjectName         = $ProjectName
            EnvironmentName     = [string]$envName
            TenantName          = [string]$manifest.AzTenantName
            HasExchangeOnline   = [bool]$manifest.HasExchangeOnline
            HasSharePointOnline = [bool]$manifest.HasSharePointOnline
        }
        if ($ManagedIdentity)
        {
            $environmentParameters.ManagedIdentity = $true
        }
        if ($IncludeCredentials)
        {
            $environmentParameters.IncludeCredentials = $true
        }
        if ($CredentialIdentityName)
        {
            $environmentParameters.CredentialIdentityName = $CredentialIdentityName
        }

        $Datum.Global.Azure.Environments[$envName] = Get-M365DscEnvironmentFromKeyVault @environmentParameters
    }

    return $Datum
}

function Get-ServicePrincipalAppPermissions
{
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'byId')]
        [string]$ObjectId,

        [Parameter(Mandatory = $true, ParameterSetName = 'byDisplayName')]
        [string]$DisplayName
    )

    $principal = if ($ObjectId)
    {
        Get-MgServicePrincipal -Filter "Id eq 'ObjectId'" -ErrorAction SilentlyContinue
    }
    else
    {
        Get-MgServicePrincipal -Filter "DisplayName eq '$DisplayName'" -ErrorAction SilentlyContinue
    }

    if (-not $principal)
    {
        Write-Error 'Service principal not found'
        return
    }

    $appRoles = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principal.Id

    foreach ($appRole in $appRoles)
    {
        $api = Get-MgServicePrincipal -Filter "DisplayName eq '$($appRole.ResourceDisplayName)'"
        $apiPermission = $api.AppRoles | Where-Object Id -EQ $appRole.AppRoleId

        [pscustomobject][ordered]@{
            ApiAppId             = $api.AppId
            ApiId                = $api.Id
            ApiRoleId            = $apiPermission.Id
            ApiDisplayName       = $api.DisplayName
            ApiPermissionName    = $apiPermission.Value
            PermissionType       = $apiPermission.AllowedMemberTypes -join ', '
            AppRoleAssignmentId  = $appRole.Id
            PrincipalDisplayName = $appRole.PrincipalDisplayName
            PrincipalId          = $appRole.PrincipalId
        }
    }
}

function Set-ServicePrincipalAppPermissions
{
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'byId')]
        [string]$ObjectId,

        [Parameter(Mandatory = $true, ParameterSetName = 'byDisplayName')]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [object[]]$Permissions,

        [Parameter()]
        [switch]$PassThru
    )

    $principal = if ($ObjectId)
    {
        Get-MgServicePrincipal -Filter "Id eq 'ObjectId'" -ErrorAction SilentlyContinue
    }
    else
    {
        Get-MgServicePrincipal -Filter "DisplayName eq '$DisplayName'" -ErrorAction SilentlyContinue
    }

    if (-not $principal)
    {
        Write-Error "Service principal named '$DisplayName' or with the Object ID '$ObjectId' could not found"
        return
    }

    if ($principal.Count -gt 1)
    {
        Write-Error "Multiple service principals with display name '$DisplayName' found"
        return
    }

    [void]$PSBoundParameters.Remove('Permissions')
    [void]$PSBoundParameters.Remove('PassThru')

    $existingPermissions = Get-ServicePrincipalAppPermissions @PSBoundParameters

    foreach ($p in $permissions)
    {
        if (($existingPermissions | Where-Object ApiRoleId -EQ $p.ApiRoleId) -or (-not $p.ApiRoleId))
        {
            Write-Verbose "Permission '$($p.ApiPermissionName)' ($($p.ApiRoleId)) already exists for '$($p.ApiDisplayName)'"
            continue
        }

        Write-Verbose "Adding Permission '$($p.ApiPermissionName)' ($($p.ApiRoleId)) for '$($p.ApiDisplayName)'"
        $params = @{
            ServicePrincipalId = $principal.Id
            AppRoleId          = $p.ApiRoleId
            ResourceId         = $p.ApiId
            PrincipalId        = $principal.Id
        }
        New-MgServicePrincipalAppRoleAssignment @params -ErrorAction SilentlyContinue -ErrorVariable assignmentError | Out-Null
        if ($assignmentError.Count -gt 0)
        {
            if ($assignmentError.Exception.Message -like '*already exists*')
            {
                Write-Verbose "Permission '$($p.ApiPermissionName)' ($($p.ApiRoleId)) already exists for '$($p.ApiDisplayName)'"
            }
            else
            {
                Write-Error -ErrorRecord $_
            }
        }
        else
        {
            Write-Verbose "Added role assignment / permission '$($p.ApiPermissionName)' for principal '$($p.PrincipalDisplayName)'"
        }
    }

    if ($PassThru)
    {
        Get-ServicePrincipalAppPermissions @PSBoundParameters
    }

}

function Remove-ServicePrincipalAppPermissions
{
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'byId')]
        [string]$ObjectId,

        [Parameter(Mandatory = $true, ParameterSetName = 'byDisplayName')]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [object[]]$Permissions,

        [Parameter()]
        [switch]$PassThru
    )

    $principal = if ($ObjectId)
    {
        Get-MgServicePrincipal -Filter "Id eq 'ObjectId'" -ErrorAction SilentlyContinue
    }
    else
    {
        Get-MgServicePrincipal -Filter "DisplayName eq '$DisplayName'" -ErrorAction SilentlyContinue
    }

    if (-not $principal)
    {
        Write-Error "Service principal '$($principal.DisplayName)' not found"
        return
    }

    if ($principal.Count -gt 1)
    {
        Write-Error "Multiple service principals with display name '$DisplayName' found"
        return
    }

    [void]$PSBoundParameters.Remove('Permissions')
    [void]$PSBoundParameters.Remove('PassThru')

    $existingPermissions = Get-ServicePrincipalAppPermissions @PSBoundParameters

    foreach ($p in $permissions)
    {
        if ($roleAssignment = $existingPermissions | Where-Object { $_.ApiRoleId -eq $p.ApiRoleId -and $_.ApiAppId -eq $p.ApiAppId })
        {
            if (-not $roleAssignment)
            {
                Write-Warning "Role assignment / permission '$($p.ApiPermissionName)' ($($p.ApiRoleId)) does not exist for '$($p.ApiDisplayName)' and cannot be removed."
                continue
            }

            Remove-MgServicePrincipalAppRoleAssignment -AppRoleAssignmentId $roleAssignment.AppRoleAssignmentId -ServicePrincipalId $principal.Id -ErrorAction SilentlyContinue
            Write-Host "Removed role assignment / permission '$($roleAssignment.ApiPermissionName)' for principal '$($principal.DisplayName)' (AppRoleAssignmentId was '$($roleAssignment.AppRoleAssignmentId)')"

        }
        else
        {
            Write-Verbose "Permission '$($p.ApiPermissionName)' ($($p.ApiRoleId)) does not exist for '$($p.ApiDisplayName)' and cannot be removed."
        }
    }

    if ($PassThru)
    {
        Get-ServicePrincipalAppPermissions @PSBoundParameters
    }

}

function Get-M365DSCCompiledPermissionList2
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Update', 'Read')]
        [string]$AccessType = 'Update'
    )

    $m365GraphPermissionList = Get-M365DSCCompiledPermissionList -ResourceNameList (Get-M365DSCAllResources) -ErrorAction Stop

    $resourceAppIds = @{
        Graph      = '00000003-0000-0000-c000-000000000000'
        SharePoint = '00000003-0000-0ff1-ce00-000000000000'
        Exchange   = '00000002-0000-0ff1-ce00-000000000000'
    }

    $exchangeAvailable = Test-M365DscExchangeOnlineConnection
    if (-not $exchangeAvailable)
    {
        Write-Host 'Exchange Online is not connected, skipping the Exchange Online API permissions.' -ForegroundColor Yellow
        $resourceAppIds.Remove('Exchange')
    }

    try
    {
        $servicePrincipals = @{}
        foreach ($resourceAppId in $resourceAppIds.GetEnumerator())
        {
            $servicePrincipals."$($resourceAppId.Name)" = Get-MgServicePrincipal -Filter "AppId eq '$($resourceAppId.Value)'" -ErrorAction Stop
        }
    }
    catch
    {
        Write-Error "Failed to retrieve service principals for '$($resourceAppIds.Keys -join ', ')'. The error was: $($_.Exception.Message)"
        return
    }

    $permissions = $m365GraphPermissionList.$AccessType

    if (-not $exchangeAvailable)
    {
        $permissions = $permissions | Where-Object { $_.Api -ne 'Exchange' }
    }

    if ($AccessType -eq 'Read')
    {
        $sitesReadAllGet = GraphPermission -PermissionName Sites.Read.All
        $permissions += @{
            API        = 'Graph'
            Permission = @{
                Name = $sitesReadAllGet.ApiPermissionName
                Type = $sitesReadAllGet.PermissionType
            }
        }
    }

    $result = foreach ($permission in $permissions)
    {
        $servicePrincipal = $servicePrincipals."$($permission.Api)"

        $appRole = $servicePrincipal.AppRoles | Where-Object -FilterScript { $_.Value -eq $permission.Permission.Name }

        [pscustomobject][ordered]@{
            ApiAppId          = $servicePrincipal.AppId
            ApiId             = $servicePrincipal.Id
            ApiRoleId         = $appRole.Id
            ApiDisplayName    = $servicePrincipal.DisplayName
            ApiPermissionName = $permission.Permission.Name
            PermissionType    = $permission.Permission.Type
        }
    }

    if ($AccessType -eq 'Read')
    {
        $result | Where-Object { $_.ApiPermissionName -notlike '*FullControl*' -and $_.ApiPermissionName -notlike '*Write*' }
    }
    else
    {
        $result
    }
}

function Get-GraphPermission
{
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$PermissionName
    )

    $servicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
    $appRoles = $servicePrincipal.AppRoles | Where-Object { $_.Permission.Type -ne 'Delegated' }

    foreach ($Permission in $PermissionName)
    {
        $appRole = $appRoles | Where-Object Value -EQ $Permission

        if (-not $appRole)
        {
            Write-Warning "Permission '$Permission' not found"
            continue
        }

        [pscustomobject][ordered]@{
            ApiAppId          = $servicePrincipal.AppId
            ApiId             = $servicePrincipal.Id
            ApiRoleId         = $appRole.Id
            ApiDisplayName    = $servicePrincipal.DisplayName
            ApiPermissionName = $appRole.Value
            PermissionType    = $appRole.AllowedMemberTypes[0]
        }
    }
}

function Connect-Azure
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [securestring]$ServicePrincipalSecret,

        [Parameter()]
        [string[]]$Scopes = ('RoleManagement.ReadWrite.Directory',
            'Directory.ReadWrite.All',
            'Application.ReadWrite.All',
            'Group.ReadWrite.All',
            'GroupMember.ReadWrite.All',
            'User.ReadWrite.All'
        )
    )

    $cred = New-Object pscredential($ServicePrincipalId, $ServicePrincipalSecret)

    try
    {
        Connect-MgGraph -ClientSecretCredential $cred -TenantId $TenantId -NoWelcome
        $graphContext = Get-MgContext
        Write-Host "Connected to Graph API '$($graphContext.TenantId)' with account '$($graphContext.ClientId)'"
    }
    catch
    {
        Write-Error "Failed to connect to Graph API of tenant '$TenantId' with service principal '$ServicePrincipalId'. The error was: $($_.Exception.Message)"
        return
    }

    try
    {
        $subscription = Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $TenantId -ErrorAction Stop
        Write-Host "Successfully connected to Azure subscription '$($subscription.Context.Subscription.Name) ($($subscription.Context.Subscription.Id))' with account '$($subscription.Context.Account.Id)'"
    }
    catch
    {
        Write-Error "Failed to connect to Azure tenant '$TenantId' / subscription '$SubscriptionId' with service principal '$ServicePrincipalId'. The error was: $($_.Exception.Message)"
        return
    }
}

function Connect-EXO
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$TenantName,

        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalSecret
    )

    $tokenBody = @{
        Grant_Type    = 'client_credentials'
        Scope         = 'https://outlook.office365.com/.default'
        Client_Id     = $ServicePrincipalId
        Client_Secret = $ServicePrincipalSecret
    }

    try
    {
        $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody

        Connect-ExchangeOnline -AccessToken $tokenResponse.access_token -Organization $TenantName -ShowBanner:$false

        Write-Host "Successfully connected to Exchange Online of tenant '$TenantName' with service principal '$ServicePrincipalId'"
    }
    catch
    {
        Write-Error "Failed to connect to Exchange Online of tenant '$TenantName' with service principal '$ServicePrincipalId'. The error was: $($_.Exception.Message)"
        return
    }
}

enum M365DscIdentityType
{
    Application
    ManagedIdentity
}

class M365DscIdentity
{
    [string]$DisplayName
    [string]$Id
    [string]$AppId
    [string]$AppPrincipalId
    [string]$ExchangePrincipalId
    [M365DscIdentityType]$ServicePrincipalType
    [object]$Secret
    [string]$CertificateThumbprint

    M365DscIdentity([string]$DisplayName, [string]$Id, [string]$AppId, [string]$AppPrincipalId, [string]$ExchangePrincipalId, [M365DscIdentityType]$ServicePrincipalType, [object]$Secret)
    {
        $this.DisplayName = $DisplayName
        $this.Id = $Id
        $this.AppId = $AppId
        $this.AppPrincipalId = $AppPrincipalId
        $this.ExchangePrincipalId = $ExchangePrincipalId
        $this.ServicePrincipalType = $ServicePrincipalType
        $this.Secret = $Secret
    }

    M365DscIdentity([string]$DisplayName, [string]$Id, [string]$AppId, [string]$AppPrincipalId, [string]$ExchangePrincipalId, [M365DscIdentityType]$ServicePrincipalType, [string]$CertificateThumbprint)
    {
        $this.DisplayName = $DisplayName
        $this.Id = $Id
        $this.AppId = $AppId
        $this.AppPrincipalId = $AppPrincipalId
        $this.ExchangePrincipalId = $ExchangePrincipalId
        $this.ServicePrincipalType = $ServicePrincipalType
        $this.CertificateThumbprint = $CertificateThumbprint
    }

    M365DscIdentity([string]$DisplayName, [string]$Id, [string]$AppId, [string]$AppPrincipalId, [string]$ExchangePrincipalId, [M365DscIdentityType]$ServicePrincipalType)
    {
        $this.DisplayName = $DisplayName
        $this.Id = $Id
        $this.AppId = $AppId
        $this.AppPrincipalId = $AppPrincipalId
        $this.ExchangePrincipalId = $ExchangePrincipalId
        $this.ServicePrincipalType = $ServicePrincipalType
    }
}

function New-M365DscIdentity
{
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Default')]
        [string]$Name,

        [Parameter(ParameterSetName = 'AppSecret')]
        [switch]$GenereateAppSecret,

        [Parameter(ParameterSetName = 'Certificate')]
        [switch]$GenereateCertificate,

        [Parameter(ParameterSetName = 'AppSecret')]
        [Parameter(ParameterSetName = 'Certificate')]
        [Parameter(ParameterSetName = 'Default')]
        [switch]$OnlyServicePrincipals,

        [Parameter(ParameterSetName = 'AppSecret')]
        [Parameter(ParameterSetName = 'Certificate')]
        [Parameter(ParameterSetName = 'Default')]
        [switch]$PassThru
    )

    if (-not (Get-MgContext))
    {
        Write-Error "You are not connected to the Microsoft Graph. Please run 'Connect-M365Dsc'."
        return
    }

    if (-not $OnlyServicePrincipals)
    {
        $matchingApplications = @(
            Get-MgApplication -Filter "displayName eq '$Name'" -ErrorAction Stop
        )
        if ($matchingApplications.Count -gt 1)
        {
            throw "More than one Entra application is named '$Name'; refusing to choose one."
        }

        if ($matchingApplications.Count -eq 0)
        {
            Write-Verbose "Did not find application '$Name' in environment."
            Write-Verbose "Creating application '$Name'."

            $appRegistration = New-MgApplication -DisplayName $Name

            Update-MgApplication -ApplicationId $appRegistration.Id -SignInAudience AzureADMyOrg
        }
        else
        {
            $appRegistration = $matchingApplications[0]
            Write-Verbose "Application '$Name' already exists in environment."
        }

        if ($GenereateAppSecret)
        {
            $passwordCred = @{
                displayName = 'Secret'
                endDateTime = (Get-Date).AddMonths(12)
            }
            Write-Verbose "Updating application '$($appRegistration.DisplayName)' (Id: $($appRegistration.Id)) with new secret."
            $clientSecret = Add-MgApplicationPassword -ApplicationId $appRegistration.Id -PasswordCredential $passwordCred
        }
        elseif ($GenereateCertificate)
        {
            $certificate = New-M365DSCSelfSignedCertificate -Subject $Name -Store LocalMachine -PassThru

            if ($certificate.Count -gt 1)
            {
                Write-Error 'More than one certificate was generated. This is not expected. Please investigate.'
                return
            }

            $bytes = $certificate.Export('Cert')
            $params = @{
                keyCredentials = @(
                    @{
                        type        = 'AsymmetricX509Cert'
                        usage       = 'Verify'
                        key         = $bytes
                        displayName = 'GeneratedByM365DscWorkshop'
                    }
                )
            }

            Write-Host "Updating application '$($appRegistration.DisplayName)' (Id: $($appRegistration.Id)) with new certificate (thumbprint: $($certificate.Thumbprint))."
            Update-MgApplication -ApplicationId $appRegistration.Id -BodyParameter $params
        }
    }

    $appPrincipals = @(
        Get-MgServicePrincipal -Filter "DisplayName eq '$Name'" -ErrorAction Stop
    )
    if ($appPrincipals.Count -gt 1)
    {
        throw "More than one Entra service principal is named '$Name'; refusing to choose one."
    }

    $appPrincipal = $appPrincipals | Select-Object -First 1
    if (-not $appPrincipal)
    {
        Write-Verbose "Creating service principal for application '$Name'."
        $appPrincipal = New-MgServicePrincipal -AppId $appRegistration.AppId
    }

    if (-not (Test-M365DscExchangeOnlineConnection))
    {
        Write-Host "Exchange Online is not connected, skipping the EXO service principal for application '$Name'." -ForegroundColor Yellow
    }
    elseif ($exchangeServicePrincipal = Get-ServicePrincipal | Where-Object DisplayName -EQ $Name)
    {
        Write-Verbose "The EXO service principal for application '$Name' already exists."
    }
    else
    {
        Write-Verbose "Creating the EXO service principal for application '$Name'."
        $retryCount = 5
        while ($retryCount -gt 0)
        {
            try
            {
                $exchangeServicePrincipal = New-ServicePrincipal -AppId $appPrincipal.AppId -ObjectId $appPrincipal.Id -DisplayName $Name -ErrorAction Stop
                break
            }
            catch
            {
                Write-Warning "Failed to create the EXO service principal for application '$Name'. Retrying in 10 seconds."
                Start-Sleep -Seconds 10
                $retryCount--
            }
        }
    }

    if ($PassThru)
    {
        $app = Get-M365DscIdentity -Name $Name
        if ($GenereateAppSecret)
        {
            $app.Secret = $clientSecret.SecretText
        }
        elseif ($GenereateCertificate)
        {
            $app.CertificateThumbprint = $certificate.Thumbprint
        }

        $app
    }
}

function Remove-M365DscIdentity
{
    [CmdletBinding(DefaultParameterSetName = 'byName')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'byName')]
        [string]$Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'byIdentity')]
        [M365DscIdentity]$Identity
    )

    if ($psCmdlet.ParameterSetName -eq 'byName')
    {
        $identity = Get-M365DscIdentity -Name $Name
    }

    if ($identity.ExchangePrincipalId)
    {
        Write-Verbose "Removing EXO service principal for application '$($Identity.DisplayName)'."
        Remove-ServicePrincipal -Identity $($Identity.DisplayName) -Confirm:$false
    }
    elseif (-not (Test-M365DscExchangeOnlineConnection))
    {
        Write-Verbose "Exchange Online is not connected, skipping the EXO service principal of application '$($Identity.DisplayName)'."
    }
    else
    {
        Write-Verbose "EXO service principal for application '$($Identity.DisplayName)' does not exist."
    }

    if ($null -eq $identity)
    {
        Write-Verbose "Application '$($Identity.DisplayName)' does not exist."
    }
    elseif (-not $identity.Id)
    {
        # A managed identity has a service principal but no application registration.
        Write-Verbose "Identity '$($Identity.DisplayName)' has no application registration to remove."
    }
    else
    {
        Write-Verbose "Removing application '$($Identity.DisplayName)'."
        Remove-MgApplication -ApplicationId $identity.Id
    }
}

function Get-M365DscIdentity
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try
    {
        $appRegistrations = @(
            Get-MgApplication -Filter "displayName eq '$Name'" -ErrorAction Stop
        )
    }
    catch
    {
        $errorRecord = $_
        $exception = $errorRecord.Exception
        while ($null -ne $exception)
        {
            if ($exception.GetType().FullName -eq 'Microsoft.Graph.PowerShell.AuthenticationException')
            {
                Write-Error -Message "You are not connected to the Microsoft Graph. Please run 'Connect-M365Dsc'." -Exception $errorRecord.Exception -ErrorAction Stop
            }

            $exception = $exception.InnerException
        }

        throw
    }

    if ($appRegistrations.Count -gt 1)
    {
        throw "More than one Entra application is named '$Name'; refusing to choose one."
    }

    $appRegistration = $appRegistrations | Select-Object -First 1
    if ($appRegistration)
    {
        Write-Verbose "Found application '$Name' with Id '$($appRegistration.Id)' and AppId '$($appRegistration.AppId)'."
        $appPrincipals = @(
            Get-MgServicePrincipal -Filter "DisplayName eq '$Name'" -ErrorAction Stop
        )
        if ($appPrincipals.Count -gt 1)
        {
            throw "More than one Entra service principal is named '$Name'; refusing to choose one."
        }
        $appPrincipal = $appPrincipals | Select-Object -First 1
        $exchangeServicePrincipal = if (Test-M365DscExchangeOnlineConnection)
        {
            Get-ServicePrincipal -Identity $Name -ErrorAction SilentlyContinue
        }

        if ($appRegistration.KeyCredentials.Count -gt 0)
        {
            if ($appRegistration.KeyCredentials.Count -ne 1)
            {
                Write-Host "Application '$Name' has more than one certificate. This is not expected. Only the first certificate will be returned."
            }

            $certificate = $appRegistration.KeyCredentials[0]
            $certificateThumbPrint = [System.Convert]::ToBase64String($certificate.CustomKeyIdentifier)

            [M365DscIdentity]::new($appRegistration.DisplayName,
                $appRegistration.Id,
                $appRegistration.AppId,
                $appPrincipal.Id,
                $exchangeServicePrincipal.Id,
                $appPrincipal.ServicePrincipalType,
                $certificateThumbPrint)
        }
        else
        {
            [M365DscIdentity]::new($appRegistration.DisplayName,
                $appRegistration.Id,
                $appRegistration.AppId,
                $appPrincipal.Id,
                $exchangeServicePrincipal.Id,
                $appPrincipal.ServicePrincipalType)
        }
    }
    elseif ($principal = Get-MgServicePrincipal -Filter "DisplayName eq '$Name'" -ErrorAction SilentlyContinue)
    {
        Write-Verbose "Found principal '$Name' with Id '$($principal.Id)' and AppId '$($principal.AppId)'."
        $exchangeServicePrincipal = if (Test-M365DscExchangeOnlineConnection)
        {
            Get-ServicePrincipal -Identity $Name -ErrorAction SilentlyContinue
        }

        [M365DscIdentity]::new($principal.DisplayName,
            $null,
            $principal.AppId,
            $principal.Id,
            $exchangeServicePrincipal.Id,
            $principal.ServicePrincipalType)
    }
    else
    {
        Write-Verbose "Application '$Name' does not exist in environment."
    }
}

function Test-M365DscConnection
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter()]
        [string]$SubscriptionId,

        [Parameter()]
        [switch]$SkipExchangeOnline
    )

    $azContext = Get-AzContext
    $mgContext = Get-MgContext
    $exoConnection = Get-ConnectionInformation

    $isConnected = $true

    if ($null -eq $azContext)
    {
        Write-Error "Azure context is not set. Please run 'Connect-AzAccount'."
        $isConnected = $false
    }

    if ($null -eq $mgContext)
    {
        Write-Error "Microsoft Graph context is not set. Please run 'Connect-MgGraph'."
        $isConnected = $false
    }

    if ($null -eq $exoConnection -and -not $SkipExchangeOnline)
    {
        Write-Error "Exchange Online connection is not set. Please run 'Connect-ExchangeOnline'."
        $isConnected = $false
    }

    if (-not $isConnected)
    {
        return $false
    }

    if ($azContext.Tenant.Id -ne $TenantId)
    {
        Write-Error "Azure context tenant ID '$($azContext.Tenant.Id)' does not match the provided tenant ID '$TenantId'."
        $isConnected = $false
    }
    else
    {
        Write-Host "Azure context tenant ID '$($azContext.Tenant.Id)' matches the provided tenant ID."
    }

    if ([string]::IsNullOrEmpty($SubscriptionId))
    {
        Write-Host 'Azure context subscription ID is not set.'
    }
    elseif ($azContext.Subscription.Id -ne $SubscriptionId)
    {
        Write-Error "Azure context subscription ID '$($azContext.Subscription.Id)' does not match the provided subscription ID '$SubscriptionId'."
        $isConnected = $false
    }
    else
    {
        Write-Host "Azure context subscription ID '$($azContext.Subscription.Id)' matches the provided subscription ID."
    }

    if ($mgContext.TenantId -ne $TenantId)
    {
        Write-Error "Microsoft Graph context tenant ID does not match the provided tenant ID: '$TenantId'."
        $isConnected = $false
    }
    else
    {
        Write-Host 'Microsoft Graph context tenant ID '$($mgContext.TenantId)' matches the provided tenant ID.'
    }

    if ($null -eq $exoConnection -and $SkipExchangeOnline)
    {
        Write-Host 'Exchange Online is not connected, skipping its tenant ID validation.'
    }
    elseif ($exoConnection.TenantId -ne $TenantId)
    {
        Write-Error "Exchange Online connection tenant ID '$($exoConnection.TenantId)' does not match the provided tenant ID: '$TenantId'."
        $isConnected = $false
    }
    else
    {
        Write-Host "Exchange Online connection tenant ID '$($exoConnection.TenantId)' matches the provided tenant ID."
    }

    return $isConnected
}

function Connect-M365DscAzure
{
    [CmdletBinding(DefaultParameterSetName = 'Interactive')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
        [string]$TenantId,

        [Parameter(ParameterSetName = 'AppSecret')]
        [Parameter(ParameterSetName = 'Certificate')]
        [Parameter(ParameterSetName = 'Interactive')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [securestring]$ServicePrincipalSecret,

        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [string]$CertificateThumbprint,

        [Parameter()]
        [string[]]$Scopes = ('RoleManagement.ReadWrite.Directory',
            'Directory.ReadWrite.All',
            'Application.ReadWrite.All',
            'Group.ReadWrite.All',
            'GroupMember.ReadWrite.All',
            'User.ReadWrite.All'
        )
    )

    if ($PSCmdlet.ParameterSetName -eq 'AppSecret')
    {
        $cred = New-Object pscredential($ServicePrincipalId, $ServicePrincipalSecret)
    }

    try
    {
        if ($PSCmdlet.ParameterSetName -eq 'AppSecret')
        {
            $param = @{
                ServicePrincipal = $true
                Credential       = $cred
                Tenant           = $TenantId
                ErrorAction      = 'Stop'
                WarningAction    = 'Ignore'
            }
            if ($SubscriptionId)
            {
                $param.Subscription = $SubscriptionId
            }
            $subscription = Connect-AzAccount @param *>&1
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Certificate')
        {
            $param = @{
                Tenant                = $TenantId
                ApplicationId         = $ServicePrincipalId
                CertificateThumbprint = $CertificateThumbprint
                ErrorAction           = 'Stop'
                WarningAction         = 'Ignore'
            }
            if ($SubscriptionId)
            {
                $param.Subscription = $SubscriptionId
            }
            $subscription = Connect-AzAccount @param *>&1
        }
        else
        {
            $contextParameters = @{ TenantName = $TenantId }
            if ($SubscriptionId)
            {
                $contextParameters.SubscriptionId = $SubscriptionId
            }
            $subscription = [pscustomobject]@{
                Context = Connect-M365DscEnvironmentContext @contextParameters
            }
        }
        Write-Host "Successfully connected to Azure subscription '$($subscription.Context.Subscription.Name)' ($($subscription.Context.Subscription.Id))' with account '$($subscription.Context.Account.Id)'"
    }
    catch
    {
        Write-Error "Failed to connect to Azure tenant '$TenantId' / subscription '$SubscriptionId'. The error was: $($_.Exception.Message)."
        return
    }

    try
    {
        $token = Get-AzAccessToken -ResourceTypeName MSGraph
        Connect-MgGraph -AccessToken $token.Token -NoWelcome
        $graphContext = Get-MgContext
        Write-Host "Connected to Graph API '$($graphContext.TenantId)' with account '$($graphContext.ClientId)'."
    }
    catch
    {
        Write-Error "Failed to connect to Graph API of tenant '$TenantId'. The error was: $($_.Exception.Message)."
        return
    }
    <#
    try {
        if ($PSCmdlet.ParameterSetName -eq 'AppSecret') {
            Connect-MgGraph -ClientSecretCredential $cred -TenantId $TenantId -NoWelcome -ErrorAction Stop | Out-Null
        }
        else {
            Connect-MgGraph -TenantId $TenantId -NoWelcome -ErrorAction Stop | Out-Null
        }

        $graphContext = Get-MgContext
        Write-Host "Connected to Graph API '$($graphContext.TenantId)' with account '$($graphContext.ClientId)'"
    }
    catch {
        Write-Error "Failed to connect to Graph API of tenant '$TenantId' with service principal '$ServicePrincipalId'. The error was: $($_.Exception.Message)"
        return
    }
    #>
}

function Test-M365DscExchangeOnlineConnection
{
    <#
        .SYNOPSIS
            Tests whether the current session is connected to Exchange Online.

        .DESCRIPTION
            'Connect-M365Dsc' skips the Exchange Online connection for an environment
            configured without Exchange Online. Every function that calls an Exchange Online
            cmdlet uses this test to decide whether it can do the Exchange Online part of its
            work.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Get-ConnectionInformation -ErrorAction SilentlyContinue)
}

function Test-M365DscExchangeOnlineLicense
{
    <#
        .SYNOPSIS
            Tests whether the connected tenant is licensed for Exchange Online.

        .DESCRIPTION
            Reads the tenant entitlement through Microsoft Graph and does not require an
            Exchange Online connection, so it can be called before any Exchange Online prep
            work is attempted. The tenant is licensed when the 'Office 365 Exchange Online'
            resource service principal is enabled and at least one subscribed SKU provides an
            Exchange service plan other than 'EXCHANGE_S_FOUNDATION'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Get-MgContext))
    {
        Write-Error "You are not connected to the Microsoft Graph. Please run 'Connect-M365Dsc'." -ErrorAction Stop
    }

    $exchangeOnlineAppId = '00000002-0000-0ff1-ce00-000000000000'
    $exchangeServicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '$exchangeOnlineAppId'" -ErrorAction Stop

    if (-not $exchangeServicePrincipal)
    {
        Write-Host "The tenant has no 'Office 365 Exchange Online' service principal, hence Exchange Online is not available." -ForegroundColor Yellow
        return $false
    }

    if (-not $exchangeServicePrincipal.AccountEnabled)
    {
        Write-Host "The 'Office 365 Exchange Online' service principal is disabled, hence Exchange Online is not available." -ForegroundColor Yellow
        return $false
    }

    # 'EXCHANGE_S_FOUNDATION' is part of almost every SKU and does not entitle a tenant to Exchange Online.
    $exchangeServicePlans = (Get-MgSubscribedSku -ErrorAction Stop).ServicePlans |
        Where-Object { $_.ServicePlanName -like 'EXCHANGE_*' -and $_.ServicePlanName -ne 'EXCHANGE_S_FOUNDATION' -and $_.ProvisioningStatus -eq 'Success' }

    if (-not $exchangeServicePlans)
    {
        Write-Host 'The tenant has no subscribed SKU with a provisioned Exchange Online service plan, hence Exchange Online is not available.' -ForegroundColor Yellow
        return $false
    }

    Write-Host "The tenant is licensed for Exchange Online with the service plan(s) '$(($exchangeServicePlans.ServicePlanName | Sort-Object -Unique) -join ', ')'."
    return $true
}

function Connect-M365DscExchangeOnline
{
    [CmdletBinding(DefaultParameterSetName = 'Interactive')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
        [string]$TenantId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
        [string]$TenantName,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [securestring]$ServicePrincipalSecret,

        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [string]$CertificateThumbprint
    )

    try
    {
        if ($PSCmdlet.ParameterSetName -eq 'AppSecret')
        {
            $tokenBody = @{
                Grant_Type    = 'client_credentials'
                Scope         = 'https://outlook.office365.com/.default'
                Client_Id     = $ServicePrincipalId
                Client_Secret = $ServicePrincipalSecret | ConvertFrom-SecureString -AsPlainText
            }

            $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody

            Connect-ExchangeOnline -AccessToken $tokenResponse.access_token -Organization $TenantName -ShowBanner:$false
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Certificate')
        {
            Connect-ExchangeOnline -CertificateThumbprint $CertificateThumbprint -AppId $ServicePrincipalId -Organization $TenantName -ShowBanner:$false
        }
        else
        {
            $context = Get-AzContext -ErrorAction Stop
            if ($context.Tenant.Id -ne $TenantId -or $context.Account.Type -ne 'User')
            {
                throw "Delegated Exchange Online authentication requires a user Azure context for tenant '$TenantId'."
            }
            $token = Get-AzAccessToken -TenantId $TenantId -ResourceUrl 'https://outlook.office365.com' -ErrorAction Stop
            $accessToken = ConvertTo-M365DscPlainText -Value $token.Token
            try
            {
                Connect-ExchangeOnline -AccessToken $accessToken -UserPrincipalName $context.Account.Id -ShowBanner:$false -ErrorAction Stop
            }
            finally
            {
                $accessToken = $null
            }
        }

        $connection = Get-ConnectionInformation

        if ($connection.TenantID -ne $TenantId)
        {
            Write-Error "Exchange Online connection tenant ID '$($connection.TenantID)' does not match the provided tenant ID: '$TenantId'."
            Disconnect-ExchangeOnline -Confirm:$false
            return
        }

        Write-Host "Successfully connected to Exchange Online of tenant '$($connection.TenantID)' with identity '$($connection.UserPrincipalName)'."
    }
    catch
    {
        Write-Error "Failed to connect to Exchange Online of tenant '$TenantName'. The error was: $($_.Exception.Message)."
        return
    }
}

function Select-M365DscCommandParameter
{
    # Replaces Sync-M365DSCParameter, which Microsoft365DSC no longer ships as of 1.26.729.2.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.CommandInfo]$Command,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Parameters
    )

    $commonParameters = [System.Management.Automation.PSCmdlet]::CommonParameters +
    [System.Management.Automation.PSCmdlet]::OptionalCommonParameters

    $selectedParameters = @{}
    foreach ($key in $Parameters.Keys)
    {
        if ($Command.Parameters.ContainsKey($key) -and $key -notin $commonParameters)
        {
            $selectedParameters[$key] = $Parameters[$key]
        }
    }

    return $selectedParameters
}

function Connect-M365Dsc
{
    [CmdletBinding(DefaultParameterSetName = 'Interactive')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
        [string]$TenantId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
        [string]$TenantName,

        [Parameter(ParameterSetName = 'AppSecret')]
        [Parameter(ParameterSetName = 'Certificate')]
        [Parameter(ParameterSetName = 'Interactive')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $true, ParameterSetName = 'AppSecret')]
        [securestring]$ServicePrincipalSecret,

        [Parameter(Mandatory = $true, ParameterSetName = 'Certificate')]
        [string]$CertificateThumbprint,

        [Parameter()]
        [switch]$SkipExchangeOnline
    )

    Disconnect-M365Dsc -KeepAzureContext -ErrorAction SilentlyContinue

    Write-Host 'Connecting to Azure, Microsoft Graph, and Exchange Online services.' -ForegroundColor Green
    $param = Select-M365DscCommandParameter -Command (Get-Command -Name Connect-M365DscAzure) -Parameters $PSBoundParameters
    Connect-M365DscAzure @param -ErrorAction Stop

    if ($SkipExchangeOnline)
    {
        Write-Host 'Skipping the Exchange Online connection as configured.' -ForegroundColor Yellow
    }
    else
    {
        if (-not (Test-M365DscExchangeOnlineLicense))
        {
            Write-Error "The tenant '$TenantName' is not licensed for Exchange Online. Set 'HasExchangeOnline' to false for this environment in 'source\Global\Azure.yml'." -ErrorAction Stop
        }

        $param = Select-M365DscCommandParameter -Command (Get-Command -Name Connect-M365DscExchangeOnline) -Parameters $PSBoundParameters
        Connect-M365DscExchangeOnline @param -ErrorAction Stop
    }

    Write-Host 'Connected to all configured services.' -ForegroundColor Green
}

function Disconnect-M365Dsc
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [switch]$KeepAzureContext
    )

    if (Test-M365DscExchangeOnlineConnection)
    {
        Disconnect-ExchangeOnline -Confirm:$false
    }
    Disconnect-MgGraph | Out-Null

    if ($KeepAzureContext)
    {
        Write-Host 'Disconnected from Graph and Exchange Online; Azure sign-in retained for subsequent lab steps.'
        return
    }

    # Az.Accounts writes this failure as a non-terminating error, unless the caller preference makes it terminating.
    $disconnectError = $null
    try
    {
        Disconnect-AzAccount -ErrorAction SilentlyContinue -ErrorVariable disconnectError | Out-Null
    }
    catch
    {
        $disconnectError = @($_)
    }

    if ($disconnectError)
    {
        if ($disconnectError[0].Exception -isnot [System.MissingMethodException])
        {
            Write-Error -ErrorRecord $disconnectError[0]
        }
        else
        {
            # Az.Accounts 5.3.2 is built against MSAL 4.65, while Microsoft.Graph.Authentication ships a newer MSAL (4.90 in 2.41.1) that is loaded into the same process.
            Write-Warning "'Disconnect-AzAccount' failed on the MSAL assembly conflict between 'Az.Accounts' and 'Microsoft.Graph.Authentication'. Clearing the Azure context of this process instead. The error was: $($disconnectError[0].Exception.Message)"
            Clear-AzContext -Scope Process -Force
        }
    }

    Write-Host 'Disconnected from all services.'
}

function Resolve-M365DscAzureMfaChallenge
{
    <#
        .SYNOPSIS
            Replays the multi-factor authentication challenge that Azure returns when a resource write is rejected.

        .DESCRIPTION
            Azure rejects a resource write when the current token was not issued through multi-factor
            authentication and returns the claims challenge to replay. This function extracts that challenge
            from the error record and re-authenticates the current Azure context with it, so the caller can
            retry the operation once. It returns $false for any other error, which the caller must rethrow.

        .PARAMETER ErrorRecord
            The error record raised by the failed Azure cmdlet.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.Exception.Message -notmatch '-ClaimsChallenge\s+"?(?<claimsChallenge>[A-Za-z0-9+/=_-]+)"?')
    {
        return $false
    }

    Write-Host 'Azure requires multi-factor authentication to manage resources. Re-authenticating.' -ForegroundColor Yellow

    $azureContext = Get-AzContext
    $reconnectParam = @{
        Tenant          = $azureContext.Tenant.Id
        Subscription    = $azureContext.Subscription.Id
        ClaimsChallenge = $Matches.claimsChallenge
        WarningAction   = 'Ignore'
        ErrorAction     = 'Stop'
    }
    Connect-AzAccount @reconnectParam | Out-Null

    return $true
}

function Add-M365DscIdentityPermission
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [M365DscIdentity]$Identity,

        [Parameter(ParameterSetName = 'ByAccessType')]
        [ValidateSet('Update', 'Read')]
        [string]$AccessType = 'Update',

        [Parameter(ParameterSetName = 'ByAccessType')]
        [switch]$AddToGlobalAdminRole = $false,

        [Parameter(ParameterSetName = 'ByPermission')]
        [string[]]$Permissions
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByPermission')
    {
        Write-Host 'Adding Microsoft365DSC required Graph API permissions' -ForegroundColor Magenta

        $requiredPermissions = foreach ($permission in $Permissions)
        {
            Get-GraphPermission -PermissionName $permission
        }

        $existingPermissions = @(Get-ServicePrincipalAppPermissions -DisplayName $Identity.DisplayName)
        $permissionDifference = (Compare-Object -ReferenceObject $requiredPermissions -DifferenceObject $existingPermissions).InputObject
    }
    else
    {
        $azureContext = Get-AzContext

        if (-not $azureContext.Subscription.Id)
        {
            Write-Host 'No Azure subscription available. Skipping Azure permissions.' -ForegroundColor Yellow
        }
        else
        {
            Write-Host 'Adding Azure permissions' -ForegroundColor Magenta
            if ($AccessType -eq 'Update')
            {
                if (-not (Get-AzRoleAssignment -ObjectId $Identity.AppPrincipalId -RoleDefinitionName Owner))
                {
                    Write-Host "Assigning the application '$($Identity.DisplayName)' to the role 'Owner'."
                    try
                    {
                        New-AzRoleAssignment -PrincipalId $Identity.AppPrincipalId -RoleDefinitionName Owner -ErrorAction Stop | Out-Null
                    }
                    catch
                    {
                        if (-not (Resolve-M365DscAzureMfaChallenge -ErrorRecord $_))
                        {
                            throw
                        }

                        New-AzRoleAssignment -PrincipalId $Identity.AppPrincipalId -RoleDefinitionName Owner -ErrorAction Stop | Out-Null
                    }
                }
                else
                {
                    Write-Host "The application '$($Identity.DisplayName)' is already assigned to the role 'Owner'."
                }
            }
            Write-Host 'Done adding Azure permissions' -ForegroundColor Magenta
        }

        #------------------------------------------------------------------------------

        Write-Host 'Adding Microsoft365DSC required Graph API permissions' -ForegroundColor Magenta
        $requiredPermissions = Get-M365DSCCompiledPermissionList2 -AccessType $AccessType
        if ($AccessType -eq 'Update')
        {
            $requiredPermissions += Get-GraphPermission -PermissionName AppRoleAssignment.ReadWrite.All
        }
        $existingPermissions = @(Get-ServicePrincipalAppPermissions -DisplayName $Identity.DisplayName)

        $permissionDifference = (Compare-Object -ReferenceObject $requiredPermissions -DifferenceObject $existingPermissions).InputObject
    }

    if ($permissionDifference)
    {
        Write-Host "There are $($permissionDifference.Count) permissions missing for managed identity '$($Identity.DisplayName)'"
        Write-Host "Updating permissions for managed identity '$($Identity.DisplayName)'"
        Set-ServicePrincipalAppPermissions -DisplayName $Identity.DisplayName -Permissions $requiredPermissions
    }
    else
    {
        Write-Host "Permissions for managed identity '$($Identity.DisplayName)' are up to date" -ForegroundColor Green
    }
    Write-Host 'Done adding Microsoft365DSC required Graph API permissions' -ForegroundColor Magenta

    #------------------------------------------------------------------------------

    if ($PSBoundParameters.ContainsKey('AccessType'))
    {
        Write-Host 'Adding identity to required roles Directory Roles' -ForegroundColor Magenta
        $globalReadersRole = Get-MgDirectoryRole -Filter "DisplayName eq 'Global Reader'"
        # If the role hasn't been activated, we need to get the role template ID to first activate the role
        if ($null -eq $globalReadersRole)
        {
            Write-Host "The role 'Global Reader' has not been activated yet. Activating the role."
            $adminRoleTemplate = Get-MgDirectoryRoleTemplate | Where-Object { $_.DisplayName -eq 'Global Reader' }
            New-MgDirectoryRole -RoleTemplateId $adminRoleTemplate.Id | Out-Null
        }

        $appPrincipal = Get-MgServicePrincipal -Filter "DisplayName eq '$($Identity.DisplayName)'"
        $requiredRoles = @('Global Reader')
        $exchangeAvailable = Test-M365DscExchangeOnlineConnection
        if ($AccessType -eq 'Update' -and $exchangeAvailable)
        {
            $requiredRoles += 'Exchange Administrator'
        }
        if ($AddToGlobalAdminRole)
        {
            $requiredRoles += 'Global Administrator'
        }

        foreach ($requiredRole in $requiredRoles)
        {
            $roleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -Filter "DisplayName eq '$requiredRole'"
            if (-not $roleDefinition)
            {
                Write-Host "Role definition '$requiredRole' not found."
                continue
            }

            if (-not (Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$($roleDefinition.Id)' and principalId eq '$($Identity.AppPrincipalId)'"))
            {
                New-MgRoleManagementDirectoryRoleAssignment -PrincipalId $appPrincipal.Id -RoleDefinitionId $roleDefinition.Id -DirectoryScopeId '/' | Out-Null
                Write-Host "Role assignment for service principal '$($Identity.DisplayName)' for role '$($roleDefinition.DisplayName)' created."
            }
            else
            {
                Write-Host "Role assignment for service principal '$($Identity.DisplayName)' for role '$($roleDefinition.DisplayName)' already exists."
            }
        }
        Write-Host 'Done adding identity to required roles Directory Roles' -ForegroundColor Magenta

        #------------------------------------------------------------------------------

        Write-Host 'Adding identity to required roles Exchange Roles' -ForegroundColor Magenta

        if (-not $exchangeAvailable)
        {
            Write-Host 'Exchange Online is not connected, skipping the Exchange role groups.' -ForegroundColor Yellow
        }
        elseif ($AccessType -eq 'Update')
        {
            $requiredRoles = 'Organization Management',
            'Security Administrator',
            'Recipient Management',
            'Compliance Administrator',
            'Compliance Management',
            'Information Protection Admins',
            'Privacy Management Administrators',
            'Privacy Management'

            foreach ($requiredRole in $requiredRoles)
            {
                $role = Get-RoleGroup -Filter "Name -eq '$requiredRole'"
                if (-not $role)
                {
                    Write-Host "Role '$requiredRole' not found."
                    continue
                }

                if (Get-RoleGroupMember -Identity $role.ExchangeObjectId | Where-Object Name -EQ $Identity.AppPrincipalId)
                {
                    Write-Host "The service principal '$($Identity.DisplayName)' is already a member of the role '$requiredRole'."
                    continue
                }

                Write-Host "Adding service principal '$($Identity.DisplayName)' to the role '$requiredRole'."
                Add-RoleGroupMember -Identity $role.ExchangeObjectId -Member $Identity.AppPrincipalId
            }
        }

        Write-Host 'Done adding identity to required roles Exchange Roles' -ForegroundColor Magenta
    }

    Write-Host 'Done adding identity to required permissions and / or roles' -ForegroundColor Magenta
}

function Remove-M365DscIdentityPermission
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [M365DscIdentity]$Identity,

        [switch]$SkipGraphApiPermissions
    )

    Write-Host 'Removing Azure permissions' -ForegroundColor Magenta
    if (Get-AzRoleAssignment -ObjectId $Identity.AppPrincipalId -RoleDefinitionName Owner -ErrorAction Stop)
    {
        Write-Host "Removing the application '$($Identity.DisplayName)' from the role 'Owner'."
        try
        {
            Remove-AzRoleAssignment -PrincipalId $Identity.AppPrincipalId -RoleDefinitionName Owner -ErrorAction Stop | Out-Null
        }
        catch
        {
            if (-not (Resolve-M365DscAzureMfaChallenge -ErrorRecord $_))
            {
                throw
            }

            Remove-AzRoleAssignment -PrincipalId $Identity.AppPrincipalId -RoleDefinitionName Owner -ErrorAction Stop | Out-Null
        }
    }
    else
    {
        Write-Host "The application '$($Identity.DisplayName)' is not assigned to the role 'Owner'."
    }
    Write-Host 'Done removing Azure permissions' -ForegroundColor Magenta

    #------------------------------------------------------------------------------

    if ($SkipGraphApiPermissions)
    {
        Write-Host 'Skipping removal of Microsoft365DSC required Graph API permissions' -ForegroundColor Magenta
    }
    else
    {
        Write-Host 'Removing Microsoft365DSC required Graph API permissions' -ForegroundColor Magenta
        $requiredPermissions = Get-M365DSCCompiledPermissionList2 -AccessType Update
        $requiredPermissions += Get-GraphPermission -PermissionName AppRoleAssignment.ReadWrite.All

        Write-Host "Removing permissions for managed identity '$($Identity.DisplayName)'"
        Remove-ServicePrincipalAppPermissions -DisplayName $Identity.DisplayName -Permissions $requiredPermissions

        Write-Host 'Done removing Microsoft365DSC required Graph API permissions' -ForegroundColor Magenta
    }

    #------------------------------------------------------------------------------

    Write-Host 'Removing identity to required roles Directory Roles' -ForegroundColor Magenta
    $appPrincipal = Get-MgServicePrincipal -Filter "DisplayName eq '$($Identity.DisplayName)'"
    $requiredRoles = 'Global Reader', 'Exchange Administrator'

    foreach ($requiredRole in $requiredRoles)
    {
        $roleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -Filter "DisplayName eq '$requiredRole'"
        if (-not $roleDefinition)
        {
            Write-Host "Role definition '$requiredRole' not found."
            continue
        }

        if ($roleAssignment = Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$($roleDefinition.Id)' and principalId eq '$($Identity.AppPrincipalId)'")
        {
            Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId $roleAssignment.Id
            Write-Host "Role assignment for service principal '$($Identity.DisplayName)' for role '$($roleDefinition.DisplayName)' removed."
        }
        else
        {
            Write-Host "Role assignment for service principal '$($Identity.DisplayName)' for role '$($roleDefinition.DisplayName)' does not exist."
        }
    }
    Write-Host 'Done removing identity to required roles Directory Roles' -ForegroundColor Magenta

    #------------------------------------------------------------------------------

    Write-Host 'Removing identity to required roles Exchange Roles' -ForegroundColor Magenta

    if (-not (Test-M365DscExchangeOnlineConnection))
    {
        Write-Host 'Exchange Online is not connected, skipping the Exchange role groups.' -ForegroundColor Yellow
    }
    else
    {
        $requiredRoles = 'Organization Management',
        'Security Administrator',
        'Recipient Management',
        'Compliance Administrator',
        'Compliance Management',
        'Information Protection Admins',
        'Privacy Management Administrators',
        'Privacy Management'

        foreach ($requiredRole in $requiredRoles)
        {
            $role = Get-RoleGroup -Filter "Name -eq '$requiredRole'"
            if (-not $role)
            {
                Write-Host "Role '$requiredRole' not found."
                continue
            }

            if (-not (Get-RoleGroupMember -Identity $role.ExchangeObjectId | Where-Object Name -EQ $Identity.AppPrincipalId))
            {
                Write-Host "The service principal '$($Identity.DisplayName)' is not a member of the role '$requiredRole'."
                continue
            }

            Write-Host "Removing service principal '$($Identity.DisplayName)' from the role '$requiredRole'."
            Remove-RoleGroupMember -Identity $role.ExchangeObjectId -Member $Identity.AppPrincipalId -Confirm:$false
        }
    }

    Write-Host 'Done removing identity to required roles Exchange Roles' -ForegroundColor Magenta
}
