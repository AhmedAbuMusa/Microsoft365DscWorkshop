BeforeAll {
    $requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
    if ($env:PSModulePath -notlike "*$requiredModulesPath*")
    {
        $env:PSModulePath = $env:PSModulePath + [IO.Path]::PathSeparator + $requiredModulesPath
    }

    $requiredModules = Import-PowerShellDataFile -Path $PSScriptRoot\..\..\RequiredModules.psd1

    # Importing a binary Az or Graph module into a session that already holds it fails with
    # 'Assembly with same name is already loaded'. The build session loads Az before 'TestConfigData'
    # runs, so take whatever is loaded and pin the version only for a session that has none.
    $moduleNames = 'Az.Accounts',
    'Az.Compute',
    'Az.Resources',
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Applications',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'ExchangeOnlineManagement'

    foreach ($moduleName in $moduleNames)
    {
        if (Get-Module -Name $moduleName)
        {
            continue
        }

        $requiredVersion = $requiredModules[$moduleName]
        if ($requiredVersion -is [hashtable])
        {
            $requiredVersion = $requiredVersion.Version
        }

        if ($requiredVersion -and $requiredVersion -ne 'latest')
        {
            Import-Module -Name $moduleName -RequiredVersion $requiredVersion
        }
        else
        {
            Import-Module -Name $moduleName
        }
    }

    Import-Module -Name $PSScriptRoot\..\..\lab\AutomatedLab\AzHelpers.psm1 -Force
}

Describe 'Agent VM naming and selection' {
    It 'Should return the canonical hyphenated resource group and stable VM and identity names' {
        Get-M365DscAgentResourceGroupName -ProjectName 'DSC' -EnvironmentName 'Dev' |
            Should -Be 'DSC-Dev-rg'
        Get-M365DscAgentVmName -ProjectName 'DSC' -EnvironmentName 'Dev' |
            Should -Be 'LcmDSCDev'
        Get-M365DscAgentIdentityName -ProjectName 'DSC' -EnvironmentName 'Dev' |
            Should -Be 'M365DscLcmDSCDevIdentity'
    }

    It 'Should prefer a VM in the canonical resource group when names are duplicated' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-AzVM -MockWith {
                [pscustomobject]@{ Name = 'LcmDSCDev'; ResourceGroupName = 'DSCDev' }
                [pscustomobject]@{ Name = 'LcmDSCDev'; ResourceGroupName = 'DSC-Dev-rg' }
            }

            $vm = Get-M365DscAgentVm -ProjectName 'DSC' -EnvironmentName 'Dev'

            $vm.ResourceGroupName | Should -Be 'DSC-Dev-rg'
        }
    }

    It 'Should retain compatibility with a uniquely named legacy AutomatedLab resource group' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-AzVM -MockWith {
                [pscustomobject]@{ Name = 'LcmDSCDev'; ResourceGroupName = 'DSCDev' }
            }

            $vm = Get-M365DscAgentVm -ProjectName 'DSC' -EnvironmentName 'Dev'

            $vm.ResourceGroupName | Should -Be 'DSCDev'
        }
    }

    It 'Should return null when no VM with the expected name exists' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-AzVM -MockWith {}

            Get-M365DscAgentVm -ProjectName 'DSC' -EnvironmentName 'Dev' |
                Should -BeNullOrEmpty
        }
    }

    It 'Should reject duplicate VM names when neither canonical resource group is present' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-AzVM -MockWith {
                [pscustomobject]@{ Name = 'LcmDSCDev'; ResourceGroupName = 'OtherGroup1' }
                [pscustomobject]@{ Name = 'LcmDSCDev'; ResourceGroupName = 'OtherGroup2' }
            }

            { Get-M365DscAgentVm -ProjectName 'DSC' -EnvironmentName 'Dev' } |
                Should -Throw '*could not uniquely select the canonical or legacy resource group*'
        }
    }
}

Describe 'Connect-M365DscAzure' -Tag Integration {
    BeforeEach {
        Mock -CommandName Connect-AzAccount -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{
                Context = [pscustomobject]@{
                    Subscription = [pscustomobject]@{
                        Name = 'Configured subscription'
                        Id   = '9522bd96-d34f-4910-9667-0517ab5dc595'
                    }
                    Account      = [pscustomobject]@{
                        Id = 'test-application'
                    }
                }
            }
        }
        Mock -CommandName Get-AzAccessToken -ModuleName AzHelpers -MockWith {
            $token = [securestring]::new()
            foreach ($character in 'token'.ToCharArray())
            {
                $token.AppendChar($character)
            }
            $token.MakeReadOnly()

            [pscustomobject]@{
                Token = $token
            }
        }
        Mock -CommandName Connect-MgGraph -ModuleName AzHelpers
        Mock -CommandName Get-MgContext -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{
                TenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
                ClientId = 'test-application'
            }
        }
    }

    It 'Should select the configured subscription when using an application secret' {
        $secret = [securestring]::new()
        foreach ($character in 'secret'.ToCharArray())
        {
            $secret.AppendChar($character)
        }
        $secret.MakeReadOnly()

        Connect-M365DscAzure `
            -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' `
            -SubscriptionId '9522bd96-d34f-4910-9667-0517ab5dc595' `
            -ServicePrincipalId 'test-application' `
            -ServicePrincipalSecret $secret

        Should -Invoke -CommandName Connect-AzAccount -ModuleName AzHelpers -Times 1 -Exactly -ParameterFilter {
            $Tenant -eq 'b246c1af-87ab-41d8-9812-83cd5ff534cb' -and
            $Subscription -eq '9522bd96-d34f-4910-9667-0517ab5dc595' -and
            $ServicePrincipal
        }
    }

    It 'Should select the configured subscription when using a certificate' {
        Connect-M365DscAzure `
            -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' `
            -SubscriptionId '9522bd96-d34f-4910-9667-0517ab5dc595' `
            -ServicePrincipalId 'test-application' `
            -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'

        Should -Invoke -CommandName Connect-AzAccount -ModuleName AzHelpers -Times 1 -Exactly -ParameterFilter {
            $Tenant -eq 'b246c1af-87ab-41d8-9812-83cd5ff534cb' -and
            $Subscription -eq '9522bd96-d34f-4910-9667-0517ab5dc595' -and
            $ApplicationId -eq 'test-application' -and
            $CertificateThumbprint -eq '0123456789ABCDEF0123456789ABCDEF01234567'
        }
    }
}

