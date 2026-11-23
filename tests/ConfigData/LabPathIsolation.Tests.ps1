BeforeAll {
    $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
    $tokens = $null
    $parseErrors = $null
    $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $bootstrapPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $bootstrapFunctions = $bootstrapAst.FindAll({
            param($astNode)
            $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $astNode.Name -in @(
                'Set-GitAuthorizationHeader',
                'Restore-GitAuthorizationHeader',
                'Assert-FreshAzureSession',
                'Add-BicepInstallDirectoriesToPath',
                'Test-SourceDependencyRestoreComplete',
                'Invoke-LabScript',
                'Get-ImportedAzureScriptIssues',
                'Confirm-AzureDevOpsCloneRefresh',
                'Update-OutdatedAzureDevOpsClone'
            )
        }, $true)
    foreach ($functionAst in $bootstrapFunctions)
    {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $importAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\05 Import GitHub Repository.ps1'),
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty
    foreach ($functionAst in $importAst.FindAll({
                param($astNode)
                $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $astNode.Name -in @('Invoke-RepositoryGit', 'Get-GitHubRepositoryHead', 'Sync-GitHubRepository')
            }, $true))
    {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $helperAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\AzHelpers.psm1'),
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty
    $contextFunction = $helperAst.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -eq 'Write-M365DscEnvironmentContext'
    }
    . ([scriptblock]::Create($contextFunction.Extent.Text))
    foreach ($functionAst in $helperAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Name -in @('Get-M365DscKeyVaultNetworkParameters', 'Get-M365DscKeyVaultPrivateEndpoints', 'Resolve-M365DscKeyVaultNetworkParameters', 'Initialize-M365DscKeyVaultPrivateEndpoint', 'Initialize-M365DscAgentKeyVaultPrivateEndpoint')
        })
    {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
}

Describe 'Key Vault private endpoint deployment' {
    BeforeAll {
        $requiredModulesPath = (Resolve-Path $PSScriptRoot\..\..\output\RequiredModules).Path
        $env:PSModulePath += [IO.Path]::PathSeparator + $requiredModulesPath
        Import-Module Az.Resources -RequiredVersion 9.0.1 -ErrorAction Stop
        Import-Module Az.KeyVault -RequiredVersion 6.4.2 -ErrorAction Stop
    }

    BeforeEach {
        $vnetId = '/subscriptions/sub-one/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/provisioning'
        $subnetId = "$vnetId/subnets/endpoints"
        $vault = [pscustomobject]@{
            VaultName = 'kv-stage'
            ResourceGroupName = 'credential-rg'
            ResourceId = '/subscriptions/sub-one/resourceGroups/credential-rg/providers/Microsoft.KeyVault/vaults/kv-stage'
        }
        $endpointId = '/subscriptions/sub-one/resourceGroups/credential-rg/providers/Microsoft.Network/privateEndpoints/endpoint'
        $nicId = '/subscriptions/sub-one/resourceGroups/credential-rg/providers/Microsoft.Network/networkInterfaces/endpoint-nic'
        $existingEndpoint = [pscustomobject]@{
            ResourceId = $endpointId
            Properties = @{
                subnet = @{ id = $subnetId }
                privateLinkServiceConnections = @(@{ properties = @{
                    privateLinkServiceId = $vault.ResourceId
                    privateLinkServiceConnectionState = @{ status = 'Approved' }
                } })
                networkInterfaces = @(@{ id = $nicId })
            }
        }
        $zoneId = '/subscriptions/sub-one/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
        Mock Write-Host {}
        Mock Import-Module {}
        Mock Import-PowerShellDataFile { @{ 'Az.Resources' = '9.0.1' } }
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-one' }; Tenant = [pscustomobject]@{ Id = 'tenant-stage' } }
        }
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = 'Registered' } }
        Mock Register-AzResourceProvider {}
        Mock Update-AzTag {}
        Mock Invoke-AzRestMethod {
            param($Path)
            $value = @(if ($Path -like '*privateDnsZoneGroups?*')
            {
                @(@{ properties = @{ privateDnsZoneConfigs = @(@{ properties = @{ privateDnsZoneId = $zoneId } }) } })
            }
            else
            {
                @(@{ properties = @{ virtualNetwork = @{ id = $vnetId } } })
            }
            )
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $value } | ConvertTo-Json -Depth 10) }
        }
        Mock New-AzResource { [pscustomobject]@{ Properties = @{ provisioningState = 'Succeeded' } } }
        Mock New-AzResourceGroupDeployment {
            [pscustomobject]@{
                ProvisioningState = 'Succeeded'
                Outputs = @{ endpointResourceId = @{ Value = $endpointId } }
            }
        }
        Mock Get-AzResource {
            param($ResourceId)
            if ($ResourceId -eq $endpointId)
            {
                return [pscustomobject]@{
                    Properties = @{
                        privateLinkServiceConnections = @(
                            @{ properties = @{
                                privateLinkServiceId = $vault.ResourceId
                                privateLinkServiceConnectionState = @{ status = 'Approved' }
                            } }
                        )
                        networkInterfaces = @(@{ id = $nicId })
                    }
                }
            }
            if ($ResourceId -eq $nicId)
            {
                return [pscustomobject]@{
                    Properties = @{ ipConfigurations = @(@{ properties = @{ privateIPAddress = '10.20.0.4' } }) }
                }
            }
            [pscustomobject]@{ Location = 'westus2'; Properties = @{} }
        }
        Mock Resolve-DnsName { [pscustomobject]@{ Type = 'A'; IPAddress = '10.20.0.4' } }
        Mock Test-NetConnection { $true }
        Mock Start-Sleep {}
    }

    It 'Deploys repeatable private endpoint and DNS resources and validates the actual vault hostname' {
        Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' `
            -PrivateEndpointSubnetId $subnetId -ValidateLocalConnectivity
        Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' `
            -PrivateEndpointSubnetId $subnetId -ValidateLocalConnectivity

        Should -Invoke New-AzResourceGroupDeployment -Times 2 -Exactly -ParameterFilter {
            $Mode -eq 'Incremental' -and $Force -and
            $ResourceGroupName -eq 'credential-rg' -and
            $TemplateParameterObject.vaultResourceId -eq $vault.ResourceId -and
            $TemplateParameterObject.subnetResourceId -eq $subnetId -and
            $TemplateParameterObject.virtualNetworkIds.Count -eq 1 -and
            $TemplateParameterObject.virtualNetworkIds[0] -eq $vnetId.ToLowerInvariant() -and
            $Name -eq $TemplateParameterObject.endpointName
        }
        Should -Invoke Resolve-DnsName -Times 2 -Exactly -ParameterFilter { $Name -eq 'kv-stage.vault.azure.net' }
        Should -Invoke Test-NetConnection -Times 2 -Exactly -ParameterFilter {
            $ComputerName -eq 'kv-stage.vault.azure.net' -and $Port -eq 443
        }
        Should -Invoke Update-AzTag -Times 2 -Exactly -ParameterFilter {
            $ResourceId -eq $vault.ResourceId -and $Tag.M365DscPrivateEndpointSubnetId -eq $subnetId -and
            $Operation -eq 'Merge' -and $Confirm -eq $false
        }
    }

    It 'Rejects missing and cross-subscription subnet topology before deployment' {
        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' -PrivateEndpointSubnetId 'unknown' } |
            Should -Throw '*full existing Azure subnet resource ID*'
        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' `
            -PrivateEndpointSubnetId ($subnetId -replace 'sub-one', 'sub-other') } |
            Should -Throw '*active subscription*'

        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
    }

    It 'Stops when endpoint approval is pending rather than reporting usable connectivity' {
        Mock Get-AzResource {
            [pscustomobject]@{
                Location = 'westus2'
                Properties = @{ privateLinkServiceConnections = @(
                    @{ properties = @{
                        privateLinkServiceId = $vault.ResourceId
                        privateLinkServiceConnectionState = @{ status = 'Pending' }
                    } }
                ) }
            }
        }

        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' -PrivateEndpointSubnetId $subnetId } |
            Should -Throw '*not Approved*'

        Should -Invoke Test-NetConnection -Times 0 -Exactly
        Should -Invoke Update-AzTag -Times 0 -Exactly
    }

    It 'Fails when private DNS resolves a public IP instead of the allocated endpoint IP' {
        Mock Resolve-DnsName { [pscustomobject]@{ Type = 'A'; IPAddress = '20.1.2.3' } }

        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' `
            -PrivateEndpointSubnetId $subnetId -ValidateLocalConnectivity } |
            Should -Throw '*does not resolve to this endpoint*'

        Should -Invoke Start-Sleep -Times 11 -Exactly
        Should -Invoke Test-NetConnection -Times 0 -Exactly
    }

    It 'Fails when the provisioning machine has private DNS but no network route' {
        Mock Test-NetConnection { $false }

        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' `
            -PrivateEndpointSubnetId $subnetId -ValidateLocalConnectivity } |
            Should -Throw '*cannot reach*TCP 443*'
    }

    It 'Stops before connectivity checks when ARM reports a failed private endpoint deployment' {
        Mock New-AzResourceGroupDeployment {
            [pscustomobject]@{ ProvisioningState = 'Failed' }
        }

        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName 'Stage' `
            -PrivateEndpointSubnetId $subnetId -ValidateLocalConnectivity } |
            Should -Throw '*private endpoint deployment failed*'

        Should -Invoke Test-NetConnection -Times 0 -Exactly
        Should -Invoke Resolve-DnsName -Times 0 -Exactly
    }

    It 'Keeps public-only configuration unchanged and reads private topology from local project settings' {
        $datum = [pscustomobject]@{ Global = [pscustomobject]@{ ProjectSettings = [ordered]@{} } }
        (Get-M365DscKeyVaultNetworkParameters -Datum $datum -EnvironmentName 'Dev').Count | Should -Be 0
        $datum.Global.ProjectSettings.KeyVaultNetworking = [ordered]@{
            Stage = [ordered]@{ PrivateEndpointSubnetId = $subnetId }
        }

        $parameters = Get-M365DscKeyVaultNetworkParameters -Datum $datum -EnvironmentName 'Stage'

        $parameters.PrivateEndpointSubnetId | Should -Be $subnetId
        $parameters.DnsVirtualNetworkId.Count | Should -Be 0
        (Get-M365DscKeyVaultNetworkParameters -Datum $datum -EnvironmentName 'Dev').Count | Should -Be 0
    }

    It 'Gives explicit settings precedence over remembered topology and preserves public-only behavior' {
        $vault | Add-Member Tags @{ M365DscPrivateEndpointSubnetId = 'old-subnet' }
        (Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage -PrivateEndpointSubnetId $subnetId).
            PrivateEndpointSubnetId | Should -Be $subnetId
        $vault.Tags.Clear()
        (Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage).Count | Should -Be 0

        Should -Invoke Get-AzResource -Times 0 -Exactly
    }

    It 'Reads the previously verified subnet from the vault tag without enumerating networks' {
        $vault | Add-Member Tags @{ M365DscPrivateEndpointSubnetId = $subnetId }

        (Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage).
            PrivateEndpointSubnetId | Should -Be $subnetId

        Should -Invoke Get-AzResource -Times 0 -Exactly
    }

    It 'Discovers the subnet by querying the existing vault private endpoint' {
        $vault | Add-Member PublicNetworkAccess Disabled
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = @{ privateEndpointConnections = @(
                @{ properties = @{ privateEndpoint = @{ id = $endpointId } } }
            ) } }
        } -ParameterFilter { $ResourceId -eq $vault.ResourceId }
        Mock Get-AzResource { $existingEndpoint } -ParameterFilter { $ResourceId -eq $endpointId }

        (Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage).
            PrivateEndpointSubnetId | Should -Be $subnetId

        Should -Invoke Get-AzResource -Times 0 -Exactly -ParameterFilter { $ResourceType -eq 'Microsoft.Network/virtualNetworks' }
    }

    It 'Discovers a unique existing subnet while excluding delegated and reserved subnets' {
        $vault | Add-Member PublicNetworkAccess Disabled
        Mock Get-AzResource { [pscustomobject]@{ ResourceId = $vnetId } } `
            -ParameterFilter { $ResourceType -eq 'Microsoft.Network/virtualNetworks' }
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = @{ subnets = @(
                @{ name = 'endpoints'; id = $subnetId; properties = @{} }
                @{ name = 'GatewaySubnet'; id = "$vnetId/subnets/GatewaySubnet"; properties = @{} }
                @{ name = 'app'; id = "$vnetId/subnets/app"; properties = @{ delegations = @(@{ name = 'app' }) } }
            ) } }
        } -ParameterFilter { $ResourceId -eq $vnetId }

        (Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage).
            PrivateEndpointSubnetId | Should -Be $subnetId
    }

    It 'Lists ambiguous candidates instead of choosing an arbitrary subnet' {
        $vault | Add-Member PublicNetworkAccess Disabled
        Mock Get-AzResource { [pscustomobject]@{ ResourceId = $vnetId } } `
            -ParameterFilter { $ResourceType -eq 'Microsoft.Network/virtualNetworks' }
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = @{ subnets = @(
                @{ name = 'endpoints'; id = $subnetId; properties = @{} }
                @{ name = 'other'; id = "$vnetId/subnets/other"; properties = @{} }
            ) } }
        } -ParameterFilter { $ResourceId -eq $vnetId }

        { Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage } |
            Should -Throw '*Candidates: */subnets/endpoints, */subnets/other*'

        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
        Should -Invoke Update-AzTag -Times 0 -Exactly
    }

    It 'Uses separate API versions for generic resource inventory and network detail queries' {
        $vault | Add-Member PublicNetworkAccess Disabled
        Mock Get-AzResource {
            param($ApiVersion)
            if ($ApiVersion -eq '2023-09-01')
            {
                throw "InvalidApiVersionParameter: Microsoft.Resources does not support the network API version."
            }
            [pscustomobject]@{ ResourceId = $vnetId }
        } -ParameterFilter { $ResourceType -eq 'Microsoft.Network/virtualNetworks' }
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = @{ subnets = @(
                @{ name = 'endpoints'; id = $subnetId; properties = @{} }
            ) } }
        } -ParameterFilter { $ResourceId -eq $vnetId }

        (Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage).
            PrivateEndpointSubnetId | Should -Be $subnetId

        Should -Invoke Get-AzResource -Times 1 -Exactly -ParameterFilter {
            $ResourceType -eq 'Microsoft.Network/virtualNetworks' -and -not $ApiVersion -and -not $ExpandProperties
        }
        Should -Invoke Get-AzResource -Times 1 -Exactly -ParameterFilter {
            $ResourceId -eq $vnetId -and $ApiVersion -eq '2023-09-01' -and $ExpandProperties
        }
    }

    It 'Stops explicitly when no existing subnet is available or Azure discovery is denied' {
        $vault | Add-Member PublicNetworkAccess Disabled
        Mock Get-AzResource {} -ParameterFilter { $ResourceType -eq 'Microsoft.Network/virtualNetworks' }
        { Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage } |
            Should -Throw '*Candidates: none*'
        Mock Get-AzResource { throw 'Azure network inventory denied' } -ParameterFilter { $ResourceType -eq 'Microsoft.Network/virtualNetworks' }
        { Resolve-M365DscKeyVaultNetworkParameters -Vault $vault -EnvironmentName Stage } |
            Should -Throw '*Azure network inventory denied*'
    }

    It 'Reuses an existing endpoint and its external DNS zone without redeploying either' {
        Mock Get-M365DscKeyVaultPrivateEndpoints { $existingEndpoint }

        Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName Stage `
            -PrivateEndpointSubnetId $subnetId -ValidateLocalConnectivity

        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
        Should -Invoke New-AzResource -Times 0 -Exactly
        Should -Invoke Test-NetConnection -Times 1 -Exactly
        Should -Invoke Update-AzTag -Times 1 -Exactly
    }

    It 'Adds requested missing DNS links to the existing zone rather than creating a conflicting zone' {
        Mock Get-M365DscKeyVaultPrivateEndpoints { $existingEndpoint }
        $additionalVnetId = '/subscriptions/sub-one/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/connected'

        Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName Stage `
            -PrivateEndpointSubnetId $subnetId -DnsVirtualNetworkId $additionalVnetId

        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
        Should -Invoke New-AzResource -Times 1 -Exactly -ParameterFilter {
            $ResourceId -like "$zoneId/virtualNetworkLinks/*" -and
            $PropertyObject.virtualNetwork.id -eq $additionalVnetId -and
            $PropertyObject.registrationEnabled -eq $false
        }
        Should -Invoke Update-AzTag -Times 0 -Exactly
    }

    It 'Provisions missing DNS infrastructure without replacing an existing private link connection' {
        Mock Get-M365DscKeyVaultPrivateEndpoints { $existingEndpoint }
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }

        Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName Stage -PrivateEndpointSubnetId $subnetId

        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
            $TemplateParameterObject.deployEndpoint -eq $false -and
            $TemplateParameterObject.endpointName -eq 'endpoint'
        }
    }

    It 'Reads subsequent DNS-link pages before deciding a VNet link is missing' {
        Mock Get-M365DscKeyVaultPrivateEndpoints { $existingEndpoint }
        Mock Invoke-AzRestMethod {
            param($Path)
            $body = if ($Path -like '*page=2*')
            {
                @{ value = @(@{ properties = @{ virtualNetwork = @{ id = $vnetId } } }) }
            }
            else
            {
                @{ value = @(); nextLink = "https://management.azure.com$zoneId/virtualNetworkLinks?api-version=2020-06-01&page=2" }
            }
            [pscustomobject]@{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 10) }
        } -ParameterFilter { $Path -like '*virtualNetworkLinks?*' }

        Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName Stage -PrivateEndpointSubnetId $subnetId

        Should -Invoke New-AzResource -Times 0 -Exactly
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -like '*page=2*' }
    }

    It 'Does not modify DNS resources for an existing unapproved connection' {
        $existingEndpoint.Properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status = 'Pending'
        Mock Get-M365DscKeyVaultPrivateEndpoints { $existingEndpoint }

        { Initialize-M365DscKeyVaultPrivateEndpoint -Vault $vault -EnvironmentName Stage -PrivateEndpointSubnetId $subnetId } |
            Should -Throw '*not Approved*'

        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
    }

    It 'Deploys a separate endpoint for an isolated agent using remembered topology <UseRememberedSubnet>' -ForEach @(
        @{ UseRememberedSubnet = $false }
        @{ UseRememberedSubnet = $true }
    ) {
        $datum = [pscustomobject]@{
            Global = [pscustomobject]@{
                ProjectSettings = @{ KeyVaultNetworking = @{ Stage = @{ PrivateEndpointSubnetId = $subnetId } } }
                Azure = @{ Environments = @{ Stage = @{ KeyVaultName = 'kv-stage' } } }
            }
        }
        $vm = [pscustomobject]@{
            ResourceGroupName = 'agent-rg'
            NetworkProfile = @{ NetworkInterfaces = @(@{ Id = 'agent-nic' }) }
        }
        if ($UseRememberedSubnet)
        {
            $datum.Global.ProjectSettings.Clear()
            $vault | Add-Member Tags @{ M365DscPrivateEndpointSubnetId = $subnetId }
        }
        Mock Get-AzKeyVault { $vault }
        Mock Get-AzResource {
            [pscustomobject]@{
                Properties = @{ ipConfigurations = @(
                    @{ properties = @{ subnet = @{ id = '/subscriptions/sub-one/resourceGroups/agent-rg/providers/Microsoft.Network/virtualNetworks/agent/subnets/default' } } }
                ) }
            }
        }
        Mock Initialize-M365DscKeyVaultPrivateEndpoint {}

        Initialize-M365DscAgentKeyVaultPrivateEndpoint -Datum $datum -EnvironmentName 'Stage' -VM $vm

        Should -Invoke Initialize-M365DscKeyVaultPrivateEndpoint -Times 1 -Exactly -ParameterFilter {
            $EndpointResourceGroupName -eq 'agent-rg' -and $PrivateEndpointSubnetId -like '*/agent/subnets/default' -and
            -not $ValidateLocalConnectivity
        }
    }

    It 'Reuses private connectivity when the worker is in the configured endpoint VNet' {
        $datum = [pscustomobject]@{
            Global = [pscustomobject]@{
                ProjectSettings = @{ KeyVaultNetworking = @{ Stage = @{ PrivateEndpointSubnetId = $subnetId } } }
                Azure = @{ Environments = @{ Stage = @{ KeyVaultName = 'kv-stage' } } }
            }
        }
        $vm = [pscustomobject]@{
            ResourceGroupName = 'agent-rg'
            NetworkProfile = @{ NetworkInterfaces = @(@{ Id = 'agent-nic' }) }
        }
        Mock Get-AzKeyVault { $vault }
        Mock Get-AzResource {
            [pscustomobject]@{
                Properties = @{ ipConfigurations = @(
                    @{ properties = @{ subnet = @{ id = "$vnetId/subnets/workers" } } }
                ) }
            }
        }
        Mock Initialize-M365DscKeyVaultPrivateEndpoint {}

        Initialize-M365DscAgentKeyVaultPrivateEndpoint -Datum $datum -EnvironmentName 'Stage' -VM $vm

        Should -Invoke Initialize-M365DscKeyVaultPrivateEndpoint -Times 0 -Exactly
    }
}

Describe 'Azure environment context output' {
    BeforeEach {
        Mock Write-Host {}
    }

    It 'Prints environment and tenant before sign-in without claiming undiscovered IDs' {
        $output = @(Write-M365DscEnvironmentContext -EnvironmentName 'Dev' -TenantName 'dev.example' -Operation 'Signing in')

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '[Environment: Dev] Signing in | Tenant: dev.example'
        }
        $output | Should -BeNullOrEmpty
    }

    It 'Includes discovered tenant, subscription, and vault details in terminal output' {
        Write-M365DscEnvironmentContext -EnvironmentName 'Test' -TenantName 'test.example' `
            -TenantId 'tenant-test' -SubscriptionId 'subscription-test' -KeyVaultName 'kv-test' `
            -Operation 'Configuring applications'

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '[Environment: Test] Configuring applications | Tenant: test.example | Tenant ID: tenant-test | Subscription ID: subscription-test | Key Vault: kv-test'
        }
    }

    It 'Uses the current environment details on each environment switch' {
        Write-M365DscEnvironmentContext -EnvironmentName 'Dev' -TenantName 'dev.example' `
            -TenantId 'tenant-dev' -SubscriptionId 'subscription-dev' -Operation 'Testing connections'
        Write-M365DscEnvironmentContext -EnvironmentName 'Prod' -TenantName 'prod.example' `
            -TenantId 'tenant-prod' -SubscriptionId 'subscription-prod' -Operation 'Testing connections'

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '[Environment: Dev] Testing connections | Tenant: dev.example | Tenant ID: tenant-dev | Subscription ID: subscription-dev'
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '[Environment: Prod] Testing connections | Tenant: prod.example | Tenant ID: tenant-prod | Subscription ID: subscription-prod'
        }
    }
}

Describe 'Azure app registration environment selection' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $registrationAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\..\lab\Azure\10 Setup App Registrations.ps1'),
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty
        $filterStatement = $registrationAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text -match '\$unknownEnvironments'
        }
        $registrationLoop = $registrationAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.ForEachStatementAst]
        }
        $authenticationStatement = $registrationLoop.Body.Statements | Where-Object {
            $_.Extent.Text -match '^\$context\s*=\s*Connect-M365DscEnvironmentContext'
        }
        # Exercise the real parameter/filter/loop code through the first context message, without signing in.
        $loopPrefix = $registrationLoop.Extent.Text.Substring(
            0, $authenticationStatement.Extent.StartOffset - $registrationLoop.Extent.StartOffset
        )
        $registrationContextScript = [scriptblock]::Create(
            $registrationAst.ParamBlock.Extent.Text + "`n" + $filterStatement.Extent.Text + "`n" + $loopPrefix + "`n}"
        )
    }

    It 'Prints scalar environment names with filter <Filter>' -ForEach @(
        @{ Filter = @('Dev', 'Test'); ExpectedCount = 2 }
        @{ Filter = $null; ExpectedCount = 3 }
    ) {
        $datum = [pscustomobject]@{
            Global = [pscustomobject]@{
                Azure = [pscustomobject]@{
                    Environments = [ordered]@{
                        Dev = [pscustomobject]@{ AzTenantName = 'dev.example' }
                        Test = [pscustomobject]@{ AzTenantName = 'test.example' }
                        Prod = [pscustomobject]@{ AzTenantName = 'prod.example' }
                    }
                }
            }
        }
        $environments = @($datum.Global.Azure.Environments.Keys)
        Mock Write-Host {}
        $arguments = @{}
        if ($Filter)
        {
            $arguments.EnvironmentName = $Filter
        }

        & $registrationContextScript @arguments

        Should -Invoke Write-Host -Times $ExpectedCount -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '[Environment: Dev] Signing in to register tenant applications | Tenant: dev.example'
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '[Environment: Test] Signing in to register tenant applications | Tenant: test.example'
        }
    }
}

