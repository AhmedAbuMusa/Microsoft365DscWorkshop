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