Describe 'M365Dsc Key Vault naming' {
    It 'Should generate a deterministic Azure-compatible vault name with subscription-specific suffix' {
        $parameters = @{
            ProjectName     = 'Example Project'
            EnvironmentName = 'Development'
            TenantId        = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
            SubscriptionId  = '9522bd96-d34f-4910-9667-0517ab5dc595'
        }

        $name = Get-M365DscKeyVaultName @parameters
        $sameName = Get-M365DscKeyVaultName @parameters
        $generationParameters = $parameters.Clone()
        $generationParameters.Generation = 1
        $newGenerationName = Get-M365DscKeyVaultName @generationParameters
        $differentSubscriptionParameters = $parameters.Clone()
        $differentSubscriptionParameters.SubscriptionId = 'da78bd51-11ab-418d-8222-db661c2aa8d9'
        $differentSubscription = Get-M365DscKeyVaultName @differentSubscriptionParameters

        $name | Should -Be $sameName
        $newGenerationName | Should -Not -Be $name
        $name | Should -Match '^kv-[a-z0-9-]+-[a-f0-9]{8}$'
        $newGenerationName | Should -Match '^kv-[a-z0-9-]+-[a-f0-9]{8}$'
        $name.Length | Should -BeLessThan 25
        $differentSubscription | Should -Not -Be $name
    }

    It 'Should resolve a persisted generated vault name from its credential resource group' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $replacementName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' `
                -SubscriptionId $subscriptionId `
                -Generation 1

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                [pscustomobject]@{
                    ResourceGroupName = 'DSC-Test-credentials-rg'
                    Tags = @{ M365DscKeyVaultName = $replacementName }
                }
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                param($VaultName)

                if ($VaultName)
                {
                    [pscustomobject]@{
                        VaultName               = $VaultName
                        ResourceGroupName       = 'DSC-Test-credentials-rg'
                        EnableRbacAuthorization = $true
                    }
                }
                else
                {
                    [pscustomobject]@{
                        VaultName               = $replacementName
                        ResourceGroupName       = 'DSC-Test-credentials-rg'
                        EnableRbacAuthorization = $null
                    }
                }
            }

            $resolvedName = Resolve-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' `
                -SubscriptionId $subscriptionId

            $resolvedName | Should -Be $replacementName
        }
    }

    It 'Should resolve the newest active RBAC vault when the credential resource group tag is missing' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $tenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
            $resourceGroupName = 'DSC-Test-credentials-rg'
            $replacementName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Generation 2
            $vaults = @(
                [pscustomobject]@{
                    VaultName               = (Get-M365DscKeyVaultName `
                        -ProjectName 'DSC' `
                        -EnvironmentName 'Test' `
                        -TenantId $tenantId `
                        -SubscriptionId $subscriptionId)
                    ResourceGroupName       = $resourceGroupName
                    EnableRbacAuthorization = $false
                }
                [pscustomobject]@{
                    VaultName               = $replacementName
                    ResourceGroupName       = $resourceGroupName
                    EnableRbacAuthorization = $true
                }
            )

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                [pscustomobject]@{ ResourceGroupName = $resourceGroupName; Tags = $null }
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                param($VaultName)

                if ($VaultName)
                {
                    $vaults | Where-Object VaultName -IEQ $VaultName
                }
                else
                {
                    $vaults | ForEach-Object {
                        [pscustomobject]@{
                            VaultName               = $_.VaultName
                            ResourceGroupName       = $_.ResourceGroupName
                            EnableRbacAuthorization = $null
                        }
                    }
                }
            }

            $resolvedName = Resolve-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId

            $resolvedName | Should -Be $replacementName
            Should -Invoke -CommandName Get-AzKeyVault -Times 2 -Exactly -ParameterFilter {
                $VaultName -and $ResourceGroupName -eq $resourceGroupName
            }
        }
    }

    It 'Should generate stable, normalized names for application credential types' {
        Get-M365DscKeyVaultSecretName -IdentityName 'M365DscLcmApplication' -CredentialType pfx-password |
            Should -Be 'm365dsclcmapplication-pfx-password'
    }

    It 'Should generate stable names for project settings credentials' {
        Get-M365DscKeyVaultSecretName -IdentityName 'ProjectSettings' -CredentialType personal-access-token |
            Should -Be 'projectsettings-personal-access-token'
        Get-M365DscKeyVaultSecretName -IdentityName 'ProjectSettings' -CredentialType build-agent-password |
            Should -Be 'projectsettings-build-agent-password'
    }

    It 'Should generate stable Key Vault names for tenant and application metadata' {
        Get-M365DscKeyVaultSecretName -IdentityName '__environment' -CredentialType tenant-id |
            Should -Be 'environment-tenant-id'
        Get-M365DscKeyVaultSecretName -IdentityName 'M365DscLcmApplication' -CredentialType application-id |
            Should -Be 'm365dsclcmapplication-application-id'
        Get-M365DscKeyVaultSecretName -IdentityName 'M365DscExportApplication' -CredentialType certificate-thumbprint |
            Should -Be 'm365dscexportapplication-certificate-thumbprint'
    }

    It 'Should authenticate Key Vault reads with the configured user-assigned managed identity' {
        InModuleScope -ModuleName AzHelpers {
            $previousClientId = $env:AZURE_CLIENT_ID
            $env:AZURE_CLIENT_ID = 'agent-identity-client-id'
            Mock -CommandName Connect-AzAccount
            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{
                    Tenant       = [pscustomobject]@{ Id = 'tenant-id' }
                    Subscription = [pscustomobject]@{ Id = 'subscription-id' }
                }
            }
            Mock -CommandName Get-AzSubscription -MockWith {
                [pscustomobject]@{ Id = 'subscription-id'; State = 'Enabled' }
            }
            Mock -CommandName Set-AzContext

            try
            {
                Connect-M365DscEnvironmentContext -TenantName 'tenant.example' -ManagedIdentity |
                    Should -Not -BeNullOrEmpty
            }
            finally
            {
                if ($null -eq $previousClientId)
                {
                    Remove-Item Env:\AZURE_CLIENT_ID -ErrorAction SilentlyContinue
                }
                else
                {
                    $env:AZURE_CLIENT_ID = $previousClientId
                }
            }

            Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
                $Identity -and $AccountId -eq 'agent-identity-client-id'
            }
        }
    }

    It 'Should pass false to the Key Vault RBAC switch using switch syntax' {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\AutomatedLab\AzHelpers.psm1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match '-DisableRbacAuthorization:\$false'
    }

    It 'Should return the newly generated certificate thumbprint when an app already has a certificate' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-MgContext -MockWith { [pscustomobject]@{} }
            Mock -CommandName Get-MgApplication -MockWith {
                [pscustomobject]@{
                    Id          = 'application-object-id'
                    AppId       = 'application-id'
                    DisplayName = 'TestApp'
                }
            }
            Mock -CommandName New-M365DSCSelfSignedCertificate -MockWith {
                $certificate = [pscustomobject]@{ Thumbprint = 'new-certificate-thumbprint' }
                $certificate | Add-Member -MemberType ScriptMethod -Name Export -Value {
                    param ($Format)
                    [byte[]](1, 2, 3)
                } -PassThru
            }
            Mock -CommandName Update-MgApplication
            Mock -CommandName Get-MgServicePrincipal -MockWith { $null }
            Mock -CommandName New-MgServicePrincipal -MockWith { [pscustomobject]@{ Id = 'service-principal-id' } }
            Mock -CommandName Test-M365DscExchangeOnlineConnection -MockWith { $false }
            Mock -CommandName Get-M365DscIdentity -MockWith {
                [pscustomobject]@{ CertificateThumbprint = 'old-certificate-thumbprint' }
            }

            $identity = New-M365DscIdentity -Name 'TestApp' -GenereateCertificate -PassThru

            $identity.CertificateThumbprint | Should -Be 'new-certificate-thumbprint'
        }
    }
}

Describe 'Project settings Key Vault hydration' {
    It 'Should load the PAT and build-agent password into memory without changing the configured vault environment' {
        InModuleScope -ModuleName AzHelpers {
            $datum = [pscustomobject]@{
                Global = [pscustomobject]@{
                    ProjectSettings = [pscustomobject]@{
                        ProjectName               = 'DSC'
                        CredentialVaultEnvironment = 'Dev'
                        PersonalAccessToken       = '<StoredInKeyVault>'
                        BuildAgents               = [pscustomobject]@{ Password = '<StoredInKeyVault>' }
                    }
                    Azure = [pscustomobject]@{
                        Environments = @{
                            Dev = [pscustomobject]@{
                                AzTenantName     = 'tenant.example'
                                AzSubscriptionId = 'subscription-id'
                            }
                        }
                    }
                }
            }
            Mock -CommandName Connect-M365DscEnvironmentContext -MockWith {
                [pscustomobject]@{
                    Tenant       = [pscustomobject]@{ Id = 'tenant-id' }
                    Subscription = [pscustomobject]@{ Id = 'subscription-id' }
                }
            }
            Mock -CommandName Resolve-M365DscKeyVaultName -MockWith { 'vault-name' }
            Mock -CommandName Test-M365DscKeyVaultSecret -MockWith {
                param($VaultName, $Name)
                $true
            }
            Mock -CommandName Get-M365DscKeyVaultSecret -MockWith {
                param($VaultName, $Name)
                if ($Name -eq 'projectsettings-personal-access-token')
                {
                    return ConvertTo-M365DscSecureString -Value 'test-pat'
                }
                return ConvertTo-M365DscSecureString -Value 'Strong-Passw0rd!'
            }

            $result = Get-M365DscProjectSettingsFromKeyVault -Datum $datum

            $result.Global.ProjectSettings.PersonalAccessToken | Should -Be 'test-pat'
            $result.Global.ProjectSettings.BuildAgents.Password | Should -Be 'Strong-Passw0rd!'
            $result.Global.ProjectSettings.CredentialVaultEnvironment | Should -Be 'Dev'
            Should -Invoke Connect-M365DscEnvironmentContext -Times 1 -Exactly
            Should -Invoke Get-M365DscKeyVaultSecret -Times 2 -Exactly
        }
    }

    It 'Should allow PAT-only consumers without requiring the build-agent password' {
        InModuleScope -ModuleName AzHelpers {
            $datum = [pscustomobject]@{
                Global = [pscustomobject]@{
                    ProjectSettings = [pscustomobject]@{
                        ProjectName                = 'DSC'
                        CredentialVaultEnvironment = 'Dev'
                        PersonalAccessToken        = '<StoredInKeyVault>'
                        BuildAgents                = [pscustomobject]@{ Password = '<StoredInKeyVault>' }
                    }
                    Azure = [pscustomobject]@{
                        Environments = @{
                            Dev = [pscustomobject]@{
                                AzTenantName     = 'tenant.example'
                                AzSubscriptionId = 'subscription-id'
                            }
                        }
                    }
                }
            }
            Mock -CommandName Connect-M365DscEnvironmentContext -MockWith {
                [pscustomobject]@{
                    Tenant       = [pscustomobject]@{ Id = 'tenant-id' }
                    Subscription = [pscustomobject]@{ Id = 'subscription-id' }
                }
            }
            Mock -CommandName Resolve-M365DscKeyVaultName -MockWith { 'vault-name' }
            Mock -CommandName Test-M365DscKeyVaultSecret -MockWith {
                param($VaultName, $Name)
                $Name -eq 'projectsettings-personal-access-token'
            }
            Mock -CommandName Get-M365DscKeyVaultSecret -MockWith {
                param($VaultName, $Name)
                ConvertTo-M365DscSecureString -Value 'test-pat'
            }

            $result = Get-M365DscProjectSettingsFromKeyVault -Datum $datum -CredentialType personal-access-token

            $result.Global.ProjectSettings.PersonalAccessToken | Should -Be 'test-pat'
            $result.Global.ProjectSettings.BuildAgents.Password | Should -Be '<StoredInKeyVault>'
            Should -Invoke Get-M365DscKeyVaultSecret -Times 1 -Exactly
        }
    }
}