Describe 'GitHub to Azure DevOps synchronization' {
    BeforeEach {
        $script:GitCommand = Get-Command git
        $syncRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $githubPath = Join-Path $syncRoot 'github.git'
        $devopsPath = Join-Path $syncRoot 'devops.git'
        $seedPath = Join-Path $syncRoot 'seed'
        $checkoutPath = Join-Path $syncRoot 'checkout'
        New-Item -ItemType Directory -Path $syncRoot | Out-Null
        Invoke-RepositoryGit -Arguments @('init', '--bare', '--initial-branch=main', $githubPath) | Out-Null
        Invoke-RepositoryGit -Arguments @('init', '--bare', '--initial-branch=main', $devopsPath) | Out-Null
        Invoke-RepositoryGit -Arguments @('init', '--initial-branch=main', $seedPath) | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'config', 'user.name', 'Sync test') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'config', 'user.email', 'sync@example.invalid') | Out-Null
        $configDirectory = Join-Path $seedPath 'source\Global'
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $configDirectory 'ProjectSettings.yml') -Value 'remote-project'
        Set-Content -LiteralPath (Join-Path $configDirectory 'Azure.yml') -Value 'remote-azure'
        Set-Content -LiteralPath (Join-Path $seedPath 'README.md') -Value 'version-one'
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'add', '--all') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'commit', '-m', 'Initial') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'push', $githubPath, 'main') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'push', $devopsPath, 'main') | Out-Null
        Invoke-RepositoryGit -Arguments @('clone', $devopsPath, $checkoutPath) | Out-Null
        $initialCommit = Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $seedPath 'README.md') -Value 'version-two'
        Set-Content -LiteralPath (Join-Path $configDirectory 'Azure.yml') -Value 'updated-remote-azure'
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'add', '--all') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'commit', '-m', 'GitHub update') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'push', $githubPath, 'main') | Out-Null
        $sourceCommit = Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'rev-parse', 'HEAD')
    }

    It 'Synchronizes repeated GitHub pushes and preserves local configuration' {
        $projectPath = Join-Path $checkoutPath 'source\Global\ProjectSettings.yml'
        $azurePath = Join-Path $checkoutPath 'source\Global\Azure.yml'
        Set-Content -LiteralPath $projectPath -Value 'local-project'
        Set-Content -LiteralPath $azurePath -Value 'local-azure'
        $branch = Get-GitHubRepositoryHead -RepositoryUrl $githubPath

        Sync-GitHubRepository -RepositoryPath $checkoutPath -RepositoryUrl $githubPath -Branch $branch

        Invoke-RepositoryGit -Arguments @("--git-dir=$devopsPath", 'rev-parse', 'main') | Should -Be $sourceCommit
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'rev-parse', 'HEAD') | Should -Be $sourceCommit
        Get-Content -LiteralPath $projectPath -Raw | Should -Be "local-project$([Environment]::NewLine)"
        Get-Content -LiteralPath $azurePath -Raw | Should -Be "local-azure$([Environment]::NewLine)"

        Set-Content -LiteralPath (Join-Path $seedPath 'README.md') -Value 'version-three'
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'commit', '-am', 'Another GitHub update') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'push', $githubPath, 'main') | Out-Null
        $latestCommit = Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'rev-parse', 'HEAD')
        Sync-GitHubRepository -RepositoryPath $checkoutPath -RepositoryUrl $githubPath -Branch $branch
        Sync-GitHubRepository -RepositoryPath $checkoutPath -RepositoryUrl $githubPath -Branch $branch

        Invoke-RepositoryGit -Arguments @("--git-dir=$devopsPath", 'rev-parse', 'main') | Should -Be $latestCommit
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'rev-parse', 'HEAD') | Should -Be $latestCommit
        Get-Content -LiteralPath $azurePath -Raw | Should -Be "local-azure$([Environment]::NewLine)"
    }

    It 'Stops before remote changes when local code has uncommitted edits' {
        Set-Content -LiteralPath (Join-Path $checkoutPath 'README.md') -Value 'local-edit'

        { Sync-GitHubRepository -RepositoryPath $checkoutPath -RepositoryUrl $githubPath -Branch 'main' } |
            Should -Throw '*edits outside*'

        Invoke-RepositoryGit -Arguments @("--git-dir=$devopsPath", 'rev-parse', 'main') | Should -Be $initialCommit
        Get-Content -LiteralPath (Join-Path $checkoutPath 'README.md') -Raw | Should -Be "local-edit$([Environment]::NewLine)"
    }

    It 'Refuses to overwrite commits made only in Azure DevOps' {
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'config', 'user.name', 'Sync test') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'config', 'user.email', 'sync@example.invalid') | Out-Null
        Set-Content -LiteralPath (Join-Path $checkoutPath 'README.md') -Value 'devops-only'
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'commit', '-am', 'DevOps-only commit') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'push', 'origin', 'main') | Out-Null
        $divergentCommit = Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'rev-parse', 'HEAD')
        $freshCheckout = Join-Path $syncRoot 'fresh-checkout'
        Invoke-RepositoryGit -Arguments @('clone', $githubPath, $freshCheckout) | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $freshCheckout, 'remote', 'set-url', 'origin', $devopsPath) | Out-Null

        { Sync-GitHubRepository -RepositoryPath $freshCheckout -RepositoryUrl $githubPath -Branch 'main' } |
            Should -Throw '*Git command*push*failed*'

        Invoke-RepositoryGit -Arguments @("--git-dir=$devopsPath", 'rev-parse', 'main') | Should -Be $divergentCommit
    }

    It 'Refuses local-only commits before changing Azure DevOps' {
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'config', 'user.name', 'Sync test') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'config', 'user.email', 'sync@example.invalid') | Out-Null
        Set-Content -LiteralPath (Join-Path $checkoutPath 'README.md') -Value 'local-only'
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'commit', '-am', 'Local-only commit') | Out-Null
        $localCommit = Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'rev-parse', 'HEAD')

        { Sync-GitHubRepository -RepositoryPath $checkoutPath -RepositoryUrl $githubPath -Branch 'main' } |
            Should -Throw '*commits not present on GitHub*'

        Invoke-RepositoryGit -Arguments @("--git-dir=$devopsPath", 'rev-parse', 'main') | Should -Be $initialCommit
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'rev-parse', 'HEAD') | Should -Be $localCommit
    }

    It 'Preserves local configuration when an untracked file blocks the checkout update' {
        $projectPath = Join-Path $checkoutPath 'source\Global\ProjectSettings.yml'
        Set-Content -LiteralPath $projectPath -Value 'local-project'
        Set-Content -LiteralPath (Join-Path $seedPath 'new-file.txt') -Value 'remote-file'
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'add', '--all') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'commit', '-m', 'New file') | Out-Null
        Invoke-RepositoryGit -Arguments @('-C', $seedPath, 'push', $githubPath, 'main') | Out-Null
        Set-Content -LiteralPath (Join-Path $checkoutPath 'new-file.txt') -Value 'local-untracked'

        { Sync-GitHubRepository -RepositoryPath $checkoutPath -RepositoryUrl $githubPath -Branch 'main' } |
            Should -Throw '*Git command*merge*failed*'

        Get-Content -LiteralPath $projectPath -Raw | Should -Be "local-project$([Environment]::NewLine)"
        Get-Content -LiteralPath (Join-Path $checkoutPath 'new-file.txt') -Raw | Should -Be "local-untracked$([Environment]::NewLine)"
        Invoke-RepositoryGit -Arguments @('-C', $checkoutPath, 'rev-parse', 'HEAD') | Should -Be $initialCommit
    }
}

