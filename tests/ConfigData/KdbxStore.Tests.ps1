BeforeAll {
    Import-Module $PSScriptRoot\..\..\lab\Secrets\Kdbx\Store.psm1 -Force
}
Describe 'Separate KDBX operator storage' {
    BeforeEach {
        $path = Join-Path $TestDrive "$([Guid]::NewGuid().ToString('N'))\operator.kdbx"
        $password = ConvertTo-SecureString 'synthetic-long-passphrase' -AsPlainText -Force
        $previousPath = $env:M365DSC_SECRET_STORE
    }
    AfterEach {
        Close-M365DscSecretStore
        $password.Dispose()
        $env:M365DSC_SECRET_STORE = $previousPath
    }
    It 'Opens a copied encrypted database with only the password, rejects a wrong password and coexists with Azure modules' {
        Open-M365DscSecretStore -Path $path -Password $password -Create
        $value = ConvertTo-SecureString 'synthetic-secret-value' -AsPlainText -Force
        try { Set-M365DscSecret -Name 'test' -Value $value } finally { $value.Dispose() }
        $deployment = Get-M365DscDeploymentId
        $versions = Import-PowerShellDataFile $PSScriptRoot\..\..\RequiredModules.psd1
        $moduleRoot = Join-Path $PSScriptRoot '..\..\output\RequiredModules'
        foreach ($name in 'Az.Resources','Az.KeyVault') {
            Import-Module (Join-Path $moduleRoot "$name\$($versions[$name])\$name.psd1") -ErrorAction Stop
        }
        Close-M365DscSecretStore
        $copy = Join-Path $TestDrive 'copy\operator.kdbx'
        $null = New-Item (Split-Path $copy) -ItemType Directory
        Copy-Item -LiteralPath $path -Destination $copy
        $wrong = ConvertTo-SecureString 'wrong-synthetic-password' -AsPlainText -Force
        try { { Open-M365DscSecretStore -Path $copy -Password $wrong } | Should -Throw '*Could not open*' }
        finally { $wrong.Dispose() }
        Open-M365DscSecretStore -Path $copy -Password $password
        Get-M365DscDeploymentId | Should -Be $deployment
        $restored = Get-M365DscSecret -Name 'test'
        try { [Net.NetworkCredential]::new('', $restored).Password | Should -Be 'synthetic-secret-value' }
        finally { $restored.Dispose() }
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($copy)) | Should -Not -Match 'synthetic-secret-value'
    }
    It 'Rejects Git checkout paths without creating any database' {
        { Open-M365DscSecretStore -Path "$PSScriptRoot\operator.kdbx" -Password $password -Create } |
            Should -Throw '*outside every Git checkout*'
    }
    It 'Retries incorrect and empty interactive passphrases without changing the saved database' {
        Open-M365DscSecretStore -Path $path -Password $password -Create
        $deploymentId = Get-M365DscDeploymentId
        Close-M365DscSecretStore
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $answers = [Collections.Generic.Queue[securestring]]::new()
        $answers.Enqueue((ConvertTo-SecureString 'synthetic-incorrect' -AsPlainText -Force))
        $answers.Enqueue([securestring]::new())
        $answers.Enqueue($password.Copy())
        Mock Read-Host -ModuleName Store { $answers.Dequeue() }
        Mock Write-Warning -ModuleName Store {}
        Open-M365DscSecretStore -Path $path
        Get-M365DscDeploymentId | Should -Be $deploymentId
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        Should -Invoke Read-Host -ModuleName Store -Times 3 -Exactly -ParameterFilter { $AsSecureString }
        Should -Invoke Write-Warning -ModuleName Store -Times 2 -Exactly -ParameterFilter { $Message -like '*Ctrl+C*' }
    }
    It 'Does not prompt again for a locked database or an explicit incorrect password' {
        Open-M365DscSecretStore -Path $path -Password $password -Create
        Close-M365DscSecretStore
        Mock Read-Host -ModuleName Store { $password.Copy() }
        $lock = [IO.File]::Open("$path.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { Open-M365DscSecretStore -Path $path } | Should -Throw '*Could not open*' }
        finally { $lock.Dispose() }
        Should -Invoke Read-Host -ModuleName Store -Times 1 -Exactly
        $wrong = ConvertTo-SecureString 'synthetic-incorrect' -AsPlainText -Force
        try { { Open-M365DscSecretStore -Path $path -Password $wrong } | Should -Throw '*Could not open*' }
        finally { $wrong.Dispose() }
        Should -Invoke Read-Host -ModuleName Store -Times 1 -Exactly
    }
    It 'Hydrates private project and environment records through the common adapter without Key Vault access' {
        Import-Module $PSScriptRoot\..\..\lab\Secrets\SecretBackend.psm1 -Force
        Open-M365DscSecretStore -Path $path -Password $password -Create
        Set-M365DscSecretJson -Name ProjectSettings -Value @{
            SecretStorage = 'Kdbx'; OrganizationName = 'synthetic-org'; ProjectName = 'synthetic-project'
            RepositoryName = 'synthetic-repo'; LocalPath = 'C:\SyntheticTarget'; AgentPoolName = 'synthetic-pool'
            PersonalAccessToken = 'synthetic-pat'
        }
        Set-M365DscSecretJson -Name 'Environment/Dev' -Value @{
            AzTenantName = 'synthetic.onmicrosoft.com'; AzTenantId = 'synthetic-tenant'
            AzSubscriptionId = 'synthetic-subscription'
            Identities = @(@{ Name = 'M365DscSetupApplication'; ApplicationId = 'synthetic-app'; CertificateThumbprint = 'synthetic-thumbprint' })
        }
        $datum = @{ Global = @{
            ProjectSettings = @{ SecretStorage = 'Kdbx' }
            Azure = @{ Environments = @{ Dev = @{ AzTenantName = 'synthetic.onmicrosoft.com' } } }
        } }
        $oldBackend = $env:M365DSC_SECRET_BACKEND
        $env:M365DSC_SECRET_BACKEND = 'Kdbx'
        try {
            $hydrated = Get-M365DscProjectSecrets -Datum $datum
            $hydrated.Global.ProjectSettings.PersonalAccessToken | Should -Be 'synthetic-pat'
            $hydrated = Update-M365DscEnvironmentMetadata -Datum $datum -ProjectName 'ignored-public-placeholder' -EnvironmentName Dev
            $hydrated.Global.Azure.Environments.Dev.AzTenantId | Should -Be 'synthetic-tenant'
            $hydrated.Global.Azure.Environments.Dev.AzTenantName = 'another.onmicrosoft.com'
            { Update-M365DscEnvironmentMetadata -Datum $datum -ProjectName synthetic -EnvironmentName Dev } |
                Should -Throw '*does not match*'
        } finally { $env:M365DSC_SECRET_BACKEND = $oldBackend }
    }
    It 'Rolls back unsaved values when encrypted atomic persistence fails' {
        Open-M365DscSecretStore -Path $path -Password $password -Create
        Mock -ModuleName Store Save-KdbxStore { throw 'Synthetic persistence failure' }
        $value = ConvertTo-SecureString 'synthetic-only' -AsPlainText -Force
        try { { Set-M365DscSecret -Name 'unsaved' -Value $value } | Should -Throw '*persistence failure*' }
        finally { $value.Dispose() }
        Test-M365DscSecret -Name 'unsaved' | Should -BeFalse
    }
    It 'Hydrates the real Datum file provider without assigning its read-only project settings accessor' {
        $env:PSModulePath += [IO.Path]::PathSeparator + (Join-Path $PSScriptRoot '..\..\output\RequiredModules')
        Import-Module Datum -ErrorAction Stop
        Import-Module Datum.ProtectedData -ErrorAction Stop
        Open-M365DscSecretStore -Path $path -Password $password -Create
        Set-M365DscSecretJson -Name ProjectSettings -Value @{
            SecretStorage = 'Kdbx'; OrganizationName = 'synthetic-org'; ProjectName = 'synthetic-project'
            RepositoryName = 'synthetic-repo'; LocalPath = 'C:\SyntheticTarget'; AgentPoolName = 'synthetic-pool'
            PersonalAccessToken = 'synthetic-pat'; BuildAgents = @{ Password = 'synthetic-worker-password' }
        }
        $datum = New-DatumStructure -DefinitionFile "$PSScriptRoot\..\..\source\Datum.yml"
        $publicSettings = Get-Content -LiteralPath "$PSScriptRoot\..\..\source\Global\ProjectSettings.yml" -Raw
        $hydrated = Get-M365DscKdbxProjectSettings -Datum $datum
        $hydrated.Global.ProjectSettings.ProjectName | Should -Be 'synthetic-project'
        $hydrated.Global.ProjectSettings.PersonalAccessToken | Should -Be 'synthetic-pat'
        $hydrated.Global.ProjectSettings.BuildAgents.Password | Should -Be 'synthetic-worker-password'
        Set-M365DscSecretJson -Name Environment/Dev -Value @{
            AzSubscriptionId = 'synthetic-subscription'; AzTenantId = 'synthetic-tenant'
            AzTenantName = $datum.Global.Azure.Environments.Dev.AzTenantName
            Identities = @(@{ Name = 'Export'; ApplicationId = 'synthetic-application' })
        }
        $hydrated = Update-M365DscDatumFromKdbx -Datum $datum -EnvironmentName Dev
        $hydrated.Global.Azure.Environments.Dev.AzSubscriptionId | Should -Be 'synthetic-subscription'
        $hydrated.Global.Azure.Environments.Dev.AzTenantId | Should -Be 'synthetic-tenant'
        (Get-Content -LiteralPath "$PSScriptRoot\..\..\source\Global\ProjectSettings.yml" -Raw) | Should -Be $publicSettings
    }
    It 'Rejects tampered encrypted data' {
        Open-M365DscSecretStore -Path $path -Password $password -Create
        Close-M365DscSecretStore
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[$bytes.Length - 20] = $bytes[$bytes.Length - 20] -bxor 1
        [IO.File]::WriteAllBytes($path, $bytes)
        { Open-M365DscSecretStore -Path $path -Password $password } | Should -Throw '*Could not open*'
        Mock Read-Host -ModuleName Store { $password.Copy() }
        { Open-M365DscSecretStore -Path $path } | Should -Throw '*Could not open*'
        Should -Invoke Read-Host -ModuleName Store -Times 1 -Exactly
    }
    It 'Recovers the encrypted PFX attachment with its original private key' {
        Open-M365DscSecretStore -Path $path -Password $password -Create
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $certificate = $null
        $pfxPassword = ConvertTo-SecureString 'synthetic-pfx-password' -AsPlainText -Force
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=SyntheticKdbxTest', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddDays(1))
            $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxPassword)
            Set-M365DscSecret -Name 'Certificate/Dev/M365DscLcmApplication' -Value $pfxPassword -Attachment $pfx
            Close-M365DscSecretStore
            Open-M365DscSecretStore -Path $path -Password $password
            $stored = Get-M365DscStoredCertificate -EnvironmentName Dev -IdentityName M365DscLcmApplication
            try {
                $stored.Thumbprint | Should -Be $certificate.Thumbprint
                $stored.Pfx | Should -Be $pfx
            } finally {
                $stored.Password.Dispose()
                [Array]::Clear($stored.Pfx, 0, $stored.Pfx.Length)
            }
        } finally {
            if ($certificate) { $certificate.Dispose() }
            $rsa.Dispose()
            $pfxPassword.Dispose()
        }
    }
}
