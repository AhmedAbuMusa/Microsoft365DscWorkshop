Describe 'KDBX pipeline publisher script environment selection' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\..\lab\Secrets\Kdbx\PipelineSecrets.psm1" -Force
        $publisherScript = "$PSScriptRoot\..\..\lab\Secrets\Kdbx\Publish Pipeline Secrets.ps1"
    }
    BeforeEach {
        Mock Import-Module {} -ParameterFilter { $Name -like '*Store.psm1' -or $Name -like '*PipelineSecrets.psm1' }
        Mock Publish-M365DscKdbxPipelineSecrets {}
        $datum = @{ Global = @{ Azure = @{ Environments = @{} } } }
    }
    It 'Publishes all bootstrap environments using individual scalar names and forwards delivery options' {
        & $publisherScript -Datum $datum -EnvironmentName Dev,Test,Stage,Preprod,Prod `
            -TrustedPipelineId 7,8 -IncludeLcmCertificate
        Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 5 -Exactly
        foreach ($name in 'Dev','Test','Stage','Preprod','Prod')
        {
            Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 1 -Exactly -ParameterFilter {
                $EnvironmentName -is [string] -and $EnvironmentName -eq $name -and
                $TrustedPipelineId.Count -eq 2 -and $TrustedPipelineId[0] -eq 7 -and
                $TrustedPipelineId[1] -eq 8 -and $IncludeLcmCertificate -and $Datum -eq $datum
            }
        }
    }
    It 'Preserves single-environment publishing without requiring explicit pipeline IDs' {
        & $publisherScript -Datum $datum -EnvironmentName Dev
        Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 1 -Exactly -ParameterFilter {
            $EnvironmentName -eq 'Dev' -and -not $TrustedPipelineId -and -not $IncludeLcmCertificate
        }
    }
    It 'Reuses the loaded Datum version when creating configuration without an explicit Datum argument' {
        $requiredModulesPath = (Resolve-Path "$PSScriptRoot\..\..\output\RequiredModules").Path
        $previousModulePath = $env:PSModulePath
        $previousDatumModules = @(Get-Module -Name Datum)
        $env:PSModulePath += [IO.Path]::PathSeparator + $requiredModulesPath
        $availableDatum = @(Get-Module -Name Datum -ListAvailable | Sort-Object Version)
        $availableDatum.Count | Should -BeGreaterThan 0
        $loadedDatum = $null
        try
        {
            if (-not $previousDatumModules)
            {
                $loadedDatum = Import-Module -Name $availableDatum[0].Path -PassThru -ErrorAction Stop
            }
            $beforeVersions = @((Get-Module -Name Datum).Version)
            & $publisherScript -EnvironmentName Dev
            @((Get-Module -Name Datum).Version) | Should -Be $beforeVersions
            Should -Invoke Import-Module -Times 0 -ParameterFilter { $Name -eq 'Datum' }
            Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 1 -Exactly -ParameterFilter {
                $EnvironmentName -eq 'Dev' -and $Datum.Global.ProjectSettings -is [Collections.IDictionary]
            }
        }
        finally
        {
            if ($loadedDatum) { Remove-Module -ModuleInfo $loadedDatum -ErrorAction Stop }
            $env:PSModulePath = $previousModulePath
        }
    }
    It 'Propagates a publication failure without publishing later environments' {
        Mock Publish-M365DscKdbxPipelineSecrets { throw 'Synthetic Stage publication failure' } `
            -ParameterFilter { $EnvironmentName -eq 'Stage' }
        { & $publisherScript -Datum $datum -EnvironmentName Dev,Test,Stage,Prod } |
            Should -Throw '*Stage publication failure*'
        Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 1 -Exactly -ParameterFilter { $EnvironmentName -eq 'Dev' }
        Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 1 -Exactly -ParameterFilter { $EnvironmentName -eq 'Test' }
        Should -Invoke Publish-M365DscKdbxPipelineSecrets -Times 0 -ParameterFilter { $EnvironmentName -eq 'Prod' }
    }
}