Describe 'Lab script path isolation' {
    It 'Should not reference scripts in the sibling lab path' {
        $labRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab'
        $crossPathReferences = @(
            @{
                Path    = Join-Path -Path $labRoot -ChildPath 'Azure'
                Sibling = 'AutomatedLab'
            }
            @{
                Path    = Join-Path -Path $labRoot -ChildPath 'AutomatedLab'
                Sibling = 'Azure'
            }
        ) | ForEach-Object {
            $pattern = "(?i)\.\.[\\/]" + [regex]::Escape($_.Sibling) + "[\\/]"
            Get-ChildItem -LiteralPath $_.Path -Filter '*.ps1' -File -Recurse |
                Select-String -Pattern $pattern
        }

        $crossPathReferences | Should -BeNullOrEmpty
    }
}

Describe 'Azure repository import step' {
    It 'Keeps GitHub import and local checkout creation in its own script' {
        $labRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab'
        $bootstrapPath = Join-Path -Path $labRoot -ChildPath 'Start Azure Lab.ps1'
        $importPath = Join-Path -Path $labRoot -ChildPath 'Azure\05 Import GitHub Repository.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
        $importTokens = $null
        $importErrors = $null
        $importAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $importPath,
            [ref]$importTokens,
            [ref]$importErrors
        )

        Test-Path -LiteralPath $importPath -PathType Leaf | Should -BeTrue
        $bootstrapContent | Should -Match ([regex]::Escape('Azure\05 Import GitHub Repository.ps1'))
        $importErrors | Should -BeNullOrEmpty
        $importAst.FindAll({ param($astNode) $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name |
            Should -Contain 'Ensure-AzureDevOpsRepository'
        $bootstrapContent | Should -Not -Match 'function Ensure-AzureDevOpsRepository'
    }
}

Describe 'Project settings credential bootstrap' {
    It 'Prepares the Key Vault before importing the Azure DevOps repository' {
        $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
        $credentialStage = $bootstrapContent.IndexOf("Name 'bootstrap-project-settings'", [StringComparison]::Ordinal)
        $importStage = $bootstrapContent.IndexOf("Name 'import-repository'", [StringComparison]::Ordinal)

        $credentialStage | Should -BeGreaterThan -1
        $credentialStage | Should -BeLessThan $importStage
    }

    It 'Opens the configured organization and stores validated credentials without writing them to YAML' {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\04 Setup Project Settings Key Vault.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        $parseErrors | Should -BeNullOrEmpty
        $content | Should -Match 'Start-Process -FilePath \$tokenPage'
        $content | Should -Match 'Read-Host .* -AsSecureString'
        $content | Should -Match 'Test-AzureDevOpsPersonalAccessToken'
        $content | Should -Match 'Set-M365DscKeyVaultSecret'
        $content | Should -Not -Match '(?im)^\s*(Set-Content|Out-File)\b'
    }
}

Describe 'Azure worker shutdown module loading' {
    It 'Loads the repository-pinned Az modules before connecting to Azure' {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\89 Stop Workers.ps1'
        $scriptContent = Get-Content -LiteralPath $scriptPath -Raw

        $scriptContent | Should -Match 'Import-Module -Name Az\.Accounts -RequiredVersion \$requiredModuleVersions'
        $scriptContent | Should -Match 'Import-Module -Name Az\.Compute -RequiredVersion \$requiredModuleVersions'
        $scriptContent.IndexOf('Import-Module -Name Az.Compute') |
            Should -BeLessThan $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1')
        $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1') |
            Should -BeLessThan $scriptContent.IndexOf('Connect-M365Dsc @param')
        $scriptContent | Should -Match 'Already-loaded Az modules'
    }
}

Describe 'Worker removal module loading' {
    It 'Loads the pinned Microsoft Graph application modules before connecting for <ScriptPath>' -ForEach @(
        @{ ScriptPath = '..\..\lab\AutomatedLab\96 Remove Workers.ps1' }
        @{ ScriptPath = '..\..\lab\Azure\96 Remove Workers.ps1' }
    ) {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $ScriptPath
        $scriptContent = Get-Content -LiteralPath $scriptPath -Raw

        $scriptContent | Should -Match 'Import-Module -Name Microsoft\.Graph\.Applications -RequiredVersion \$requiredModuleVersions'
        $scriptContent | Should -Match 'Import-Module -Name Microsoft\.Graph\.Identity\.DirectoryManagement -RequiredVersion \$requiredModuleVersions'
        $scriptContent.IndexOf('Import-Module -Name Microsoft.Graph.Applications') |
            Should -BeLessThan $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1')
        $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1') |
            Should -BeLessThan $scriptContent.IndexOf('Connect-M365Dsc @param')
        $scriptContent | Should -Match 'Already-loaded Azure or Graph modules'
    }
}

Describe 'Azure bootstrap session isolation' {
    It 'Stops before setup when Az.Accounts is already loaded' {
        Mock Get-Module { [pscustomobject]@{ Name = 'Az.Accounts' } }

        { Assert-FreshAzureSession } | Should -Throw '*fresh elevated PowerShell 7 session*'
    }

    It 'Propagates preparation script failures to the bootstrap stage' {
        $preparationScript = Join-Path -Path $TestDrive -ChildPath 'failed-preparation.ps1'
        "throw 'Simulated preparation failure'" | Set-Content -LiteralPath $preparationScript

        { Invoke-LabScript -Path $preparationScript } | Should -Throw '*Simulated preparation failure*'
    }

    It 'Makes the preparation script terminate when an Azure assembly is already loaded' {
        $preparationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\00 Prep.ps1'
        $tokens = $null
        $parseErrors = $null
        $preparationAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $preparationPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty
        $sessionGuard = $preparationAst.Find({
                param($astNode)
                $astNode -is [System.Management.Automation.Language.IfStatementAst] -and
                $astNode.Extent.Text -match '\$loadedAzAccounts' -and
                $astNode.Extent.Text -match '\$assemblyLoading'
            }, $true)

        $sessionGuard | Should -Not -BeNullOrEmpty
        $sessionGuard.Extent.Text | Should -Match '\bthrow\b'
        $sessionGuard.Extent.Text | Should -Not -Match '\breturn\b'
    }
}

Describe 'Azure bootstrap dependency restore' {
    It 'Runs the dependency resolver directly in an isolated PowerShell process' {
        $labRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab'
        $bootstrapPath = Join-Path -Path $labRoot -ChildPath 'Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw

        $bootstrapContent | Should -Match ([regex]::Escape("ChildPath 'Resolve-Dependency.ps1'"))
        $bootstrapContent | Should -Match ([regex]::Escape('$dependencyRestoreArguments = @(''-UsePSResourceGet'')'))
        $bootstrapContent | Should -Match ([regex]::Escape('$dependencyRestoreArguments += ''-WithYAML'''))
        $bootstrapContent | Should -Match ([regex]::Escape('$dependencyRestoreArguments += ''-WithYAML:$false'''))
        $bootstrapContent | Should -Match ([regex]::Escape('-File $sourceDependencyScript @dependencyRestoreArguments'))
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-File $sourceBuildScript -UsePSResourceGet -ResolveDependency'))
    }

    It 'Adds an existing Bicep install directory to the process PATH' {
        $previousPath = $env:PATH
        $installDirectory = Join-Path -Path $TestDrive -ChildPath 'Bicep CLI'
        $null = New-Item -ItemType Directory -Path $installDirectory -Force
        $executablePath = Join-Path -Path $installDirectory -ChildPath 'bicep.exe'
        Set-Content -LiteralPath $executablePath -Value 'test executable'
        try
        {
            Add-BicepInstallDirectoriesToPath -ExecutablePaths @($executablePath)

            @($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator)) |
                Should -Contain $installDirectory
        }
        finally
        {
            $env:PATH = $previousPath
        }
    }

    It 'Runs the Azure-specific build initialization workflow in a clean process' {
        $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
        $buildConfigurationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\build.yaml'
        $buildConfiguration = Get-Content -LiteralPath $buildConfigurationPath -Raw

        $bootstrapContent | Should -Match ([regex]::Escape('-NoLogo -NoProfile -File $targetBuildScript -Tasks azureinit'))
        $buildConfiguration | Should -Match '(?ms)^\s+azureinit:\s*\r?\n\s+- test7\s*\r?\n\s+- LoadDatumConfigData\s*\r?\n\s+- ConfigDataPreparation'
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-Tasks shellinit'))
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-Tasks init'))
    }

    It 'Keeps checkpoint restart separate from forced dependency restoration' {
        $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw

        $bootstrapContent | Should -Match '\[switch\]\$ForceDependencyRestore'
        $bootstrapContent | Should -Match ([regex]::Escape('-ForceRestore:$ForceDependencyRestore'))
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-ForceRestore:$Restart'))
    }

    It 'Skips dependency restore only when every required package version is present' {
        $repositoryRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
        $requiredModules = Import-PowerShellDataFile (Join-Path -Path $repositoryRoot -ChildPath 'RequiredModules.psd1')
        $resolverDefaults = Import-PowerShellDataFile (Join-Path -Path $repositoryRoot -ChildPath 'Resolve-Dependency.psd1')
        $requirements = foreach ($entry in $requiredModules.GetEnumerator() | Where-Object Key -ne 'PSDependOptions')
        {
            $version = if ($entry.Value -is [System.Collections.IDictionary]) { [string]$entry.Value.Version } else { [string]$entry.Value }
            @{ Name = $entry.Key; Version = $version }
        }
        $requirements += @{ Name = 'PSDepend'; Version = 'latest' }
        if ($resolverDefaults.WithYAML) { $requirements += @{ Name = 'PowerShell-Yaml'; Version = 'latest' } }
        if ($resolverDefaults.UsePSResourceGet) { $requirements += @{ Name = 'Microsoft.PowerShell.PSResourceGet'; Version = [string]$resolverDefaults.PSResourceGetVersion } }
        if ($resolverDefaults.UsePowerShellGetCompatibilityModule) { $requirements += @{ Name = 'PowerShellGet'; Version = [string]$resolverDefaults.UsePowerShellGetCompatibilityModuleVersion } }

        $requiredModulesPath = Join-Path -Path $TestDrive -ChildPath 'RequiredModules'
        $dependencyModuleFixtures = @(
            foreach ($requirement in $requirements)
            {
                $version = $requirement.Version
                $prerelease = $null
                if ($version -match '^(.+)-([^-]+)$')
                {
                    $version = $Matches[1]
                    $prerelease = $Matches[2]
                }
                if ($version -eq 'latest') { $version = '1.0.0' }

                [pscustomobject]@{
                    Name        = $requirement.Name
                    ModuleBase  = $requiredModulesPath
                    Version     = [version]$version
                    PrivateData = @{ PSData = @{ Prerelease = $prerelease } }
                }
            }
        )
        $previousFixtures = Get-Variable -Name 'AzureBootstrapDependencyModuleFixtures' -Scope Global -ErrorAction SilentlyContinue
        $global:AzureBootstrapDependencyModuleFixtures = $dependencyModuleFixtures
        Mock Get-Module { $global:AzureBootstrapDependencyModuleFixtures }
        try
        {
            Test-SourceDependencyRestoreComplete `
                -RepositoryRoot $repositoryRoot `
                -RequiredModulesPath $requiredModulesPath `
                -Verbose |
                Should -BeTrue

            Test-SourceDependencyRestoreComplete `
                -RepositoryRoot $repositoryRoot `
                -RequiredModulesPath $requiredModulesPath `
                -ForceRestore |
                Should -BeFalse

            $global:AzureBootstrapDependencyModuleFixtures = @($dependencyModuleFixtures | Where-Object Name -ne 'Az.Security')
            Test-SourceDependencyRestoreComplete `
                -RepositoryRoot $repositoryRoot `
                -RequiredModulesPath $requiredModulesPath |
                Should -BeFalse
        }
        finally
        {
            Remove-Variable -Name 'AzureBootstrapDependencyModuleFixtures' -Scope Global -ErrorAction SilentlyContinue
            if ($previousFixtures)
            {
                Set-Variable -Name 'AzureBootstrapDependencyModuleFixtures' -Scope Global -Value $previousFixtures.Value
            }
        }
    }
}

