Describe 'Delta report tenant identifier anonymization' {
    BeforeAll {
        . "$PSScriptRoot\..\..\.build\Export\DeltaReport.Helpers.ps1"
    }

    It 'Replaces mapped tenant domains and GUIDs without replacing unrelated identifiers' {
        $reportPath = Join-Path -Path $TestDrive -ChildPath 'delta.html'
        Set-Content -LiteralPath $reportPath -Value '<html>DEV.EXAMPLE.COM 01234567-89AB-CDEF-0123-456789ABCDEF 11111111-2222-3333-4444-555555555555</html>' -NoNewline
        $tenantIdentifierMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $tenantIdentifierMap['dev.example.com'] = 'Dev'
        $tenantIdentifierMap['01234567-89ab-cdef-0123-456789abcdef'] = 'Dev'

        Convert-DeltaReportTenantIdentifiers -Path $reportPath -TenantIdentifierMap $tenantIdentifierMap

        Get-Content -LiteralPath $reportPath -Raw | Should -Be '<html>Dev Dev 11111111-2222-3333-4444-555555555555</html>'
    }

    It 'Fails rather than silently skipping a missing report' {
        $tenantIdentifierMap = @{ 'dev.example.com' = 'Dev' }

        { Convert-DeltaReportTenantIdentifiers -Path (Join-Path $TestDrive 'missing.html') -TenantIdentifierMap $tenantIdentifierMap } |
            Should -Throw '*was not found*'
    }

    It 'Exposes a disabled-by-default pipeline option and passes it to the report task' {
        $pipelinePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\pipelines\deltaReport.yml'
        $pipeline = Get-Content -LiteralPath $pipelinePath -Raw | ConvertFrom-Yaml -ErrorAction Stop
        $parameter = @($pipeline.parameters | Where-Object name -EQ 'anonymizeTenantIdentifiers')

        $parameter | Should -HaveCount 1
        $parameter[0].type | Should -Be 'boolean'
        $parameter[0].default | Should -BeFalse
        $pipeline.steps[-2].env.DeltaReportAnonymizeTenantIdentifiers | Should -Be '${{ parameters.anonymizeTenantIdentifiers }}'
    }
}

