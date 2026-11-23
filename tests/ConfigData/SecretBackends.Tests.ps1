BeforeAll {
    $env:PSModulePath += [IO.Path]::PathSeparator + (Join-Path $PSScriptRoot '..\..\output\RequiredModules')
    Import-Module $PSScriptRoot\..\..\lab\Azure\AzHelpers.psm1 -Global -ErrorAction Stop
    Import-Module $PSScriptRoot\..\..\lab\Secrets\SecretBackend.psm1 -Force
    Import-Module $PSScriptRoot\..\..\lab\Secrets\KeyVault\PublicEndpoint.psm1 -Force
    Import-Module $PSScriptRoot\..\..\lab\Secrets\Kdbx\Store.psm1 -Force
}
Describe 'Explicit side-by-side backend routing' {
    BeforeEach {
        $oldBackend = $env:M365DSC_SECRET_BACKEND
        $oldPublicOnly = $env:M365DSC_KEYVAULT_PUBLIC_ONLY
        $env:M365DSC_SECRET_BACKEND = $null
        $datum = @{ Global = @{ ProjectSettings = @{} } }
    }
    AfterEach {
        $env:M365DSC_SECRET_BACKEND = $oldBackend
        $env:M365DSC_KEYVAULT_PUBLIC_ONLY = $oldPublicOnly
    }
    It 'Prompts for KDBX or Key Vault and accepts an explicit noninteractive selection without prompting' {
        Mock -ModuleName SecretBackend Read-Host { '2' }
        Select-M365DscSecretBackend -Datum $datum | Should -Be 'Kdbx'
        Select-M365DscSecretBackend -Backend KeyVault -Datum $datum | Should -Be 'KeyVault'
        Should -Invoke -ModuleName SecretBackend Read-Host -Times 1 -Exactly
    }
    It 'Keeps the saved choice when Enter is pressed and rejects invalid choices' {
        $datum.Global.ProjectSettings.SecretStorage = 'Kdbx'
        Mock -ModuleName SecretBackend Read-Host { '' }
        Select-M365DscSecretBackend -Datum $datum | Should -Be 'Kdbx'
        Mock -ModuleName SecretBackend Read-Host { 'invalid' }
        { Select-M365DscSecretBackend -Datum $datum } | Should -Throw '*No backend was selected*'
    }
    It 'Preserves legacy Key Vault routing and never falls back to KDBX on access failure' {
        Mock -ModuleName SecretBackend Get-M365DscProjectSettingsFromKeyVault { throw 'Synthetic vault access denied' }
        Mock -ModuleName SecretBackend Import-KdbxBackend { throw 'Must not load KDBX' }
        { Get-M365DscProjectSecrets -Datum $datum } | Should -Throw '*vault access denied*'
        Should -Invoke -ModuleName SecretBackend Import-KdbxBackend -Times 0
    }
    It 'Routes KDBX hydration without attempting any Key Vault call' {
        $datum.Global.ProjectSettings.SecretStorage = 'Kdbx'
        Mock -ModuleName SecretBackend Get-M365DscProjectSettingsFromKeyVault { throw 'Must not access Key Vault' }
        Mock -ModuleName SecretBackend Import-KdbxBackend {}
        Mock -ModuleName SecretBackend Get-M365DscKdbxProjectSettings {
            $Datum.Global.ProjectSettings.ProjectName = 'synthetic-private'; return $Datum
        }
        (Get-M365DscProjectSecrets -Datum $datum).Global.ProjectSettings.ProjectName | Should -Be 'synthetic-private'
        Should -Invoke -ModuleName SecretBackend Get-M365DscProjectSettingsFromKeyVault -Times 0
    }
    It 'Updates only the public backend selector and preserves unrelated YAML bytes' {
        $path = Join-Path $TestDrive 'ProjectSettings.yml'
        $original = "SecretStorage: KeyVault`r`nProjectName: '<ProjectName>' # keep`r`nOther: true`r`n"
        [IO.File]::WriteAllText($path, $original)
        Set-M365DscSecretBackendSetting -Path $path -Backend Kdbx
        [IO.File]::ReadAllText($path) | Should -Be ($original.Replace('SecretStorage: KeyVault','SecretStorage: Kdbx'))
    }
    It 'Does not treat a managed identity as a KDBX master password' {
        $datum.Global.ProjectSettings.SecretStorage = 'Kdbx'
        { Update-M365DscEnvironmentMetadata -Datum $datum -ProjectName synthetic -ManagedIdentity } |
            Should -Throw '*cannot be unlocked using a managed identity*'
    }
    It 'Refuses the legacy Key Vault initializer when the configured backend is KDBX' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\..\..\lab\Azure\04 Setup Project Settings Key Vault.ps1", [ref]$tokens, [ref]$errors)
        $guard = $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text -like '*Get-M365DscSecretBackend*'
        }
        $datum.Global.ProjectSettings.SecretStorage = 'Kdbx'
        { & ([scriptblock]::Create($guard.Extent.Text)) } | Should -Throw '*will not access Azure resources*'
    }
}

