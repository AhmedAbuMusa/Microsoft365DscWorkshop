BeforeAll {
    function Read-ProvisioningAst([string]$Path) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors) { throw ($errors.Message -join '; ') }
        return $ast
    }
}
Describe 'Isolated KDBX application registration' {
    BeforeAll {
        $ast = Read-ProvisioningAst "$PSScriptRoot\..\..\lab\Secrets\Kdbx\Register Applications.ps1"
        $loop = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] }
        $register = [scriptblock]::Create($loop.Extent.Text)
        function Connect-M365DscEnvironmentContext {}
        function Connect-M365Dsc {}
        function Test-M365DscConnection {}
        function New-M365DscIdentity { param($Name, [switch]$GenereateCertificate, [switch]$PassThru) }
        function Test-M365DscSecret { param($Name) }
        function Get-M365DscSecret { param($Name) }
        function Set-M365DscSecret { param($Name, $Value, $Attachment) }
        function ConvertTo-M365DscSecureString {
            param([string]$Value)
            $secure = [securestring]::new()
            foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
            return $secure
        }
        function Add-M365DscIdentityPermission { param($Identity, $AccessType, [switch]$SkipAzurePermissions, [switch]$AddToGlobalAdminRole) }
        function Get-AzRoleAssignment { [CmdletBinding()]param($ObjectId, $RoleDefinitionName, $Scope) }
        function New-AzRoleAssignment { [CmdletBinding()]param($ObjectId, $RoleDefinitionName, $Scope) }
        function Get-M365DscStoredCertificate {}
        function Set-M365DscSecretJson { param($Name, $Value) }
        function Disconnect-M365Dsc {}
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=SyntheticRegistration', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddDays(1))
    }
    AfterAll { $certificate.Dispose(); $rsa.Dispose() }
    BeforeEach {
        $datum = @{ Global = @{ Azure = @{ Environments = @{
            Dev = @{ AzTenantName = 'synthetic.onmicrosoft.com'; HasExchangeOnline = $false; HasSharePointOnline = $false }
        } } } }
        $names = @('Dev')
        $roles = 'M365DscSetupApplication','M365DscLcmApplication','M365DscExportApplication'
        $deploymentId = 'synthetic-deployment'
        Mock Connect-M365DscEnvironmentContext { @{ Tenant = @{ Id = 'synthetic-tenant' }; Subscription = @{ Id = 'synthetic-subscription' } } }
        Mock Connect-M365Dsc {}
        Mock Test-M365DscConnection { $true }
        Mock New-M365DscIdentity {
            @{ AppId = 'synthetic-app'; AppPrincipalId = 'synthetic-principal'; CertificateThumbprint = $certificate.Thumbprint }
        }
        Mock Test-M365DscSecret { $false }
        Mock Set-M365DscSecret {}
        Mock Add-M365DscIdentityPermission {}
        Mock Get-AzRoleAssignment {}
        Mock New-AzRoleAssignment {}
        Mock Get-Item { $certificate } -ParameterFilter { $LiteralPath -like 'Cert:*' }
        Mock Get-M365DscStoredCertificate {
            @{ Thumbprint = $certificate.Thumbprint; Pfx = [byte[]]@(1,2,3); Password = ConvertTo-M365DscSecureString 'synthetic-pfx' }
        }
        Mock Set-M365DscSecretJson {}
        Mock Disconnect-M365Dsc {}
    }
    It 'Stores each role certificate before environment metadata and grants only subscription Reader on Azure' {
        & $register
        Should -Invoke Set-M365DscSecret -Times 3 -Exactly -ParameterFilter {
            $Name -like 'Certificate/Dev/*' -and $Attachment.Length -gt 0 -and $Value -is [securestring]
        }
        Should -Invoke New-M365DscIdentity -Times 6 -Exactly -ParameterFilter { $Name -like '*-synthetic-deployment' }
        Should -Invoke Add-M365DscIdentityPermission -Times 1 -Exactly -ParameterFilter {
            $AccessType -eq 'Read' -and $SkipAzurePermissions -and -not $AddToGlobalAdminRole
        }
        Should -Invoke New-AzRoleAssignment -Times 3 -Exactly -ParameterFilter {
            $RoleDefinitionName -eq 'Reader' -and $Scope -eq '/subscriptions/synthetic-subscription'
        }
        Should -Invoke Set-M365DscSecretJson -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Environment/Dev' -and $Value.Identities.Count -eq 3
        }
    }
    It 'Does not report completed environment metadata when encrypted certificate persistence fails' {
        Mock Set-M365DscSecret { throw 'Synthetic encrypted-store failure' } -ParameterFilter { $Name -like 'Certificate/*' }
        { & $register } | Should -Throw '*encrypted-store failure*'
        Should -Invoke Set-M365DscSecretJson -Times 0
        Should -Invoke Disconnect-M365Dsc -Times 1 -Exactly
    }
    It 'Rejects an unrelated application binding without changing its saved recovery records' {
        Mock Test-M365DscSecret { $true }
        Mock Get-M365DscSecret { ConvertTo-M365DscSecureString 'unrelated-app' }
        { & $register } | Should -Throw '*binding mismatch*'
        Should -Invoke Set-M365DscSecret -Times 0
        Should -Invoke New-M365DscIdentity -Times 0 -ParameterFilter { $GenereateCertificate }
    }
}