Describe 'Kdbx delta report native metadata' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\..\lab\Secrets\Kdbx\PipelineSecrets.psm1" -Force
        function Write-DeltaMetadata {
            param([string]$Alias, [string]$TenantName, [string]$TenantId, [string]$ProjectName = 'Workshop')
            $path = Join-Path $TestDrive "$Alias.metadata.json"
            @{
                projectName = $ProjectName
                environments = @{
                    $Alias = @{
                        AzTenantName = $TenantName; AzTenantId = $TenantId
                        HasExchangeOnline = $true; HasSharePointOnline = $true
                        Identities = @(
                            @{ Name = 'M365DscLcmApplication'; ApplicationId = '22222222-2222-3333-4444-555555555555'; CertificateThumbprint = 'A' * 40 }
                            @{ Name = 'M365DscExportApplication'; ApplicationId = '33333333-2222-3333-4444-555555555555'; CertificateThumbprint = 'B' * 40 }
                        )
                    }
                }
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
            $path
        }
    }
    AfterAll {
        Remove-Module PipelineSecrets -ErrorAction SilentlyContinue
    }

    It 'Uses multiple downloaded environment files to anonymize domains and tenant IDs' {
        $dev = Write-DeltaMetadata Dev 'dev.example.com' '01234567-89ab-cdef-0123-456789abcdef'
        $test = Write-DeltaMetadata Test 'test.example.com' '11111111-2222-3333-4444-555555555555'
        $map = Get-M365DscPipelineTenantIdentifierMap -Path $dev, $test
        $map['DEV.EXAMPLE.COM'] | Should -Be 'Dev'
        $map['11111111-2222-3333-4444-555555555555'] | Should -Be 'Test'
        $reportPath = Join-Path $TestDrive 'native-delta.html'
        Set-Content -LiteralPath $reportPath -Value 'dev.example.com 01234567-89ab-cdef-0123-456789abcdef test.example.com 11111111-2222-3333-4444-555555555555' -NoNewline
        . "$PSScriptRoot\..\..\.build\Export\DeltaReport.Helpers.ps1"
        Convert-DeltaReportTenantIdentifiers -Path $reportPath -TenantIdentifierMap $map
        Get-Content -LiteralPath $reportPath -Raw | Should -Be 'Dev Dev Test Test'
    }

    It 'Refuses duplicate aliases, conflicting tenant mappings and mixed projects' {
        $dev = Write-DeltaMetadata Dev 'dev.example.com' '01234567-89ab-cdef-0123-456789abcdef'
        { Get-M365DscPipelineTenantIdentifierMap -Path $dev, $dev } | Should -Throw '*Duplicate metadata*'
        $test = Write-DeltaMetadata Test 'test.example.com' '01234567-89ab-cdef-0123-456789abcdef'
        { Get-M365DscPipelineTenantIdentifierMap -Path $dev, $test } | Should -Throw '*more than one environment*'
        $test = Write-DeltaMetadata Test 'test.example.com' '11111111-2222-3333-4444-555555555555' -ProjectName OtherProject
        { Get-M365DscPipelineTenantIdentifierMap -Path $dev, $test } | Should -Throw '*one project*'
    }

    Context 'Native delta task execution' {
        BeforeAll {
            function task { param($Name, [scriptblock]$Action) $script:deltaTask = $Action }
            function Join-M365DSCConfiguration { param($ConfigurationFile, $ConfigurationPath) }
            function New-M365DSCDeltaReport { param($Source, $Destination, $OutputPath, $Type, $DriftOnly) }
            . "$PSScriptRoot\..\..\.build\Export\DeltaReport.ps1"
        }
        BeforeEach {
            $script:savedDeltaEnvironment = @{}
            foreach ($name in 'BuildEnvironment', 'M365DSC_SECRET_BACKEND', 'M365DSC_METADATA_PATH', 'M365DSC_METADATA_PATHS',
                'DeltaReportInputDirectory', 'DeltaReportOutputDirectory', 'DeltaReportSourceTenant', 'DeltaReportAnonymizeTenantIdentifiers')
            {
                $script:savedDeltaEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $null)
            }
            $ProjectPath = (Resolve-Path "$PSScriptRoot\..\..").Path
            $OutputDirectory = Join-Path $TestDrive 'output'
            $env:DeltaReportInputDirectory = Join-Path $TestDrive 'exports'
            $env:DeltaReportOutputDirectory = Join-Path $TestDrive 'reports'
            $env:DeltaReportSourceTenant = 'dev.example.com'
            $env:DeltaReportAnonymizeTenantIdentifiers = 'true'
            foreach ($tenantName in 'dev.example.com', 'test.example.com')
            {
                $resourceDirectory = Join-Path $env:DeltaReportInputDirectory "$tenantName\AADApplication"
                New-Item -Path $resourceDirectory -ItemType Directory -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $resourceDirectory 'M365TenantConfig.ps1') -Value 'Configuration Tenant {}'
            }
            $dev = Write-DeltaMetadata Dev 'dev.example.com' '01234567-89ab-cdef-0123-456789abcdef'
            $test = Write-DeltaMetadata Test 'test.example.com' '11111111-2222-3333-4444-555555555555'
            $env:M365DSC_METADATA_PATHS = ConvertTo-Json -InputObject @($dev, $test) -Compress
            Mock Join-M365DSCConfiguration { 'Configuration Merged {}' }
            Mock New-M365DSCDeltaReport {
                Set-Content -LiteralPath $OutputPath -Value 'dev.example.com 01234567-89ab-cdef-0123-456789abcdef test.example.com 11111111-2222-3333-4444-555555555555' -NoNewline
            }
            Mock Import-Module { throw 'Unexpected Key Vault import' } -ParameterFilter { $Name -like 'Az.*' -or $Name -like '*AzHelpers.psm1' }
        }
        AfterEach {
            foreach ($name in $script:savedDeltaEnvironment.Keys)
            {
                [Environment]::SetEnvironmentVariable($name, $script:savedDeltaEnvironment[$name])
            }
        }

        It 'Anonymizes multiple environments without BuildEnvironment or Azure and removes unredacted merge inputs' {
            . $script:deltaTask
            $reportPath = Join-Path $env:DeltaReportOutputDirectory 'DeltaReport-Dev-vs-Test.html'
            Get-Content -LiteralPath $reportPath -Raw | Should -Be 'Dev Dev Test Test'
            Get-ChildItem -LiteralPath $env:DeltaReportOutputDirectory -Filter '*.ps1' | Should -BeNullOrEmpty
            Should -Invoke Import-Module -Times 0 -ParameterFilter { $Name -like 'Az.*' -or $Name -like '*AzHelpers.psm1' }
        }

        It 'Fails closed on missing tenant metadata without reaching the Key Vault branch' {
            $env:M365DSC_METADATA_PATHS = ConvertTo-Json -InputObject @($dev) -Compress
            { . $script:deltaTask } | Should -Throw '*has no native metadata*'
            Should -Invoke New-M365DSCDeltaReport -Times 0
            Should -Invoke Import-Module -Times 0 -ParameterFilter { $Name -like 'Az.*' -or $Name -like '*AzHelpers.psm1' }
        }

        It 'Rejects a scalar metadata paths value instead of selecting Key Vault' {
            $env:M365DSC_METADATA_PATHS = ConvertTo-Json -InputObject $dev -Compress
            { . $script:deltaTask } | Should -Throw '*JSON array*'
            Should -Invoke Import-Module -Times 0 -ParameterFilter { $Name -like 'Az.*' -or $Name -like '*AzHelpers.psm1' }
        }

        It 'Requires native metadata when Kdbx anonymization is explicitly selected' {
            $env:M365DSC_SECRET_BACKEND = 'Kdbx'
            $env:M365DSC_METADATA_PATHS = ''
            { . $script:deltaTask } | Should -Throw '*Kdbx delta anonymization requires*'
            Should -Invoke Import-Module -Times 0 -ParameterFilter { $Name -like 'Az.*' -or $Name -like '*AzHelpers.psm1' }
        }
    }
}