Describe 'Public-only Key Vault provisioning' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\..\..\lab\Azure\AzHelpers.psm1", [ref]$tokens, [ref]$errors)
        foreach ($function in $ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Name -in 'Resolve-M365DscKeyVaultNetworkParameters','Get-M365DscKeyVaultNetworkParameters'
        }) { . ([scriptblock]::Create($function.Extent.Text)) }
    }
    BeforeEach {
        $oldPublicOnly = $env:M365DSC_KEYVAULT_PUBLIC_ONLY
        $env:M365DSC_KEYVAULT_PUBLIC_ONLY = '1'
    }
    AfterEach { $env:M365DSC_KEYVAULT_PUBLIC_ONLY = $oldPublicOnly }
    It 'Refuses a private-only vault before discovering or creating endpoint networking' {
        { Resolve-M365DscKeyVaultNetworkParameters -Vault @{ PublicNetworkAccess = 'Disabled' } -EnvironmentName Stage } |
            Should -Throw '*Select Kdbx explicitly*'
    }
    It 'Does not adopt private endpoints from old tags on a public-enabled vault' {
        $result = Resolve-M365DscKeyVaultNetworkParameters -Vault @{
            PublicNetworkAccess = 'Enabled'; Tags = @{ M365DscPrivateEndpointSubnetId = 'unrelated-old-subnet' }
        } -EnvironmentName Dev
        $result.Count | Should -Be 0
    }
    It 'Rejects explicit endpoint parameters in public-only mode and ignores configured network discovery' {
        { Resolve-M365DscKeyVaultNetworkParameters -Vault @{ PublicNetworkAccess = 'Enabled' } -EnvironmentName Dev -PrivateEndpointSubnetId 'synthetic-subnet' } |
            Should -Throw '*cannot accept private endpoint*'
        (Get-M365DscKeyVaultNetworkParameters -Datum @{
            Global = @{ ProjectSettings = @{ KeyVaultPublicOnly = $true; KeyVaultNetworking = @{ Dev = @{ PrivateEndpointSubnetId = 'synthetic-subnet' } } } }
        } -EnvironmentName Dev).Count | Should -Be 0
    }
}

Describe 'Backend-bound bootstrap checkpoints' {
    It 'Produces different fingerprints for another backend or another KDBX deployment' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\..\..\lab\Start Azure Lab.ps1", [ref]$tokens, [ref]$errors)
        $assignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'resumeIdentity'
        }, $true)
        $buildIdentity = [scriptblock]::Create($assignment.Extent.Text + "`n" + '$resumeIdentity | ConvertTo-Json -Depth 10 -Compress')
        $sourceProjectSettings = @{ BuildAgents = @{} }
        $script:EnvironmentNames = @()
        $repositoryRoot = 'C:\SyntheticSource'
        $resolvedLocalPath = 'C:\SyntheticTarget'
        function Get-M365DscDeploymentId { return $deployment }
        Mock Import-Module {}
        $SecretBackend = 'KeyVault'
        $keyVault = & $buildIdentity
        $SecretBackend = 'Kdbx'
        $deployment = 'first-synthetic-deployment'
        $first = & $buildIdentity
        $deployment = 'second-synthetic-deployment'
        $second = & $buildIdentity
        $hashes = @($keyVault,$first,$second | ForEach-Object {
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_)))
        } | Sort-Object -Unique)
        $hashes | Should -HaveCount 3
    }
}