Describe 'Azure DevOps clone refresh approval' {
    It 'Detects when the imported checkout is missing the current Azure scripts' {
        $issues = @(Get-ImportedAzureScriptIssues -RepositoryPath $TestDrive)

        $issues.Count | Should -Be 6
        $issues[0] | Should -Match 'lab\\Azure\\00 Prep.ps1'
        $issues[4] | Should -Match 'build.yaml'
        $issues[5] | Should -Match 'build.ps1'
    }

    It 'Accepts a checkout containing all required scripts and parameters' {
        $scriptDefinitions = @(
            @{ Path = 'lab\Azure\00 Prep.ps1'; Parameter = 'ProjectName' }
            @{ Path = 'lab\Azure\30 Create Agent VMs.ps1'; Parameter = 'BuildAgentPassword' }
            @{ Path = 'lab\Azure\31 Agent Setup.ps1'; Parameter = 'EnvironmentName' }
        )
        foreach ($scriptDefinition in $scriptDefinitions)
        {
            $scriptPath = Join-Path -Path $TestDrive -ChildPath $scriptDefinition.Path
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $scriptPath -Parent) -Force
            "param([string]`$$($scriptDefinition.Parameter))" |
                Set-Content -LiteralPath $scriptPath
        }
        $helperPath = Join-Path -Path $TestDrive -ChildPath 'lab\Azure\AzHelpers.psm1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $helperPath -Parent) -Force
        'function Get-M365DscProjectSettingsFromKeyVault { param([object]$Datum) }' |
            Set-Content -LiteralPath $helperPath

        "  azureinit:`r`n    - test7`r`n    - LoadDatumConfigData`r`n    - ConfigDataPreparation" |
            Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'build.yaml')
        @'
        $buildResult = @{}
        Invoke-Build @PSBoundParameters -Task $Tasks -File $MyInvocation.MyCommand.Path -Result $buildResult
        if ($buildResult.Value.Error) { throw $buildResult.Value.Error }