Describe 'Explicit Kdbx native pipeline delivery' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\..\lab\Secrets\Kdbx\PipelineSecrets.psm1" -Force
        $script:storeStub = New-Module -Name KdbxPipelineSecretsTestStore -ScriptBlock {
            function Get-M365DscKdbxProjectSettings { param($Datum) $Datum }
            function Update-M365DscDatumFromKdbx { param($Datum, $EnvironmentName) $Datum }
            function Get-M365DscStoredCertificate { param($EnvironmentName, $IdentityName) }
            function Write-Build { param($Color, $Message) }
            function Export-M365DSCConfiguration { param($Components, $ApplicationId, $TenantId, $Path, $CertificateThumbprint) }
            function Update-M365DscDatumFromKeyVault { param($Datum) throw 'Unexpected Key Vault access' }
            Export-ModuleMember -Function *
        }
        Import-Module $script:storeStub
        function New-TestMetadata {
            param([string]$Alias = 'Dev', [string]$TenantName = 'dev.example.com',
                [string]$TenantId = '01234567-89ab-cdef-0123-456789abcdef')
            @{
                projectName = 'Workshop'
                environments = @{
                    $Alias = @{
                        AzTenantName = $TenantName
                        AzTenantId = $TenantId
                        AzSubscriptionId = '11111111-2222-3333-4444-555555555555'
                        HasExchangeOnline = $true
                        HasSharePointOnline = $false
                        Identities = @(
                            @{ Name = 'M365DscLcmApplication'; ApplicationId = '22222222-2222-3333-4444-555555555555'; CertificateThumbprint = 'A' * 40 }
                            @{ Name = 'M365DscExportApplication'; ApplicationId = '33333333-2222-3333-4444-555555555555'; CertificateThumbprint = 'B' * 40 }
                        )
                    }
                }
            }
        }
        function Write-TestMetadata {
            param($Metadata, [string]$Name = 'metadata.json')
            $path = Join-Path $TestDrive $Name
            $Metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
            $path
        }
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=PipelineTest', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:testCertificate = $request.CreateSelfSigned([datetimeoffset]::Now.AddDays(-1), [datetimeoffset]::Now.AddDays(1))
        $script:pfxBytes = $script:testCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'test-pfx-password')
        $rsa.Dispose()
    }

    AfterAll {
        $script:testCertificate.Dispose()
        Remove-Module $script:storeStub
        Remove-Module PipelineSecrets -ErrorAction SilentlyContinue
    }

    It 'Hydrates only the explicitly selected environment without private settings' {
        $path = Write-TestMetadata (New-TestMetadata)
        $datum = @{ Global = @{
            ProjectSettings = @{ ProjectName = '<ProjectName>'; OrganizationName = 'PublicPlaceholder' }
            Azure = @{ Environments = @{ Dev = @{ AzTenantId = '' }; Test = @{ AzTenantId = 'untouched' } } }
        } }

        $actual = Update-M365DscDatumFromPipelineMetadata -Datum $datum -Path $path -EnvironmentName Dev

        $actual.Global.ProjectSettings.ProjectName | Should -Be 'Workshop'
        $actual.Global.ProjectSettings.OrganizationName | Should -Be 'PublicPlaceholder'
        $actual.Global.Azure.Environments.Dev.AzTenantId | Should -Be '01234567-89ab-cdef-0123-456789abcdef'
        $actual.Global.Azure.Environments.Test.AzTenantId | Should -Be 'untouched'
    }

    It 'Rejects credentials outside the metadata allowlist at every level' {
        foreach ($location in 'project', 'environment', 'identity')
        {
            $metadata = New-TestMetadata
            switch ($location) {
                project { $metadata.PersonalAccessToken = 'must-not-travel' }
                environment { $metadata.environments.Dev.VmAdminPassword = 'must-not-travel' }
                identity { $metadata.environments.Dev.Identities[0].ApplicationSecret = 'must-not-travel' }
            }
            $path = Write-TestMetadata $metadata
            { ConvertFrom-M365DscPipelineMetadata -Path $path } | Should -Throw '*metadata*'
        }
    }

    It 'Refuses mismatched and multi-environment files instead of falling back' {
        $metadata = New-TestMetadata
        $path = Write-TestMetadata $metadata
        $datum = @{ Global = @{ Azure = @{ Environments = @{ Dev = @{}; Test = @{} } } } }
        { Update-M365DscDatumFromPipelineMetadata -Datum $datum -Path $path -EnvironmentName Test } | Should -Throw '*selected environment*'
        $metadata.environments.Test = (New-TestMetadata -Alias Test).environments.Test
        $path = Write-TestMetadata $metadata
        { Update-M365DscDatumFromPipelineMetadata -Datum $datum -Path $path -EnvironmentName Dev } | Should -Throw '*only selected*'
        { Update-M365DscDatumFromPipelineMetadata -Datum $datum -Path "$TestDrive\missing.json" -EnvironmentName Dev } | Should -Throw
    }

    It 'Rejects invalid tenant paths and missing certificate-only identities' {
        $metadata = New-TestMetadata -TenantName '..\outside'
        { ConvertFrom-M365DscPipelineMetadata -Path (Write-TestMetadata $metadata) } | Should -Throw '*tenant metadata*'
        $metadata = New-TestMetadata
        $metadata.environments.Dev.Identities = @($metadata.environments.Dev.Identities[0])
        { ConvertFrom-M365DscPipelineMetadata -Path (Write-TestMetadata $metadata) } | Should -Throw '*M365DscExportApplication*'
    }

    It 'Rejects a downloaded certificate with the wrong thumbprint or password before installing it' {
        $path = Join-Path $TestDrive 'certificate.pfx'
        [System.IO.File]::WriteAllBytes($path, $script:pfxBytes)
        { Import-M365DscPipelineCertificate -Path $path -Password (ConvertTo-SecureString 'test-pfx-password' -AsPlainText -Force) `
            -ExpectedThumbprint ('A' * 40) } | Should -Throw '*does not match*'
        { Import-M365DscPipelineCertificate -Path $path -Password (ConvertTo-SecureString 'wrong-password' -AsPlainText -Force) `
            -ExpectedThumbprint $script:testCertificate.Thumbprint } | Should -Throw
    }

    Context 'Native build and export runtime gates' {
        BeforeAll {
            Import-Module powershell-yaml
            $script:taskActions = @{}
            function task {
                param([string]$Name, [scriptblock]$Action)
                $script:taskActions[$Name] = $Action
            }
            . "$PSScriptRoot\..\..\.build\ConfigDataPreparation.ps1"
            . "$PSScriptRoot\..\..\.build\Export\ExportTenantData.ps1"
        }
        BeforeEach {
            $script:savedEnvironment = @{}
            foreach ($name in 'BuildEnvironment', 'M365DSC_SECRET_BACKEND', 'M365DSC_METADATA_PATH', 'M365DSC_EXPORT_PFX_PATH', 'M365DSC_EXPORT_PFX_PASSWORD')
            {
                $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $null)
            }
            $env:BuildEnvironment = 'Dev'
            $env:M365DSC_METADATA_PATH = Write-TestMetadata (New-TestMetadata)
            $BuildRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
            $ProjectPath = $BuildRoot
            $OutputDirectory = Join-Path $TestDrive 'output'
            $datum = @{ Global = @{
                ProjectSettings = @{ ProjectName = '<ProjectName>' }
                Azure = @{ Environments = @{ Dev = @{ AzTenantId = '' }; Test = @{ AzTenantId = ''; AzTenantName = '<PublicTestTenant>' } } }
            } }
            Mock Import-Module {} -ParameterFilter { $Name -like '*PipelineSecrets.psm1' }
            Mock Import-Module { throw 'Unexpected Key Vault import' } -ParameterFilter { $Name -like '*AzHelpers.psm1' -or $Name -like 'Az.*' }
            Mock Update-M365DscDatumFromKeyVault { throw 'Unexpected Key Vault access' }
        }
        AfterEach {
            foreach ($name in $script:savedEnvironment.Keys)
            {
                [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
            }
            Remove-Variable azBuildParameters -Scope Global -ErrorAction SilentlyContinue
        }

        It 'Builds selected native metadata and retains synthetic parameters for unselected public environments' {
            . $script:taskActions.ConfigDataPreparation

            $global:azBuildParameters.Dev.AzTenantId | Should -Be '01234567-89ab-cdef-0123-456789abcdef'
            $global:azBuildParameters.Test.AzTenantId | Should -Match '^[a-f0-9-]{36}$'
            $global:azBuildParameters.Test.Identities | Should -HaveCount 2
            Should -Invoke Update-M365DscDatumFromKeyVault -Times 0
            Should -Invoke Import-Module -Times 0 -ParameterFilter { $Name -like '*AzHelpers.psm1' -or $Name -like 'Az.*' }
        }

        It 'Fails closed if an environment or downloaded metadata file is missing' {
            $env:BuildEnvironment = ''
            { . $script:taskActions.ConfigDataPreparation } | Should -Throw '*BuildEnvironment is required*'
            $env:BuildEnvironment = 'Dev'
            $env:M365DSC_METADATA_PATH = "$TestDrive\missing.json"
            { . $script:taskActions.ConfigDataPreparation } | Should -Throw
            Should -Invoke Update-M365DscDatumFromKeyVault -Times 0
        }

        It 'Keeps the clean Kdbx bootstrap child template-only without accessing Azure or the database' {
            $env:M365DSC_SECRET_BACKEND = 'Kdbx'
            $env:BuildEnvironment = ''
            $env:M365DSC_METADATA_PATH = ''
            $datum.Global.ProjectSettings.ProjectName = 'ExistingPublicProject'
            Mock Get-M365DscKdbxProjectSettings { throw 'Unexpected database access' }
            Mock Update-M365DscDatumFromKdbx { throw 'Unexpected database access' }

            . $script:taskActions.ConfigDataPreparation

            $datum.Global.ProjectSettings.ProjectName | Should -Be 'ExistingPublicProject'
            $global:azBuildParameters.Dev.AzTenantId | Should -Match '^[a-f0-9-]{36}$'
            Should -Invoke Import-Module -Times 0
            Should -Invoke Update-M365DscDatumFromKeyVault -Times 0
            Should -Invoke Get-M365DscKdbxProjectSettings -Times 0
            Should -Invoke Update-M365DscDatumFromKdbx -Times 0
        }

        It 'Requires native metadata for an operational Kdbx build or export' {
            $env:M365DSC_SECRET_BACKEND = 'Kdbx'
            $env:M365DSC_METADATA_PATH = ''
            { . $script:taskActions.ConfigDataPreparation } | Should -Throw '*Operational Kdbx builds require*'
            { . $script:taskActions.ExportTenantData } | Should -Throw '*requires M365DSC_METADATA_PATH*'
            Should -Invoke Update-M365DscDatumFromKeyVault -Times 0
        }

        It 'Requires certificate delivery before export rather than falling back to Key Vault' {
            { . $script:taskActions.ExportTenantData } | Should -Throw '*M365DSC_EXPORT_PFX_PATH*'
            Should -Invoke Update-M365DscDatumFromKeyVault -Times 0
        }

        It 'Removes only the certificate it imported even when an export fails' {
            $env:M365DSC_EXPORT_PFX_PATH = "$TestDrive\export.pfx"
            $env:M365DSC_EXPORT_PFX_PASSWORD = 'secret-export-password'
            Mock Import-M365DscPipelineCertificate { @{ Imported = $true; Path = 'Cert:\CurrentUser\My\test'; Thumbprint = 'B' * 40 } }
            Mock Remove-M365DscPipelineCertificate {}
            Mock Export-M365DSCConfiguration { throw 'native export failed' }

            { . $script:taskActions.ExportTenantData } | Should -Throw '*native export failed*'
            Should -Invoke Import-M365DscPipelineCertificate -Times 1 -ParameterFilter { $ExpectedThumbprint -eq ('B' * 40) -and $Password -is [securestring] }
            Should -Invoke Remove-M365DscPipelineCertificate -Times 1 -ParameterFilter { $Certificate.Imported }
            Should -Invoke Update-M365DscDatumFromKeyVault -Times 0
        }
    }

    Context 'Publisher with mocked Azure DevOps' {
        BeforeEach {
            $script:uploads = @()
            $script:requests = @()
            $script:metadata = New-TestMetadata
            foreach ($identity in $script:metadata.environments.Dev.Identities)
            {
                $identity.CertificateThumbprint = $script:testCertificate.Thumbprint
                $identity.ApplicationSecret = 'not-allowed-in-delivery'
            }
            $script:publisherDatum = @{
                Global = @{
                    ProjectSettings = @{
                        OrganizationName = 'TestOrganization'; ProjectName = 'Workshop'; PersonalAccessToken = 'private-pat'; AgentPoolName = 'PrivatePool'
                        VmAdminPassword = 'private-vm-password'; KdbxPassphrase = 'private-db-password'
                    }
                    Azure = @{ Environments = $script:metadata.environments }
                }
            }
            Mock Get-M365DscKdbxProjectSettings -ModuleName PipelineSecrets { $Datum }
            Mock Update-M365DscDatumFromKdbx -ModuleName PipelineSecrets { $Datum }
            Mock Get-M365DscStoredCertificate -ModuleName PipelineSecrets {
                @{ Pfx = $script:pfxBytes; Password = ConvertTo-SecureString 'test-pfx-password' -AsPlainText -Force; Thumbprint = $script:testCertificate.Thumbprint }
            }
            Mock Invoke-RestMethod -ModuleName PipelineSecrets {
                param($Uri, $Method, $Headers, $Body, $InFile, $ContentType)
                $script:requests += @{ Uri = $Uri; Method = $Method; Body = $Body }
                if ($Uri -like '*_apis/projects/*') { return @{ id = 'project-id' } }
                if ($Uri -like '*build/definitions/7?*') { return @{ process = @{ yamlFilename = 'pipelines/Kdbx/build.yml' } } }
                if ($Uri -like '*build/definitions/8?*') { return @{ process = @{ yamlFilename = 'pipelines/Kdbx/export.yml' } } }
                if ($Uri -like '*build/definitions*') {
                    return @{ value = @(
                        @{ id = 7; name = 'M365DSC build'; process = @{ yamlFilename = 'pipelines/Kdbx/build.yml' } }
                        @{ id = 8; name = 'M365DSC export'; process = @{ yamlFilename = 'pipelines/Kdbx/export.yml' } }
                        @{ id = 9; name = 'Untrusted pipeline' }
                    ) }
                }
                if ($Uri -like '*pipelinepermissions*') {
                    if ($Method -eq 'Get') { return @{ allPipelines = @{ authorized = $true }; pipelines = @(@{ id = 9; authorized = $true }) } }
                    return @{}
                }
                if ($Uri -like '*securefiles*') {
                    if ($Method -eq 'Post') {
                        $script:uploads += @{
                            Name = [uri]::UnescapeDataString(($Uri -split 'name=')[1].Split('&')[0])
                            Bytes = [System.IO.File]::ReadAllBytes($InFile)
                            ContentType = $ContentType
                        }
                        return @{ id = "file-$($script:uploads.Count)" }
                    }
                    return @{ value = @() }
                }
                if ($Uri -like '*variablegroups*') {
                    if ($Method -eq 'Post' -or $Method -eq 'Put') { return @{ id = 42 } }
                    return @{ value = @() }
                }
                throw "Unexpected URI '$Uri'"
            }
        }

        It 'Uploads allowlisted metadata and binary PFX, masks passwords and revokes untrusted pipeline authorization' {
            $result = Publish-M365DscKdbxPipelineSecrets -Datum $script:publisherDatum -EnvironmentName Dev

            $result.VariableGroup | Should -Be 'M365DSC-Dev-Kdbx'
            $result.PipelineIds | Should -Be @(7, 8)
            $script:uploads | Should -HaveCount 2
            $pfx = @($script:uploads | Where-Object Name -Like '*.pfx')[0]
            [Convert]::ToBase64String($pfx.Bytes) | Should -Be ([Convert]::ToBase64String($script:pfxBytes))
            $pfx.ContentType | Should -Be 'application/octet-stream'
            $metadataText = [Text.Encoding]::UTF8.GetString(@($script:uploads | Where-Object Name -Like '*.json')[0].Bytes)
            $metadataText | Should -Not -Match 'private-pat|private-vm-password|private-db-password|not-allowed-in-delivery|OrganizationName'
            $uploadedMetadata = $metadataText | ConvertFrom-Json -AsHashtable
            $uploadedMetadata.Keys.Count | Should -Be 2
            $uploadedMetadata.environments.Keys | Should -Be @('Dev')
            $group = @($script:requests | Where-Object { $_.Uri -like '*variablegroups*' -and $_.Method -eq 'Post' })[0].Body | ConvertFrom-Json -AsHashtable
            $group.variables.M365DSC_EXPORT_PFX_PASSWORD.isSecret | Should -BeTrue
            $group.variables.M365DSC_EXPORT_PFX_PASSWORD.value | Should -Be 'test-pfx-password'
            $group.variables.ContainsKey('M365DSC_LCM_PFX_PASSWORD') | Should -BeFalse
            $group.variables.M365DSC_AGENT_POOL.value | Should -Be 'PrivatePool'
            $group.variables.Keys.Count | Should -Be 4
            foreach ($request in @($script:requests | Where-Object Method -EQ Patch))
            {
                $permissions = $request.Body | ConvertFrom-Json -AsHashtable
                $permissions.allPipelines.authorized | Should -BeFalse
                @($permissions.pipelines | Where-Object authorized -EQ $true).id | Should -Be @(7, 8)
                @($permissions.pipelines | Where-Object id -EQ 9)[0].authorized | Should -BeFalse
            }
            Get-ChildItem -Path . -Directory -Filter '.kdbx-publish-*' | Should -BeNullOrEmpty
        }

        It 'Accepts only existing explicit pipeline IDs and uploads LCM PFX only when requested' {
            { Publish-M365DscKdbxPipelineSecrets -Datum $script:publisherDatum -EnvironmentName Dev -TrustedPipelineId 404 } | Should -Throw '*existing explicit*'
            $script:uploads | Should -HaveCount 0
            $result = Publish-M365DscKdbxPipelineSecrets -Datum $script:publisherDatum -EnvironmentName Dev -TrustedPipelineId 8 -IncludeLcmCertificate
            $result.PipelineIds | Should -Be @(8)
            $result.SecureFiles | Should -Contain 'M365DSC-Dev-Kdbx.Lcm.pfx'
            $script:uploads | Should -HaveCount 3
        }

        It 'Cleans the local staging directory when native upload fails' {
            Mock Invoke-RestMethod -ModuleName PipelineSecrets { throw 'upload failed' } -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*securefiles*' }
            { Publish-M365DscKdbxPipelineSecrets -Datum $script:publisherDatum -EnvironmentName Dev -TrustedPipelineId 7 } | Should -Throw '*upload failed*'
            Get-ChildItem -Path . -Directory -Filter '.kdbx-publish-*' | Should -BeNullOrEmpty
        }

        It 'Refuses trusted names still pointing to Key Vault pipeline YAML' {
            Mock Invoke-RestMethod -ModuleName PipelineSecrets {
                @{ process = @{ yamlFilename = 'pipelines/build.yml' } }
            } -ParameterFilter { $Uri -like '*build/definitions/7?*' }
            { Publish-M365DscKdbxPipelineSecrets -Datum $script:publisherDatum -EnvironmentName Dev } | Should -Throw '*refusing to authorize*'
            $script:uploads | Should -HaveCount 0
        }
    }
}
