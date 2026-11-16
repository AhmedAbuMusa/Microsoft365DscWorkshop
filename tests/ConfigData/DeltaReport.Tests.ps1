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