Describe 'M365Dsc Key Vault initialization' {
    It 'Should reuse an existing RBAC Key Vault without prompting or deleting resources' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $vaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' `
                -SubscriptionId $subscriptionId
            $vault = [pscustomobject]@{
                VaultName               = $vaultName
                ResourceGroupName       = 'DSC-Test-credentials-rg'
                ResourceId              = "/subscriptions/$subscriptionId/resourceGroups/DSC-Test-credentials-rg/providers/Microsoft.KeyVault/vaults/$vaultName"
                EnableRbacAuthorization = $true
                EnablePurgeProtection   = $true
            }

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceProvider -MockWith {
                [pscustomobject]@{ RegistrationState = 'Registered' }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                [pscustomobject]@{ ResourceGroupName = 'DSC-Test-credentials-rg' }
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                if (-not $InRemovedState)
                {
                    [pscustomobject]@{
                        VaultName               = 'kv-dsc-test-7b72ba00'
                        ResourceGroupName       = 'DSC-Test-credentials-rg'
                        ResourceId              = "/subscriptions/$subscriptionId/resourceGroups/DSC-Test-credentials-rg/providers/Microsoft.KeyVault/vaults/kv-dsc-test-7b72ba00"
                        EnableRbacAuthorization = $true
                        EnablePurgeProtection   = $true
                    }
                }
            }
            Mock -CommandName Remove-AzResourceGroup
            Mock -CommandName Remove-AzKeyVault
            Mock -CommandName New-AzKeyVault
            Mock -CommandName Update-AzKeyVault
            Mock -CommandName Update-AzTag

            $result = Initialize-M365DscKeyVault `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' `
                -SubscriptionId $subscriptionId `
                -Location 'West US 2'

            $result.VaultName | Should -Be $vaultName
            Should -Invoke -CommandName Remove-AzResourceGroup -Times 0 -Exactly
            Should -Invoke -CommandName Remove-AzKeyVault -Times 0 -Exactly
            Should -Invoke -CommandName New-AzKeyVault -Times 0 -Exactly
            Should -Invoke -CommandName Update-AzKeyVault -Times 0 -Exactly
            Should -Invoke -CommandName Update-AzTag -Times 1 -Exactly -ParameterFilter {
                $ResourceId -eq "/subscriptions/$subscriptionId/resourceGroups/DSC-Test-credentials-rg" -and
                $Tag['M365DscKeyVaultName'] -eq $vaultName -and
                $Operation -eq 'Merge' -and
                $Confirm -eq $false
            }
        }
    }

    It 'Should create a new generated vault name instead of recovering a matching soft-deleted vault' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $tenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
            $baseVaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId
            $replacementVaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Generation 1
            $deletedVault = [pscustomobject]@{
                VaultName = $baseVaultName
                Location  = 'West US 2'
            }
            $resourceGroup = [pscustomobject]@{
                ResourceGroupName = 'DSC-Test-credentials-rg'
                Tags = @{}
            }

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceProvider -MockWith {
                [pscustomobject]@{ RegistrationState = 'Registered' }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                $resourceGroup
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                if ($InRemovedState) { $deletedVault }
                elseif ($resourceGroup.Tags['M365DscKeyVaultName'] -eq $replacementVaultName)
                {
                    [pscustomobject]@{
                        VaultName               = $replacementVaultName
                        ResourceGroupName       = 'DSC-Test-credentials-rg'
                        ResourceId              = "/subscriptions/$subscriptionId/resourceGroups/DSC-Test-credentials-rg/providers/Microsoft.KeyVault/vaults/$replacementVaultName"
                        EnableRbacAuthorization = $true
                        EnablePurgeProtection   = $true
                    }
                }
            }
            Mock -CommandName New-AzKeyVault -MockWith {
                [pscustomobject]@{
                    VaultName               = $VaultName
                    ResourceGroupName       = $ResourceGroupName
                    ResourceId              = "/subscriptions/$subscriptionId/resourceGroups/DSC-Test-credentials-rg/providers/Microsoft.KeyVault/vaults/$VaultName"
                    EnableRbacAuthorization = $true
                    EnablePurgeProtection   = $true
                }
            }
            Mock -CommandName Update-AzTag
            Mock -CommandName Undo-AzKeyVaultRemoval

            $result = Initialize-M365DscKeyVault `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Location 'West US 2'

            $result.VaultName | Should -Be $replacementVaultName
            $resourceGroup.Tags['M365DscKeyVaultName'] = $replacementVaultName
            $rerunResult = Initialize-M365DscKeyVault `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Location 'West US 2'

            $rerunResult.VaultName | Should -Be $replacementVaultName
            Should -Invoke -CommandName New-AzKeyVault -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq $replacementVaultName
            }
            Should -Invoke -CommandName Undo-AzKeyVaultRemoval -Times 0 -Exactly
            Should -Invoke -CommandName Update-AzTag -Times 1 -Exactly -ParameterFilter {
                $Tag['M365DscKeyVaultName'] -eq $replacementVaultName -and
                $Confirm -eq $false
            }
        }
    }

    It 'Should replace an active legacy Key Vault with a new RBAC vault without modifying it' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $tenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
            $legacyVaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId
            $replacementVaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Generation 1

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceProvider -MockWith {
                [pscustomobject]@{ RegistrationState = 'Registered' }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                [pscustomobject]@{ ResourceGroupName = 'DSC-Test-credentials-rg'; Tags = @{} }
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                if (-not $InRemovedState)
                {
                    [pscustomobject]@{
                        VaultName               = $legacyVaultName
                        ResourceGroupName       = 'DSC-Test-credentials-rg'
                        EnableRbacAuthorization = $false
                    }
                }
            }
            Mock -CommandName New-AzKeyVault -MockWith {
                [pscustomobject]@{
                    VaultName               = $VaultName
                    ResourceGroupName       = $ResourceGroupName
                    EnableRbacAuthorization = $true
                    EnablePurgeProtection   = $true
                }
            }
            Mock -CommandName Update-AzKeyVault
            Mock -CommandName Update-AzTag
            Mock -CommandName Remove-AzResourceGroup
            Mock -CommandName Remove-AzKeyVault

            $result = Initialize-M365DscKeyVault `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Location 'West US 2'

            $result.VaultName | Should -Be $replacementVaultName
            Should -Invoke -CommandName New-AzKeyVault -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq $replacementVaultName
            }
            Should -Invoke -CommandName Update-AzKeyVault -Times 0 -Exactly
            Should -Invoke -CommandName Remove-AzResourceGroup -Times 0 -Exactly
            Should -Invoke -CommandName Remove-AzKeyVault -Times 0 -Exactly
            Should -Invoke -CommandName Update-AzTag -Times 1 -Exactly -ParameterFilter {
                $Tag['M365DscKeyVaultName'] -eq $replacementVaultName -and
                $Confirm -eq $false
            }
        }
    }

    It 'Should reuse the newest active RBAC generated vault when multiple are in the credential resource group' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $tenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
            $resourceGroupName = 'DSC-Test-credentials-rg'
            $candidateNames = @(
                0..2 | ForEach-Object {
                    Get-M365DscKeyVaultName `
                        -ProjectName 'DSC' `
                        -EnvironmentName 'Test' `
                        -TenantId $tenantId `
                        -SubscriptionId $subscriptionId `
                        -Generation $_
                }
            )
            $activeVaults = @(
                [pscustomobject]@{
                    VaultName               = $candidateNames[1]
                    ResourceGroupName       = $resourceGroupName
                    EnableRbacAuthorization = $true
                    EnablePurgeProtection   = $true
                }
                [pscustomobject]@{
                    VaultName               = $candidateNames[2]
                    ResourceGroupName       = $resourceGroupName
                    EnableRbacAuthorization = $true
                    EnablePurgeProtection   = $true
                }
            )
            $resourceGroup = [pscustomobject]@{
                ResourceGroupName = $resourceGroupName
                Tags = @{}
            }

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceProvider -MockWith {
                [pscustomobject]@{ RegistrationState = 'Registered' }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                $resourceGroup
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                param($VaultName, $InRemovedState)

                if ($InRemovedState)
                {
                    [pscustomobject]@{ VaultName = $candidateNames[0] }
                }
                elseif ($VaultName)
                {
                    $activeVaults | Where-Object VaultName -IEQ $VaultName
                }
                else
                {
                    $activeVaults | ForEach-Object {
                        [pscustomobject]@{
                            VaultName               = $_.VaultName
                            ResourceGroupName       = $_.ResourceGroupName
                            EnableRbacAuthorization = $null
                        }
                    }
                }
            }
            Mock -CommandName Update-AzTag
            Mock -CommandName New-AzKeyVault

            $parameters = @{
                ProjectName     = 'DSC'
                EnvironmentName = 'Test'
                TenantId        = $tenantId
                SubscriptionId  = $subscriptionId
                Location        = 'West US 2'
            }
            $result = Initialize-M365DscKeyVault @parameters
            $resourceGroup.Tags['M365DscKeyVaultName'] = $candidateNames[0]
            $rerunResult = Initialize-M365DscKeyVault @parameters

            $result.VaultName | Should -Be $candidateNames[2]
            $rerunResult.VaultName | Should -Be $candidateNames[2]
            Should -Invoke -CommandName New-AzKeyVault -Times 0 -Exactly
            Should -Invoke -CommandName Update-AzTag -Times 2 -Exactly -ParameterFilter {
                $Tag['M365DscKeyVaultName'] -eq $candidateNames[2] -and
                $Confirm -eq $false
            }
        }
    }

    It 'Should skip a generated vault name already active in another resource group' {
        InModuleScope -ModuleName AzHelpers {
            $subscriptionId = '9522bd96-d34f-4910-9667-0517ab5dc595'
            $tenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb'
            $resourceGroupName = 'DSC-Test-credentials-rg'
            $baseVaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId
            $replacementVaultName = Get-M365DscKeyVaultName `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Generation 1
            $activeVault = [pscustomobject]@{
                VaultName               = $baseVaultName
                ResourceGroupName       = 'Other-credentials-rg'
                EnableRbacAuthorization = $true
                EnablePurgeProtection   = $true
            }

            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscriptionId } }
            }
            Mock -CommandName Get-AzResourceProvider -MockWith {
                [pscustomobject]@{ RegistrationState = 'Registered' }
            }
            Mock -CommandName Get-AzResourceGroup -MockWith {
                [pscustomobject]@{ ResourceGroupName = $resourceGroupName; Tags = @{} }
            }
            Mock -CommandName Get-AzKeyVault -MockWith {
                if (-not $InRemovedState) { $activeVault }
            }
            Mock -CommandName New-AzKeyVault -MockWith {
                [pscustomobject]@{
                    VaultName               = $VaultName
                    ResourceGroupName       = $ResourceGroupName
                    EnableRbacAuthorization = $true
                    EnablePurgeProtection   = $true
                }
            }
            Mock -CommandName Update-AzTag

            $result = Initialize-M365DscKeyVault `
                -ProjectName 'DSC' `
                -EnvironmentName 'Test' `
                -TenantId $tenantId `
                -SubscriptionId $subscriptionId `
                -Location 'West US 2'

            $result.VaultName | Should -Be $replacementVaultName
            Should -Invoke -CommandName New-AzKeyVault -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq $replacementVaultName
            }
        }
    }
}
Describe 'M365Dsc Key Vault access grants' {
    It 'Should grant the required secret permissions without switching legacy vaults to RBAC' {
        InModuleScope -ModuleName AzHelpers {
            $vault = [pscustomobject]@{
                VaultName               = 'kv-test'
                ResourceGroupName       = 'credentials-rg'
                ResourceId              = '/subscriptions/test/resourceGroups/credentials-rg/providers/Microsoft.KeyVault/vaults/kv-test'
                EnableRbacAuthorization = $true
                AccessPolicies          = @()
            }

            Mock -CommandName Get-AzRoleAssignment -MockWith {
                [pscustomobject]@{ RoleDefinitionName = 'Key Vault Secrets Officer' }
            }
            Mock -CommandName Get-AzKeyVault -MockWith { $vault }
            Mock -CommandName Get-AzResource -MockWith {
                [pscustomobject]@{
                    Properties = [pscustomobject]@{ EnableRbacAuthorization = $false }
                }
            }
            Mock -CommandName Set-AzKeyVaultAccessPolicy
            Mock -CommandName New-AzRoleAssignment

            Ensure-M365DscKeyVaultRoleAssignment `
                -VaultResourceId $vault.ResourceId `
                -PrincipalId 'service-principal-object-id' `
                -RoleDefinitionName 'Key Vault Secrets Officer'

            Should -Invoke -CommandName Set-AzKeyVaultAccessPolicy -Times 1 -Exactly -ParameterFilter {
                $ObjectId -eq 'service-principal-object-id' -and
                $VaultName -eq 'kv-test' -and
                'Get' -in $PermissionsToSecrets -and
                'List' -in $PermissionsToSecrets -and
                'Set' -in $PermissionsToSecrets
            }
            Should -Invoke -CommandName New-AzRoleAssignment -Times 0 -Exactly
            Should -Invoke -CommandName Get-AzRoleAssignment -Times 0 -Exactly
        }
    }

    It 'Should assign the secret role using the ARM RBAC setting' {
        InModuleScope -ModuleName AzHelpers {
            $vault = [pscustomobject]@{
                VaultName               = 'kv-test'
                ResourceGroupName       = 'credentials-rg'
                ResourceId              = '/subscriptions/test/resourceGroups/credentials-rg/providers/Microsoft.KeyVault/vaults/kv-test'
                EnableRbacAuthorization = $false
                AccessPolicies          = @()
            }

            Mock -CommandName Get-AzRoleAssignment
            Mock -CommandName Get-AzKeyVault -MockWith { $vault }
            Mock -CommandName Get-AzResource -MockWith {
                [pscustomobject]@{
                    Properties = [pscustomobject]@{ EnableRbacAuthorization = $true }
                }
            }
            Mock -CommandName New-AzRoleAssignment
            Mock -CommandName Set-AzKeyVaultAccessPolicy

            Ensure-M365DscKeyVaultRoleAssignment `
                -VaultResourceId $vault.ResourceId `
                -PrincipalId 'service-principal-object-id' `
                -RoleDefinitionName 'Key Vault Secrets Officer'

            Should -Invoke -CommandName New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter {
                $ObjectId -eq 'service-principal-object-id' -and
                $Scope -eq '/subscriptions/test/resourceGroups/credentials-rg' -and
                $RoleDefinitionName -eq 'Reader'
            }
            Should -Invoke -CommandName New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter {
                $ObjectId -eq 'service-principal-object-id' -and
                $Scope -eq $vault.ResourceId -and
                $RoleDefinitionName -eq 'Key Vault Secrets Officer'
            }
            Should -Invoke -CommandName Set-AzKeyVaultAccessPolicy -Times 0 -Exactly
        }
    }
}

Describe 'Get-M365DscIdentity' {
    It 'Should translate Graph authentication errors without binding their type' {
        InModuleScope -ModuleName AzHelpers {
            $authenticationExceptionType = [AppDomain]::CurrentDomain.GetAssemblies() |
                ForEach-Object { $_.GetType('Microsoft.Graph.PowerShell.AuthenticationException', $false) } |
                Where-Object { $null -ne $_ } |
                Select-Object -First 1

            $authenticationException = [Activator]::CreateInstance(
                $authenticationExceptionType,
                @('Graph authentication failed', [System.Exception]::new('Not authenticated'))
            )
            Mock -CommandName Get-MgApplication -MockWith {
                throw $authenticationException
            }

            $errorRecord = $null
            try
            {
                Get-M365DscIdentity -Name 'TestApp'
            }
            catch
            {
                $errorRecord = $_
            }

            $errorRecord | Should -Not -BeNull
            $errorRecord.ErrorDetails.Message | Should -Be "You are not connected to the Microsoft Graph. Please run 'Connect-M365Dsc'."
        }
    }

    It 'Should preserve non-authentication Graph errors' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-MgApplication -MockWith {
                throw [System.InvalidOperationException]::new('Graph API unavailable')
            }

            { Get-M365DscIdentity -Name 'TestApp' } | Should -Throw '*Graph API unavailable*'
        }
    }
}

Describe 'Test-M365DscExchangeOnlineLicense' -Tag Integration {
    BeforeEach {
        Mock -CommandName Get-MgContext -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{ TenantId = 'b246c1af-87ab-41d8-9812-83cd5ff534cb' }
        }
        Mock -CommandName Get-MgServicePrincipal -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{ AppId = '00000002-0000-0ff1-ce00-000000000000'; AccountEnabled = $true }
        }
        Mock -CommandName Get-MgSubscribedSku -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{
                ServicePlans = @(
                    [pscustomobject]@{ ServicePlanName = 'EXCHANGE_S_FOUNDATION'; ProvisioningStatus = 'Success' }
                    [pscustomobject]@{ ServicePlanName = 'EXCHANGE_S_ENTERPRISE'; ProvisioningStatus = 'Success' }
                )
            }
        }
    }

    It 'Should report a licensed tenant' {
        Test-M365DscExchangeOnlineLicense | Should -BeTrue
    }

    It 'Should report an unlicensed tenant when the Exchange Online service principal is disabled' {
        # This is the state of a tenant whose Microsoft 365 subscription has lapsed.
        Mock -CommandName Get-MgServicePrincipal -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{ AppId = '00000002-0000-0ff1-ce00-000000000000'; AccountEnabled = $false }
        }

        Test-M365DscExchangeOnlineLicense | Should -BeFalse
    }

    It "Should report an unlicensed tenant when only 'EXCHANGE_S_FOUNDATION' is provisioned" {
        # 'EXCHANGE_S_FOUNDATION' ships with almost every SKU and grants no Exchange Online mailbox.
        Mock -CommandName Get-MgSubscribedSku -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{
                ServicePlans = @(
                    [pscustomobject]@{ ServicePlanName = 'EXCHANGE_S_FOUNDATION'; ProvisioningStatus = 'Success' }
                )
            }
        }

        Test-M365DscExchangeOnlineLicense | Should -BeFalse
    }
}

Describe 'Connect-M365Dsc' -Tag Integration {
    BeforeEach {
        Mock -CommandName Disconnect-M365Dsc -ModuleName AzHelpers
        Mock -CommandName Connect-M365DscAzure -ModuleName AzHelpers
        Mock -CommandName Connect-M365DscExchangeOnline -ModuleName AzHelpers
    }

    It 'Should connect to Exchange Online when the tenant is licensed for it' {
        Mock -CommandName Test-M365DscExchangeOnlineLicense -ModuleName AzHelpers -MockWith { $true }

        Connect-M365Dsc -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' -TenantName 'contoso.onmicrosoft.com'

        Should -Invoke -CommandName Connect-M365DscExchangeOnline -ModuleName AzHelpers -Times 1 -Exactly
    }

    It 'Should fail when Exchange Online is expected but the tenant is not licensed for it' {
        Mock -CommandName Test-M365DscExchangeOnlineLicense -ModuleName AzHelpers -MockWith { $false }

        { Connect-M365Dsc -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' -TenantName 'contoso.onmicrosoft.com' } |
            Should -Throw "*is not licensed for Exchange Online*"

        Should -Invoke -CommandName Connect-M365DscAzure -ModuleName AzHelpers -Times 1 -Exactly
        Should -Invoke -CommandName Connect-M365DscExchangeOnline -ModuleName AzHelpers -Times 0 -Exactly
    }

    It 'Should not test the license when Exchange Online is skipped by the configuration' {
        Mock -CommandName Test-M365DscExchangeOnlineLicense -ModuleName AzHelpers -MockWith { $true }

        Connect-M365Dsc -TenantId 'b246c1af-87ab-41d8-9812-83cd5ff534cb' -TenantName 'contoso.onmicrosoft.com' -SkipExchangeOnline

        Should -Invoke -CommandName Test-M365DscExchangeOnlineLicense -ModuleName AzHelpers -Times 0 -Exactly
        Should -Invoke -CommandName Connect-M365DscExchangeOnline -ModuleName AzHelpers -Times 0 -Exactly
    }
}

Describe 'Disconnect-M365Dsc' -Tag Integration {
    BeforeEach {
        Mock -CommandName Test-M365DscExchangeOnlineConnection -ModuleName AzHelpers -MockWith { $false }
        Mock -CommandName Disconnect-MgGraph -ModuleName AzHelpers
        Mock -CommandName Clear-AzContext -ModuleName AzHelpers
    }

    It 'Should clear the Azure context when Disconnect-AzAccount hits the MSAL assembly conflict' {
        # Verbatim error of Az.Accounts 5.3.2 running next to Microsoft.Graph.Authentication 2.35.1.
        Mock -CommandName Disconnect-AzAccount -ModuleName AzHelpers -MockWith {
            throw [System.MissingMethodException]::new("Method not found: 'Void Microsoft.Identity.Client.Extensions.Msal.MsalCacheHelper.RegisterCache(Microsoft.Identity.Client.ITokenCache)'.")
        }

        Disconnect-M365Dsc -WarningAction SilentlyContinue

        Should -Invoke -CommandName Clear-AzContext -ModuleName AzHelpers -Times 1 -Exactly -ParameterFilter {
            $Scope -eq 'Process' -and $Force
        }
    }

    It 'Should not swallow an unrelated Disconnect-AzAccount error' {
        Mock -CommandName Disconnect-AzAccount -ModuleName AzHelpers -MockWith {
            throw [System.InvalidOperationException]::new('The credentials could not be found.')
        }

        Disconnect-M365Dsc -ErrorAction SilentlyContinue -ErrorVariable disconnectError

        $disconnectError[0].Exception.Message | Should -BeLike '*The credentials could not be found.*'
        Should -Invoke -CommandName Clear-AzContext -ModuleName AzHelpers -Times 0 -Exactly
    }
}

Describe 'Add-M365DscIdentityPermission' -Tag Integration {    It 'Should skip the Exchange role groups when Exchange Online is not connected' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Test-M365DscExchangeOnlineConnection -MockWith { $false }
            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $null } }
            }
            Mock -CommandName Get-M365DSCCompiledPermissionList2 -MockWith {
                @(
                    [pscustomobject]@{ ApiRoleId = 'roleId1'; ApiAppId = 'apiAppId'; ApiPermissionName = 'Test.Read.All' }
                    [pscustomobject]@{ ApiRoleId = 'roleId2'; ApiAppId = 'apiAppId'; ApiPermissionName = 'Test.Write.All' }
                )
            }
            Mock -CommandName Get-GraphPermission -MockWith {
                [pscustomobject]@{ ApiRoleId = 'roleId3'; ApiAppId = 'apiAppId'; ApiPermissionName = 'AppRoleAssignment.ReadWrite.All' }
            }
            Mock -CommandName Get-ServicePrincipalAppPermissions -MockWith {
                @(
                    [pscustomobject]@{ ApiRoleId = 'roleId1'; ApiAppId = 'apiAppId'; ApiPermissionName = 'Test.Read.All' }
                    [pscustomobject]@{ ApiRoleId = 'roleId2'; ApiAppId = 'apiAppId'; ApiPermissionName = 'Test.Write.All' }
                )
            }
            Mock -CommandName Set-ServicePrincipalAppPermissions
            Mock -CommandName Get-MgDirectoryRole -MockWith { [pscustomobject]@{ DisplayName = 'Global Reader' } }
            Mock -CommandName Get-MgServicePrincipal -MockWith { [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000002' } }
            Mock -CommandName Get-MgRoleManagementDirectoryRoleDefinition -MockWith { $null }

            $identity = [M365DscIdentity]::new('TestApp', 'objectId', 'appId', '00000000-0000-0000-0000-000000000001', $null, [M365DscIdentityType]::Application)

            # 'Get-RoleGroup' and 'Add-RoleGroupMember' only exist while Exchange Online is connected,
            # so reaching the Exchange role group block would raise a CommandNotFoundException.
            { Add-M365DscIdentityPermission -Identity $identity -AccessType Update } | Should -Not -Throw
        }
    }
}

Describe 'Resolve-M365DscAzureMfaChallenge' -Tag Integration {
    BeforeEach {
        Mock -CommandName Connect-AzAccount -ModuleName AzHelpers
        Mock -CommandName Get-AzContext -ModuleName AzHelpers -MockWith {
            [pscustomobject]@{
                Tenant       = [pscustomobject]@{ Id = 'b246c1af-87ab-41d8-9812-83cd5ff534cb' }
                Subscription = [pscustomobject]@{ Id = '9522bd96-d34f-4910-9667-0517ab5dc595' }
            }
        }
    }

    It 'Should replay the claims challenge of an MFA error' {
        # Verbatim text of the Remove-AzRoleAssignment failure this test guards against.
        $mfaErrorMessage = @'
Resource '00000000-0000-0000-0000-000000000001' was disallowed by Azure: You are receiving this error because you tried to create, update or delete Azure resources without authenticating through MFA.
User accounts must be authenticated through MFA to manage your resources. To resolve this error, go to https://aka.ms/MFAforAzure.  Run the cmdlet below to authenticate interactively; additional
parameters may be added as needed.  Connect-AzAccount -Tenant (Get-AzContext).Tenant.Id -ClaimsChallenge "eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19"
'@

        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($mfaErrorMessage), 'Disallowed', 'PermissionDenied', $null)

        Resolve-M365DscAzureMfaChallenge -ErrorRecord $errorRecord | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -ModuleName AzHelpers -Times 1 -Exactly -ParameterFilter {
            $Tenant -eq 'b246c1af-87ab-41d8-9812-83cd5ff534cb' -and
            $Subscription -eq '9522bd96-d34f-4910-9667-0517ab5dc595' -and
            $ClaimsChallenge -eq 'eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19'
        }
    }

    It 'Should not re-authenticate for an unrelated error' {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('The role assignment does not exist.'), 'NotFound', 'ObjectNotFound', $null)

        Resolve-M365DscAzureMfaChallenge -ErrorRecord $errorRecord | Should -BeFalse

        Should -Invoke -CommandName Connect-AzAccount -ModuleName AzHelpers -Times 0 -Exactly
    }
}

Describe 'Remove-M365DscIdentityPermission' -Tag Integration {
    It 'Should stop when the Azure role assignment lookup fails' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Get-AzRoleAssignment -MockWith { throw 'Azure role assignment lookup failed' }

            $identity = [M365DscIdentity]::new('TestApp', 'objectId', 'appId', '00000000-0000-0000-0000-000000000001', 'exchangeId', [M365DscIdentityType]::Application)

            { Remove-M365DscIdentityPermission -Identity $identity -SkipGraphApiPermissions } |
                Should -Throw 'Azure role assignment lookup failed'
        }
    }

    It 'Should retry the Owner role removal after replaying the claims challenge' {
        InModuleScope -ModuleName AzHelpers {
            $mfaErrorMessage = 'Resource was disallowed by Azure: You are receiving this error because you tried to create, update or delete Azure resources without authenticating through MFA.  Connect-AzAccount -Tenant (Get-AzContext).Tenant.Id -ClaimsChallenge "eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19"'

            Mock -CommandName Get-AzRoleAssignment -MockWith { [pscustomobject]@{ RoleDefinitionName = 'Owner' } }
            Mock -CommandName Connect-AzAccount
            Mock -CommandName Get-AzContext -MockWith {
                [pscustomobject]@{
                    Tenant       = [pscustomobject]@{ Id = 'b246c1af-87ab-41d8-9812-83cd5ff534cb' }
                    Subscription = [pscustomobject]@{ Id = '9522bd96-d34f-4910-9667-0517ab5dc595' }
                }
            }

            $script:removeAttempt = 0
            Mock -CommandName Remove-AzRoleAssignment -MockWith {
                $script:removeAttempt++
                if ($script:removeAttempt -eq 1)
                {
                    throw $mfaErrorMessage
                }
            }

            # The function walks on into the Graph and Exchange Online blocks, which this test does not cover.
            Mock -CommandName Get-MgServicePrincipal -MockWith { throw 'end of the tested path' }

            $identity = [M365DscIdentity]::new('TestApp', 'objectId', 'appId', '00000000-0000-0000-0000-000000000001', 'exchangeId', [M365DscIdentityType]::Application)

            { Remove-M365DscIdentityPermission -Identity $identity -SkipGraphApiPermissions } |
                Should -Throw 'end of the tested path'

            Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
                $ClaimsChallenge -eq 'eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19'
            }
            Should -Invoke -CommandName Remove-AzRoleAssignment -Times 2 -Exactly
        }
    }
}

Describe 'Exchange Online entitlement in the lab scripts' -Tag Integration {
    BeforeDiscovery {
        $connectingLabScripts = Get-ChildItem -Path $PSScriptRoot\..\..\lab -Filter *.ps1 -Recurse | Where-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({
                    param ($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Connect-M365Dsc'
                }, $true)
        } | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    }

    It "'<Name>' passes the 'HasExchangeOnline' setting on to 'Connect-M365Dsc'" -ForEach $connectingLabScripts {
        # A script that connects without the switch fails on a tenant configured with
        # 'HasExchangeOnline: false', because Connect-M365Dsc then demands the entitlement.
        $content = Get-Content -Path $Path -Raw

        $content | Should -Match 'HasExchangeOnline'
        $content | Should -Match 'SkipExchangeOnline'
    }

    It "'10 Setup App Registrations.ps1' passes the Exchange Online setting to its connection test" {
        $paths = @(
            "$PSScriptRoot\..\..\lab\Azure\10 Setup App Registrations.ps1"
            "$PSScriptRoot\..\..\lab\AutomatedLab\10 Setup App Registrations.ps1"
        )
        foreach ($path in $paths)
        {
            $content = Get-Content -Path $path -Raw

            $content | Should -Match '\$tenantId\s*=\s*\[string\]\$context\.Tenant\.Id'
            $content | Should -Match '\$subscriptionId\s*=\s*\[string\]\$context\.Subscription\.Id'
            $content | Should -Not -Match '\$environment\.Az(?:Tenant|Subscription)Id\s*='
            $content | Should -Match '\$skipExchangeOnline\s*=\s*\$environment\.HasExchangeOnline\s*-eq\s*\$false'
            $content | Should -Match '(?s)Test-M365DscConnection `\s*-TenantId \$tenantId `\s*-SubscriptionId \$subscriptionId `\s*-SkipExchangeOnline:\$skipExchangeOnline'
        }
    }

    It "'10 Setup App Registrations.ps1' stops if Key Vault initialization fails" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\AutomatedLab\10 Setup App Registrations.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match '(?s)\$vault\s*=\s*Initialize-M365DscKeyVault.*?-EnvironmentName\s+\(\[string\]\$environmentName\).*?-ErrorAction Stop\s*if\s*\(\$null -eq \$vault\)\s*\{\s*throw'
    }
}