'@ | Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'build.ps1')

        Get-ImportedAzureScriptIssues -RepositoryPath $TestDrive | Should -BeNullOrEmpty
    }

    It 'Requires affirmative approval before refreshing an outdated clone' {
        Mock Read-Host { 'n' }
        Confirm-AzureDevOpsCloneRefresh -Upstream 'origin/main' -Behind 43 -Ahead 0 |
            Should -BeFalse

        Mock Read-Host { 'yes' }
        Confirm-AzureDevOpsCloneRefresh -Upstream 'origin/main' -Behind 43 -Ahead 0 |
            Should -BeTrue
    }

    It 'Refreshes tracked files after approval while preserving local configuration' {
        $testRoot = Join-Path -Path $TestDrive -ChildPath 'clone-refresh'
        $originPath = Join-Path -Path $testRoot -ChildPath 'origin.git'
        $seedPath = Join-Path -Path $testRoot -ChildPath 'seed'
        $clonePath = Join-Path -Path $testRoot -ChildPath 'clone'
        $null = New-Item -ItemType Directory -Path $testRoot -Force

        git init --bare $originPath | Out-Null
        git init $seedPath | Out-Null
        git -C $seedPath checkout -b main | Out-Null
        git -C $seedPath config user.name 'Bootstrap test'
        git -C $seedPath config user.email 'bootstrap-test@example.invalid'

        foreach ($relativePath in @('source\Global\ProjectSettings.yml', 'source\Global\Azure.yml'))
        {
            $filePath = Join-Path -Path $seedPath -ChildPath $relativePath
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $filePath -Parent) -Force
            Set-Content -LiteralPath $filePath -Value 'remote-config-v1'
        }
        Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'README.md') -Value 'remote-v1'
        git -C $seedPath add --all
        git -C $seedPath commit -m 'Initial repository' | Out-Null
        git -C $seedPath remote add origin $originPath
        git -C $seedPath push -u origin main | Out-Null
        git clone --branch main $originPath $clonePath | Out-Null

        Set-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\ProjectSettings.yml') -Value 'local-project-settings'
        Set-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\Azure.yml') -Value 'local-azure-settings'
        Set-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'README.md') -Value 'local-code-change'

        $scriptDefinitions = @(
            @{ Path = 'lab\Azure\00 Prep.ps1'; Parameter = 'ProjectName' }
            @{ Path = 'lab\Azure\30 Create Agent VMs.ps1'; Parameter = 'BuildAgentPassword' }
            @{ Path = 'lab\Azure\31 Agent Setup.ps1'; Parameter = 'EnvironmentName' }
        )
        foreach ($scriptDefinition in $scriptDefinitions)
        {
            $scriptPath = Join-Path -Path $seedPath -ChildPath $scriptDefinition.Path
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $scriptPath -Parent) -Force
            "param([string]`$$($scriptDefinition.Parameter))" |
                Set-Content -LiteralPath $scriptPath
        }
        $helperPath = Join-Path -Path $seedPath -ChildPath 'lab\Azure\AzHelpers.psm1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $helperPath -Parent) -Force
        'function Get-M365DscProjectSettingsFromKeyVault { param([object]$Datum) }' |
            Set-Content -LiteralPath $helperPath
        "  azureinit:`r`n    - test7`r`n    - LoadDatumConfigData`r`n    - ConfigDataPreparation" |
            Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'build.yaml')
        @'
