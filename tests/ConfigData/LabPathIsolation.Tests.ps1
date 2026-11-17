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