Describe 'Azure DevOps project setup Git failures' {
    It 'Stops when either local-change push fails' {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\AutomatedLab\20 Configure AzDo Project.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match '(?s)git push\s+if\s*\(\$LASTEXITCODE -ne 0\)\s*\{\s*throw'
        $content | Should -Match '(?s)git -C \$repositoryRoot push\s+if\s*\(\$LASTEXITCODE -ne 0\)\s*\{\s*throw'
    }
}

Describe 'Pipeline environment selection parameters' -Tag Integration {
    It 'Uses committed pipeline parameters for the matrix without reading Azure.yml' {
        $repositoryRoot = (Resolve-Path -Path "$PSScriptRoot\..\..").Path
        $pipelinesPath = Join-Path -Path $repositoryRoot -ChildPath 'pipelines'
        $pipelineFiles = @(
            Get-ChildItem -Path $pipelinesPath -Filter *.yml |
                Where-Object Name -In 'build.yml', 'export.yml', 'push.yml', 'reapply.yml', 'test.yml'
            Get-Item -Path (Join-Path -Path $pipelinesPath -ChildPath 'Troubleshooting\winrmDiagnostics.yml')
        )

        $matrixScriptPath = Join-Path -Path $pipelinesPath -ChildPath 'scripts\GetBuildEnvironmentMatrix.ps1'
        $matrixScript = Get-Content -Path $matrixScriptPath -Raw
        $matrixScript | Should -Match '\$env:SELECTED_ENVIRONMENTS'
        $matrixScript | Should -Not -Match 'Azure\.yml'

        foreach ($pipelineFile in $pipelineFiles)
        {
            $pipeline = Get-Content -Path $pipelineFile.FullName -Raw | ConvertFrom-Yaml -ErrorAction Stop
            $environmentParameter = @($pipeline.parameters | Where-Object name -EQ 'environments')

            $environmentParameter | Should -HaveCount 1
            $environmentParameter[0].type | Should -Be 'stringList'
            @($environmentParameter[0].values) | Should -Not -BeNullOrEmpty
            (@($environmentParameter[0].values | Sort-Object) -join ',') |
                Should -Be (@($environmentParameter[0].default | Sort-Object) -join ',')
        }

        $previousSelection = $env:SELECTED_ENVIRONMENTS
        try
        {
            $env:SELECTED_ENVIRONMENTS = 'Dev,Test'
            $output = & $matrixScriptPath 6>&1 | Out-String
            $matrixMatch = [regex]::Match($output, 'variable=buildEnvironmentMatrix;isOutput=true\](?<json>\{[^\r\n]+\})')

            $matrixMatch.Success | Should -BeTrue
            $matrix = ConvertFrom-Json -InputObject $matrixMatch.Groups['json'].Value -ErrorAction Stop
            $matrix.Environment0.BuildEnvironment | Should -Be 'Dev'
            $matrix.Environment1.BuildEnvironment | Should -Be 'Test'
        }
        finally
        {
            $env:SELECTED_ENVIRONMENTS = $previousSelection
        }
    }

    It 'Builds and applies the DSC configuration before validating deployment' {
        $pipelinePath = (Resolve-Path -Path "$PSScriptRoot\..\..\pipelines\test.yml").Path
        $pipeline = Get-Content -Path $pipelinePath -Raw | ConvertFrom-Yaml -ErrorAction Stop
        $stageTemplates = @($pipeline.stages | ForEach-Object { Split-Path -Path $_.template -Leaf })

        $stageTemplates | Should -Be @(
            'environmentMatrixTemplate.yml',
            'buildTemplate.yml',
            'startDscTemplate.yml',
            'testDscTemplate.yml'
        )

        $testStage = $pipeline.stages | Where-Object { $_.template -eq 'testDscTemplate.yml' }
        $testStage.parameters.validateDeployment | Should -BeTrue
        $testStage.parameters.dependsOnStage | Should -Be 'StartConfiguration'
    }

    It 'Initializes pinned DSC modules in the deployment job before applying the MOF' {
        $templatePath = (Resolve-Path -Path "$PSScriptRoot\..\..\pipelines\startDscTemplate.yml").Path
        $template = Get-Content -Path $templatePath -Raw | ConvertFrom-Yaml -ErrorAction Stop
        $steps = @($template.stages[0].jobs[0].steps)
        $initializeIndex = -1
        $deployIndex = -1

        for ($index = 0; $index -lt $steps.Count; $index++)
        {
            if ($steps[$index].name -eq 'initializeModules')
            {
                $initializeIndex = $index
            }
            if ($steps[$index].name -eq 'deploy')
            {
                $deployIndex = $index
            }
        }

        $initializeIndex | Should -BeGreaterOrEqual 0
        $deployIndex | Should -BeGreaterThan $initializeIndex
        $steps[$initializeIndex].inputs.filePath | Should -Be './build.ps1'
        $steps[$initializeIndex].inputs.arguments | Should -Be '-ResolveDependency -Tasks InitializeModuleFolder'
        $steps[$initializeIndex].inputs.pwsh | Should -BeTrue
    }

    It 'Displays accurate live pipeline progress and retries transient monitoring errors' {
        $scriptPath = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\41 Run Pipelines In Parallel.ps1").Path
        $content = Get-Content -Path $scriptPath -Raw

        $content | Should -Match '\$progressLines = foreach \(\$pipelineRun in \$pipelineRuns\)'
        $content | Should -Match '\$progressLines -join "`n"'
        $content | Should -Match 'Write-Host "`nPipelines \[\$completedRuns/\$totalRuns completed\]" -ForegroundColor Cyan'
        $content | Should -Not -Match "Write-Progress -Activity 'Pipelines'"
        $content | Should -Match 'Write-Host "  \$progressLine"'
        $content | Should -Not -Match "-join ' \| '"
        $content | Should -Match '\$pipelineRun\.MonitorFailures\+\+'
        $content | Should -Match "keeping its last known state"
        $content | Should -Match '\$deferredDeltaReport\.State = ''skipped'''
        $content | Should -Not -Match 'monitor-failed|queue-failed'
    }

    It 'Runs the build runtime preflight after restoring modules in build and export pipelines' {
        $repositoryRoot = (Resolve-Path -Path "$PSScriptRoot\..\..").Path
        foreach ($templateName in 'buildTemplate.yml', 'exportDscTemplate.yml')
        {
            $templatePath = Join-Path -Path $repositoryRoot -ChildPath "pipelines\$templateName"
            $template = Get-Content -Path $templatePath -Raw | ConvertFrom-Yaml -ErrorAction Stop
            $steps = @($template.stages[0].jobs[0].steps)
            $restoreIndex = -1
            $preflightIndex = -1
            for ($index = 0; $index -lt $steps.Count; $index++)
            {
                if ($steps[$index].name -in 'clean', 'InitializeModuleFolder')
                {
                    $restoreIndex = $index
                }
                if ($steps[$index].name -eq 'runtimePreflight')
                {
                    $preflightIndex = $index
                }
            }

            $restoreIndex | Should -BeGreaterOrEqual 0
            $preflightIndex | Should -BeGreaterThan $restoreIndex
            $steps[$preflightIndex].inputs.filePath | Should -Be './pipelines/scripts/TestBuildRuntime.ps1'
            if ($templateName -eq 'exportDscTemplate.yml')
            {
                $steps[$preflightIndex].inputs.arguments | Should -Be '-IncludeExchangeOnlineManagement'
            }
        }
    }
}