$buildResult = @{}
Invoke-Build @PSBoundParameters -Task $Tasks -File $MyInvocation.MyCommand.Path -Result $buildResult
if ($buildResult.Value.Error) { throw $buildResult.Value.Error }
'@ | Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'build.ps1')
        Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'README.md') -Value 'remote-v2'
        foreach ($relativePath in @('source\Global\ProjectSettings.yml', 'source\Global\Azure.yml'))
        {
            Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath $relativePath) -Value 'remote-config-v2'
        }
        git -C $seedPath add --all
        git -C $seedPath commit -m 'Add current Azure scripts' | Out-Null
        git -C $seedPath push origin main | Out-Null

        $script:GitCommand = Get-Command -Name git
        $oldCommit = git -C $clonePath rev-parse HEAD
        Mock Read-Host { 'n' }
        {
            Update-OutdatedAzureDevOpsClone `
                -RepositoryPath $clonePath `
                -AuthorizationHeader 'AUTHORIZATION: Basic dGVzdA==' `
                -BackupRoot (Join-Path -Path $testRoot -ChildPath 'backups')
        } | Should -Throw 'The local clone was not changed*'
        (git -C $clonePath rev-parse HEAD) | Should -Be $oldCommit

        Mock Read-Host { 'y' }
        Update-OutdatedAzureDevOpsClone `
            -RepositoryPath $clonePath `
            -AuthorizationHeader 'AUTHORIZATION: Basic dGVzdA==' `
            -BackupRoot (Join-Path -Path $testRoot -ChildPath 'backups')

        (Get-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'README.md') -Raw).Trim() |
            Should -Be 'remote-v2'
        (Get-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\ProjectSettings.yml') -Raw).Trim() |
            Should -Be 'local-project-settings'
        (Get-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\Azure.yml') -Raw).Trim() |
            Should -Be 'local-azure-settings'
        Get-ImportedAzureScriptIssues -RepositoryPath $clonePath | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path -Path $testRoot -ChildPath 'backups') -Directory -ErrorAction SilentlyContinue).Count |
            Should -Be 0
    }
}
