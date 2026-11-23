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