Describe 'Transient PowerShell Gallery restore failures' -Tag Integration {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\.build\PSResourceRetry.ps1')
    }

    BeforeEach {
        $script:saveResourceAttempts = 0
        $script:retryDelays = @()
        $script:retryStatusMessages = @()
    }

    It 'Retries 503 responses with backoff and visible attempt status' {
        Mock Save-PSResource {
            $script:saveResourceAttempts++
            if ($script:saveResourceAttempts -lt 3)
            {
                throw [System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 503 (Service Unavailable).')
            }
        }
        Mock Start-Sleep { $script:retryDelays += $Seconds }
        Mock Get-Random { 0 }
        Mock Write-Host { $script:retryStatusMessages += [string]$Object }

        Invoke-SavePSResourceWithRetry -Parameters @{ Name = 'TestModule' } -ModuleName 'TestModule' -RetryCount 2

        $script:saveResourceAttempts | Should -Be 3
        $script:retryDelays | Should -Be @(5, 10)
        ($script:retryStatusMessages -join "`n") | Should -Match "attempt 1/3"
        ($script:retryStatusMessages -join "`n") | Should -Match "Retrying 'TestModule' in 5 second\(s\); next attempt is 2/3"
    }

    It 'Does not retry permanent package errors' {
        Mock Save-PSResource {
            $script:saveResourceAttempts++
            throw [System.InvalidOperationException]::new('Module was not found (404).')
        }
        Mock Start-Sleep { $script:retryDelays += $Seconds }

        { Invoke-SavePSResourceWithRetry -Parameters @{ Name = 'TestModule' } -ModuleName 'TestModule' -RetryCount 2 } |
            Should -Throw '*Module was not found*'

        $script:saveResourceAttempts | Should -Be 1
        $script:retryDelays | Should -BeNullOrEmpty
    }

    It 'Fails with a clear error after transient retries are exhausted' {
        Mock Save-PSResource {
            $script:saveResourceAttempts++
            throw [System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 503 (Service Unavailable).')
        }
        Mock Start-Sleep { $script:retryDelays += $Seconds }
        Mock Get-Random { 0 }

        { Invoke-SavePSResourceWithRetry -Parameters @{ Name = 'TestModule' } -ModuleName 'TestModule' -RetryCount 1 } |
            Should -Throw '*after 2 attempts*'

        $script:saveResourceAttempts | Should -Be 2
        $script:retryDelays | Should -Be @(5)
    }
}

Describe 'Build agent identity in the lab scripts' -Tag Integration {
    It "'30 Create Agent VMs.ps1' creates the build agent identity as a managed identity" {
        # Without '-OnlyServicePrincipals' the function registers an application of the same
        # display name next to the managed identity created by 'New-AzUserAssignedIdentity'.
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\30 Create Agent VMs.ps1").Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

        $calls = $ast.FindAll({
                param ($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'New-M365DscIdentity'
            }, $true)

        $calls | Should -HaveCount 1
        $calls.CommandElements.ParameterName | Should -Contain 'OnlyServicePrincipals'
    }
}

Describe 'Build agent software installation in the lab scripts' -Tag Integration {
    BeforeAll {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

        # Covers quoted paths and bare command names alike.
        $script:literals = $script:ast.FindAll({
                param ($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true).Value
    }

    It "'31 Agent Setup.ps1' does not download the agent from the retired Azure CDN" {
        # 'vstsagentpackage.azureedge.net' no longer resolves, so the download failed with
        # 'No such host is known'. Chocolatey pulls the agent from download.agent.dev.azure.com.
        $script:literals | Where-Object { $_ -match 'vstsagentpackage\.azureedge\.net' } | Should -BeNullOrEmpty
    }

    It "'31 Agent Setup.ps1' does not call the lab sources script at a hard-coded path" {
        # AutomatedLab writes 'AzureLabSources.ps1' below '$AL_DeployDebugFolder\AL', which expands
        # to '%APPDATA%\DeployDebug\AL' and not to the legacy 'C:\AL'.
        $script:literals | Where-Object { $_ -match 'AzureLabSources\.ps1' } | Should -BeNullOrEmpty
    }

    It "'31 Agent Setup.ps1' upgrades PowerShell when it is below the pinned version" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match "\`$requiredPowerShellVersion = \[version\]'7\.6\.10'"
        $content | Should -Match '(?s)\$installedPowerShellVersion -lt \$requiredPowerShellVersion.*?choco install powershell-core --version \$requiredPowerShellVersionString.*?--force'
    }

    It "'31 Agent Setup.ps1' reports the installed PowerShell and .NET runtime versions" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match '\$PSVersionTable\.PSVersion'
        $content | Should -Match '\[System\.Runtime\.InteropServices\.RuntimeInformation\]::FrameworkDescription'
        $content | Should -Match "\`$runtimeVersion = & \`$pwsh .*?-Command '\`$PSVersionTable\.PSVersion\.ToString\(\)'"
        $content | Should -Match "\`$runtimeFramework = & \`$pwsh .*?-Command '\[System\.Runtime\.InteropServices\.RuntimeInformation\]::FrameworkDescription'"
        $content | Should -Match "\`$runtimeHome = & \`$pwsh .*?-Command '\`$PSHOME'"
    }

    It "'31 Agent Setup.ps1' recreates the PowerShell.7 remoting endpoint after a runtime upgrade" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match '(?s)Unregister-PSSessionConfiguration -Name PowerShell\.7.*?Enable-PSRemoting -Force.*?Restart-Service -Name WinRM.*?New-PSSession -ComputerName localhost -ConfigurationName PowerShell\.7'
    }

    It "'31 Agent Setup.ps1' never writes tenant metadata or credentials to Azure.yml" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'Update-M365DscDatumFromKeyVault'
        $content | Should -Match "SetEnvironmentVariable\('AZURE_CLIENT_ID', \`$ManagedIdentityClientId, 'Machine'\)"
        $content | Should -Not -Match '(?i)source\\Global\\Azure\.yml|azureConfigPath|git add.*Azure\.yml|git push'
    }

    It "'31 Agent Setup.ps1' polls asynchronous Run Command completion" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match '(?s)AsyncExecution\s+= \$true.*?Set-AzVMRunCommand @runCommandParameters.*?Get-AzVMRunCommand.*?-Expand InstanceView.*?InstanceView\.ExecutionState'
        $content | Should -Match 'runCommandParameters\.ProtectedParameter'
        $content | Should -Match 'checking every 5 seconds'
        $content | Should -Match 'still \$reportedState'
        $content | Should -Match 'TimeoutInSecond\s+= \$TimeoutInSeconds'
        $content | Should -Match 'TimeoutInSeconds 600'
    }

    It "'31 Agent Setup.ps1' does not download PowerShellGet when the built-in module is available" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'Get-Module -Name PowerShellGet -ListAvailable'
        $content | Should -Not -Match 'Install-Module -Name PowerShellGet'
    }

    It "'31 Agent Setup.ps1' passes the pinned Microsoft365DSC version to the worker VM" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'M365DscVersion\s*=\s*\[string\]\$requiredModuleVersions\[''Microsoft365DSC''\]'
        $content | Should -Match 'Install-Module -Name Microsoft365DSC -RequiredVersion \$M365DscVersion'
    }

    It "'31 Agent Setup.ps1' retrieves certificates on the VM using its managed identity" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'Connect-AzAccount -Identity'
        $content | Should -Match 'Get-AzKeyVaultSecret'
        $content | Should -Not -Match 'CertificateBase64'
        $content | Should -Match '(?s)Get-Module -Name Az\.KeyVault -ListAvailable.*?Install-Module -Name Az\.KeyVault -RequiredVersion \$AzKeyVaultVersion'
        $content | Should -Match 'AzKeyVaultVersion\s*=\s*\[string\]\$requiredModuleVersions\[''Az.KeyVault''\]'
        $content | Should -Match 'Connecting to managed identity'
        $content | Should -Match 'Reading certificate secrets from Key Vault'
    }

    It "'10 Setup App Registrations.ps1' does not print credentials or commit them automatically" {
        $path = (Resolve-Path -Path "$PSScriptRoot\..\..\lab\AutomatedLab\10 Setup App Registrations.ps1").Path
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'Set-M365DscKeyVaultSecret'
        $content | Should -Not -Match 'AzApplicationSecret:'
        $content | Should -Not -Match 'git push|git commit'
    }
}

Describe 'Remove-M365DscIdentity' -Tag Integration {
    It 'Should not remove an application for an identity that has none' {
        InModuleScope -ModuleName AzHelpers {
            Mock -CommandName Test-M365DscExchangeOnlineConnection -MockWith { $false }
            Mock -CommandName Remove-MgApplication

            # A managed identity resolves to a service principal only, so its 'Id' stays empty.
            $identity = [M365DscIdentity]::new('M365DscLcmM3652DevIdentity', $null, 'appId', 'principalId', $null, [M365DscIdentityType]::ManagedIdentity)

            Remove-M365DscIdentity -Identity $identity

            Should -Invoke -CommandName Remove-MgApplication -Times 0 -Exactly
        }
    }
}