Describe 'Subscription resource provider readiness' {
    BeforeAll {
        $ast = Read-ProvisioningAst "$PSScriptRoot\..\..\lab\Azure\AzHelpers.psm1"
        $function = $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Initialize-M365DscResourceProvider'
        }
        . ([scriptblock]::Create($function.Extent.Text))
        function Get-AzContext { [CmdletBinding()]param() }
        function Get-AzResourceProvider { [CmdletBinding()]param($ProviderNamespace) }
        function Register-AzResourceProvider { [CmdletBinding()]param($ProviderNamespace) }
    }
    BeforeEach {
        $context = @{ Subscription = @{ Id = 'synthetic-subscription' } }
        Mock Get-AzContext { $context }
        Mock Get-AzResourceProvider { @{ RegistrationState = 'Registered' } }
        Mock Register-AzResourceProvider {}
        Mock Start-Sleep {}
        Mock Write-Host {}
    }
    It 'Leaves registered providers unchanged and checks them in the expected subscription context' {
        Initialize-M365DscResourceProvider -SubscriptionId 'synthetic-subscription' `
            -ProviderNamespace 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.ManagedIdentity'
        Should -Invoke Get-AzContext -Times 1 -Exactly
        Should -Invoke Get-AzResourceProvider -Times 3 -Exactly
        Should -Invoke Register-AzResourceProvider -Times 0
        Should -Invoke Start-Sleep -Times 0
    }
    It 'Registers a missing provider once and waits for Azure to report Registered' {
        $states = [Collections.Generic.Queue[string]]::new()
        foreach ($state in 'NotRegistered', 'Registering', 'Registered') { $states.Enqueue($state) }
        Mock Get-AzResourceProvider { @{ RegistrationState = $states.Dequeue() } }
        Initialize-M365DscResourceProvider -SubscriptionId 'synthetic-subscription' -ProviderNamespace 'Microsoft.Network'
        Should -Invoke Register-AzResourceProvider -Times 1 -Exactly -ParameterFilter {
            $ProviderNamespace -eq 'Microsoft.Network'
        }
        Should -Invoke Get-AzResourceProvider -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }
    It 'Waits for an in-progress registration without submitting a duplicate request' {
        $states = [Collections.Generic.Queue[string]]::new()
        foreach ($state in 'Registering', 'Registered') { $states.Enqueue($state) }
        Mock Get-AzResourceProvider { @{ RegistrationState = $states.Dequeue() } }
        Initialize-M365DscResourceProvider -ProviderNamespace 'Microsoft.Compute'
        Should -Invoke Register-AzResourceProvider -Times 0
        Should -Invoke Get-AzResourceProvider -Times 2 -Exactly
    }
    It 'Refreshes a registered provider when a deployment error or feature registration requires it' {
        Initialize-M365DscResourceProvider -SubscriptionId 'synthetic-subscription' -ProviderNamespace 'Microsoft.Network' -ForceRegistration
        Should -Invoke Register-AzResourceProvider -Times 1 -Exactly -ParameterFilter { $ProviderNamespace -eq 'Microsoft.Network' }
        Should -Invoke Get-AzResourceProvider -Times 2 -Exactly
    }
    It 'Reports a bounded registration timeout instead of proceeding with resource provisioning' {
        Mock Get-AzResourceProvider { @{ RegistrationState = 'Registering' } }
        { Initialize-M365DscResourceProvider -ProviderNamespace 'Microsoft.Network' } |
            Should -Throw "*Microsoft.Network*synthetic-subscription*60 probes*"
        Should -Invoke Get-AzResourceProvider -Times 61 -Exactly
        Should -Invoke Start-Sleep -Times 59 -Exactly
    }
    It 'Propagates registration permission failures without retrying indefinitely' {
        Mock Get-AzResourceProvider { @{ RegistrationState = 'NotRegistered' } }
        Mock Register-AzResourceProvider { throw 'Synthetic authorization denial' }
        { Initialize-M365DscResourceProvider -ProviderNamespace 'Microsoft.ManagedIdentity' } |
            Should -Throw '*authorization denial*'
        Should -Invoke Start-Sleep -Times 0
    }
    It 'Rejects an unexpected subscription before requesting or changing registrations' {
        { Initialize-M365DscResourceProvider -SubscriptionId 'different-subscription' -ProviderNamespace 'Microsoft.Network' } |
            Should -Throw '*does not match*'
        Should -Invoke Get-AzResourceProvider -Times 0
        Should -Invoke Register-AzResourceProvider -Times 0
    }
    It 'Stops when Azure does not return a registration state' {
        Mock Get-AzResourceProvider { $null }
        { Initialize-M365DscResourceProvider -ProviderNamespace 'Microsoft.Network' } |
            Should -Throw '*did not return a registration state*'
        Should -Invoke Register-AzResourceProvider -Times 0
    }
}

Describe 'Deployment registration exception recovery' {
    BeforeAll {
        $ast = Read-ProvisioningAst "$PSScriptRoot\..\..\lab\Azure\AzHelpers.psm1"
        $function = $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-M365DscResourceGroupDeployment'
        }
        . ([scriptblock]::Create($function.Extent.Text))
        function Get-AzContext { [CmdletBinding()]param() }
        function Get-AzProviderFeature { [CmdletBinding()]param($ProviderNamespace, $FeatureName) }
        function Register-AzProviderFeature { [CmdletBinding()]param($ProviderNamespace, $FeatureName) }
        function Initialize-M365DscResourceProvider { [CmdletBinding()]param($SubscriptionId, $ProviderNamespace, [switch]$ForceRegistration) }
        function New-AzResourceGroupDeployment { [CmdletBinding()]param($Name, $ResourceGroupName, $TemplateFile, $TemplateParameterObject, $Tag) }
    }
    BeforeEach {
        $parameters = @{
            Name = 'build-agent-Prod'; ResourceGroupName = 'synthetic-rg'; TemplateFile = 'synthetic.bicep'
            TemplateParameterObject = @{ vmName = 'synthetic-vm'; adminPassword = 'synthetic-test-value' }
            Tag = @{ Environment = 'Prod' }
        }
        $featureError = 'Subscription /subscriptions/synthetic-subscription/resourceGroups//providers/Microsoft.Network/subscriptions/ is not registered for feature Microsoft.Network/AllowBringYourOwnPublicIpAddress required to carry out the requested operation. (Code: SubscriptionNotRegisteredForFeature)'
        Mock Get-AzContext { @{ Subscription = @{ Id = 'synthetic-subscription' } } }
        Mock Get-AzProviderFeature { @{ RegistrationState = 'Registered' } }
        Mock Register-AzProviderFeature {}
        Mock Initialize-M365DscResourceProvider {}
        Mock New-AzResourceGroupDeployment { @{ ProvisioningState = 'Succeeded' } }
        Mock Start-Sleep {}
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    It 'Returns a successful deployment without changing registrations' {
        (Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters).ProvisioningState |
            Should -Be 'Succeeded'
        Should -Invoke Get-AzProviderFeature -Times 0
        Should -Invoke Initialize-M365DscResourceProvider -Times 0
        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly
    }
    It 'Registers the exact feature reported in error details, awaits readiness, refreshes its provider and retries the same deployment' {
        $states = [Collections.Generic.Queue[string]]::new()
        foreach ($state in 'NotRegistered', 'Registering', 'Registered') { $states.Enqueue($state) }
        Mock Get-AzProviderFeature { @{ RegistrationState = $states.Dequeue() } }
        $attempts = [Collections.Generic.List[string]]::new()
        Mock New-AzResourceGroupDeployment {
            $attempts.Add($Name)
            $ResourceGroupName | Should -Be $parameters.ResourceGroupName
            $TemplateParameterObject | Should -Be $parameters.TemplateParameterObject
            $TemplateFile | Should -Be $parameters.TemplateFile
            $Tag | Should -Be $parameters.Tag
            if ($attempts.Count -eq 1) {
                $record = [Management.Automation.ErrorRecord]::new(
                    [InvalidOperationException]::new('Deployment failed'), 'DeploymentFailed',
                    [Management.Automation.ErrorCategory]::InvalidOperation, $null)
                $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($featureError)
                throw $record
            }
            @{ ProvisioningState = 'Succeeded' }
        }
        Mock Initialize-M365DscResourceProvider {
            $states.Count | Should -Be 0
            $attempts.Count | Should -Be 1
        }
        (Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters).ProvisioningState |
            Should -Be 'Succeeded'
        Should -Invoke Register-AzProviderFeature -Times 1 -Exactly -ParameterFilter {
            $ProviderNamespace -eq 'Microsoft.Network' -and $FeatureName -eq 'AllowBringYourOwnPublicIpAddress'
        }
        Should -Invoke Initialize-M365DscResourceProvider -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq 'synthetic-subscription' -and $ProviderNamespace -eq 'Microsoft.Network' -and $ForceRegistration
        }
        Should -Invoke New-AzResourceGroupDeployment -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }
    It 'Awaits in-progress features without registering again' -TestCases @(
        @{ State = 'Registering' }, @{ State = 'Pending' }, @{ State = 'Registered' }
    ) {
        param($State)
        $states = [Collections.Generic.Queue[string]]::new()
        $states.Enqueue($State)
        $states.Enqueue('Registered')
        Mock Get-AzProviderFeature { @{ RegistrationState = $states.Dequeue() } }
        $attempts = [Collections.Generic.List[int]]::new()
        Mock New-AzResourceGroupDeployment {
            $attempts.Add(1)
            if ($attempts.Count -eq 1) { throw $featureError }
            @{ ProvisioningState = 'Succeeded' }
        }
        Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters
        Should -Invoke Register-AzProviderFeature -Times 0
        Should -Invoke Initialize-M365DscResourceProvider -Times 1 -Exactly
    }
    It 'Stops with approval guidance after a bounded pending-feature timeout without retrying deployment' {
        Mock New-AzResourceGroupDeployment { throw $featureError }
        Mock Get-AzProviderFeature { @{ RegistrationState = 'Pending' } }
        { Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters } |
            Should -Throw '*60 probes*Pending*Azure Support*'
        Should -Invoke Get-AzProviderFeature -Times 61 -Exactly
        Should -Invoke Start-Sleep -Times 59 -Exactly
        Should -Invoke Register-AzProviderFeature -Times 0
        Should -Invoke Initialize-M365DscResourceProvider -Times 0
        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly
    }
    It 'Propagates feature registration authorization errors without a deployment retry' {
        Mock New-AzResourceGroupDeployment { throw $featureError }
        Mock Get-AzProviderFeature { @{ RegistrationState = 'NotRegistered' } }
        Mock Register-AzProviderFeature { throw 'Synthetic AuthorizationFailed' }
        { Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters } |
            Should -Throw '*AuthorizationFailed*'
        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly
        Should -Invoke Initialize-M365DscResourceProvider -Times 0
    }
    It 'Refreshes only the namespace reported by a provider registration error and retries once' {
        $attempts = [Collections.Generic.List[int]]::new()
        Mock New-AzResourceGroupDeployment {
            $attempts.Add(1)
            if ($attempts.Count -eq 1) { throw "MissingSubscriptionRegistration: The subscription is not registered to use namespace 'Microsoft.Network'." }
            @{ ProvisioningState = 'Succeeded' }
        }
        Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters
        Should -Invoke Initialize-M365DscResourceProvider -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq 'synthetic-subscription' -and $ProviderNamespace -eq 'Microsoft.Network' -and $ForceRegistration
        }
        Should -Invoke Get-AzProviderFeature -Times 0
        Should -Invoke New-AzResourceGroupDeployment -Times 2 -Exactly
    }
    It 'Does not keep retrying when the same feature error remains after recovery' {
        Mock New-AzResourceGroupDeployment { throw $featureError }
        { Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters } |
            Should -Throw '*SubscriptionNotRegisteredForFeature*'
        Should -Invoke Initialize-M365DscResourceProvider -Times 1 -Exactly
        Should -Invoke New-AzResourceGroupDeployment -Times 2 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*still failed*Azure Support*' }
    }
    It 'Preserves unrelated or unidentifiable errors without registration changes' -TestCases @(
        @{ Message = 'AuthorizationFailed: permission denied' },
        @{ Message = 'SubscriptionNotRegisteredForFeature: no feature identified' },
        @{ Message = 'InvalidTemplate: invalid namespace Microsoft.Network' }
    ) {
        param($Message)
        Mock New-AzResourceGroupDeployment { throw $Message }
        { Invoke-M365DscResourceGroupDeployment -SubscriptionId 'synthetic-subscription' -DeploymentParameters $parameters } |
            Should -Throw "*$Message*"
        Should -Invoke Get-AzProviderFeature -Times 0
        Should -Invoke Initialize-M365DscResourceProvider -Times 0
        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly
    }
    It 'Rejects a different active subscription before attempting deployment or registration' {
        { Invoke-M365DscResourceGroupDeployment -SubscriptionId 'other-subscription' -DeploymentParameters $parameters } |
            Should -Throw '*does not match*'
        Should -Invoke New-AzResourceGroupDeployment -Times 0
        Should -Invoke Get-AzProviderFeature -Times 0
    }
}

Describe 'Worker VM provisioning backend isolation' {
    BeforeAll {
        $ast = Read-ProvisioningAst "$PSScriptRoot\..\..\lab\Azure\30 Create Agent VMs.ps1"
        $loop = $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.ForEachStatementAst] -and
            $_.Extent.Text -like '*Initialize-M365DscAgentKeyVaultPrivateEndpoint*'
        }
        $provision = [scriptblock]::Create($loop.Extent.Text)
        function Write-M365DscEnvironmentContext { param($EnvironmentName, $TenantName, $TenantId, $SubscriptionId, $KeyVaultName, $Operation) }
        function Connect-M365Dsc { [CmdletBinding()]param($TenantId, $TenantName, $SubscriptionId, $SkipExchangeOnline) }
        function Set-AzContext { [CmdletBinding()]param($TenantId, $SubscriptionId) }
        function Initialize-M365DscResourceProvider { [CmdletBinding()]param($SubscriptionId, $ProviderNamespace) }
        function Get-M365DscAgentVmName { param($ProjectName, $EnvironmentName) 'synthetic-vm' }
        function Get-M365DscAgentIdentityName { param($ProjectName, $EnvironmentName) 'synthetic-identity' }
        function Get-M365DscAgentResourceGroupName { param($ProjectName, $EnvironmentName) 'synthetic-rg' }
        function Get-M365DscAgentVm { param($ProjectName, $EnvironmentName) }
        function Get-M365DscSecretBackend { param($Datum) $Datum.Global.ProjectSettings.SecretStorage }
        function Get-AzVM { [CmdletBinding()]param($ResourceGroupName, $Name, [switch]$Status) }
        function Start-AzVM { [CmdletBinding()]param($ResourceGroupName, $Name) }
        function Initialize-M365DscAgentKeyVaultPrivateEndpoint { [CmdletBinding()]param($Datum, $EnvironmentName, $VM) }
        function Get-AzSnapshot { [CmdletBinding()]param($ResourceGroupName) }
        function New-AzSnapshotConfig { [CmdletBinding()]param($SourceResourceId, $Location, $CreateOption, $SkuName, $Tag) }
        function New-AzSnapshot { [CmdletBinding()]param($ResourceGroupName, $SnapshotName, $Snapshot) }
        function bicep {}
        function Get-AzResourceGroup { [CmdletBinding()]param() }
        function Invoke-M365DscResourceGroupDeployment { [CmdletBinding()]param($SubscriptionId, $DeploymentParameters) }
    }
    BeforeEach {
        $datum = @{ Global = @{
            ProjectSettings = @{ ProjectName = 'synthetic'; SecretStorage = 'Kdbx'; BuildAgents = @{ AzureLocation = 'westeurope' } }
            Azure = @{ Environments = @{ Dev = @{
                AzTenantName = 'synthetic.onmicrosoft.com'; AzTenantId = 'synthetic-tenant'
                AzSubscriptionId = 'synthetic-subscription'; HasExchangeOnline = $false
            } } }
        } }
        $environments = @('Dev')
        $vmResourceGroupNames = @{}
        $existingVm = @{
            Name = 'synthetic-vm'; ResourceGroupName = 'synthetic-rg'; Location = 'westeurope'
            Statuses = @(@{ Code = 'PowerState/running' })
            StorageProfile = @{ OsDisk = @{ ManagedDisk = @{ Id = 'synthetic-disk' } }; DataDisks = @() }
        }
        Mock Write-Host {}
        Mock Write-M365DscEnvironmentContext {}
        Mock Connect-M365Dsc {}
        Mock Set-AzContext {}
        Mock Initialize-M365DscResourceProvider {}
        Mock Get-M365DscAgentVm { $existingVm }
        Mock Get-AzVM { $existingVm }
        Mock Start-AzVM {}
        Mock Initialize-M365DscAgentKeyVaultPrivateEndpoint { throw 'Unexpected Key Vault access in KDBX provisioning.' }
        Mock Get-AzSnapshot { @() }
        Mock New-AzSnapshotConfig { @{ SourceResourceId = $SourceResourceId } }
        Mock New-AzSnapshot { @{ Name = $SnapshotName } }
    }
    It 'Reuses the existing KDBX VM and reaches disk snapshot creation without any Key Vault name' {
        & $provision
        $vmResourceGroupNames.Dev | Should -Be 'synthetic-rg'
        Should -Invoke Initialize-M365DscAgentKeyVaultPrivateEndpoint -Times 0
        Should -Invoke New-AzSnapshot -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'synthetic-rg' -and $SnapshotName -eq 'synthetic-vm-AfterInstall'
        }
    }
    It 'Checks the required providers in each selected subscription before looking up or provisioning VMs' {
        $datum.Global.Azure.Environments.Test = $datum.Global.Azure.Environments.Dev.Clone()
        $datum.Global.Azure.Environments.Test.AzSubscriptionId = 'synthetic-second-subscription'
        $environments = @('Dev', 'Test')
        $checked = [Collections.Generic.List[string]]::new()
        Mock Initialize-M365DscResourceProvider {
            $ProviderNamespace | Should -Be @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.ManagedIdentity')
            $checked.Add($SubscriptionId)
        }
        Mock Get-M365DscAgentVm {
            $checked | Should -Contain $datum.Global.Azure.Environments[$EnvironmentName].AzSubscriptionId
            $existingVm
        }
        & $provision
        $checked.ToArray() | Should -Be @('synthetic-subscription', 'synthetic-second-subscription')
    }
    It 'Stops before looking up or creating VM resources if required providers are not ready' {
        Mock Initialize-M365DscResourceProvider { throw 'Synthetic provider registration failed' }
        { & $provision } | Should -Throw '*provider registration failed*'
        Should -Invoke Get-M365DscAgentVm -Times 0
        Should -Invoke Get-AzVM -Times 0
        Should -Invoke New-AzSnapshot -Times 0
    }
    It 'Uses registration recovery for new VM deployments and continues only after success' {
        Mock Get-M365DscAgentVm { $null }
        Mock Get-AzResourceGroup { @{ ResourceGroupName = 'synthetic-rg' } }
        Mock Invoke-M365DscResourceGroupDeployment { @{ ProvisioningState = 'Succeeded' } }
        & $provision
        Should -Invoke Invoke-M365DscResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq 'synthetic-subscription' -and
            $DeploymentParameters.Name -eq 'build-agent-Dev' -and
            $DeploymentParameters.ResourceGroupName -eq 'synthetic-rg' -and
            $DeploymentParameters.TemplateFile -like '*buildAgent.bicep' -and
            $DeploymentParameters.TemplateParameterObject.vmName -eq 'synthetic-vm'
        }
        Should -Invoke New-AzSnapshot -Times 1 -Exactly
    }
    It 'Keeps Key Vault network initialization for the Key Vault workflow' {
        $datum.Global.ProjectSettings.SecretStorage = 'KeyVault'
        $datum.Global.Azure.Environments.Dev.KeyVaultName = 'synthetic-vault'
        Mock Initialize-M365DscAgentKeyVaultPrivateEndpoint {}
        & $provision
        Should -Invoke Initialize-M365DscAgentKeyVaultPrivateEndpoint -Times 1 -Exactly -ParameterFilter {
            $EnvironmentName -eq 'Dev' -and $Datum.Global.Azure.Environments.Dev.KeyVaultName -eq 'synthetic-vault'
        }
        Should -Invoke New-AzSnapshot -Times 1 -Exactly
    }
    It 'Does not hide a genuine Key Vault networking failure or continue to snapshots' {
        $datum.Global.ProjectSettings.SecretStorage = 'KeyVault'
        Mock Initialize-M365DscAgentKeyVaultPrivateEndpoint { throw 'Synthetic vault networking failure' }
        { & $provision } | Should -Throw '*vault networking failure*'
        Should -Invoke New-AzSnapshot -Times 0
    }
}

Describe 'KDBX protected worker delivery cleanup' {
    BeforeAll {
        $ast = Read-ProvisioningAst "$PSScriptRoot\..\..\lab\Azure\31 Agent Setup.ps1"
        $function = $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-WorkerVmScript'
        }
        . ([scriptblock]::Create($function.Extent.Text))
        function Set-AzVMRunCommand {
            [CmdletBinding()]param($ResourceGroupName, $VMName, $RunCommandName, $Location, $SourceScript,
                $AsyncExecution, $TimeoutInSecond, $ProtectedParameter)
        }
        function Get-AzVMRunCommand { [CmdletBinding()]param($ResourceGroupName, $VMName, $RunCommandName, $Expand) }
        function Remove-AzVMRunCommand { [CmdletBinding()]param($ResourceGroupName, $VMName, $RunCommandName) }
    }
    BeforeEach {
        $secretBackend = 'Kdbx'
        $vm = @{ Name = 'synthetic-vm'; ResourceGroupName = 'synthetic-rg'; Location = 'westeurope' }
        Mock Set-AzVMRunCommand {}
        Mock Get-AzVMRunCommand { @{ InstanceView = @{ ExecutionState = 'Succeeded'; ExitCode = 0 } } }
        Mock Remove-AzVMRunCommand {}
        Mock Start-Sleep {}
    }
    It 'Sends credential values only as protected parameters and removes successful command resources' {
        Invoke-WorkerVmScript -VM $vm -ScriptBlock { param($PfxPassword) } -Parameters @{ PfxPassword = 'synthetic-password' }
        Should -Invoke Set-AzVMRunCommand -Times 1 -Exactly -ParameterFilter {
            $ProtectedParameter[0].Name -eq 'PfxPassword' -and
            $ProtectedParameter[0].Value -eq 'synthetic-password' -and $SourceScript -notlike '*synthetic-password*'
        }
        Should -Invoke Remove-AzVMRunCommand -Times 1 -Exactly
    }
    It 'Removes credential-bearing command resources on polling failure without hiding the failure' {
        Mock Get-AzVMRunCommand { throw 'Synthetic polling failure' }
        { Invoke-WorkerVmScript -VM $vm -ScriptBlock {} -Parameters @{ PersonalAccessToken = 'synthetic-token' } } |
            Should -Throw '*polling failure*'
        Should -Invoke Remove-AzVMRunCommand -Times 1 -Exactly
    }
}
