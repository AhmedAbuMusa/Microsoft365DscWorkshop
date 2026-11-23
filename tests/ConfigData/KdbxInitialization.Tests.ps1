BeforeAll {
    $env:PSModulePath += [IO.Path]::PathSeparator + (Join-Path $PSScriptRoot '..\..\output\RequiredModules')
    Import-Module powershell-yaml -ErrorAction Stop
    Import-Module $PSScriptRoot\..\..\lab\Secrets\Kdbx\Store.psm1 -Force
    $initializer = "$PSScriptRoot\..\..\lab\Secrets\Kdbx\Initialize Operator.ps1"
}
Describe 'KDBX initialization from available project YAML settings' {
    BeforeEach {
        $configPath = Join-Path $TestDrive 'ProjectSettings.yml'
        $databasePath = Join-Path $TestDrive 'operator.kdbx'
        $config = @{
            OrganizationName = 'synthetic-org'; ProjectName = 'synthetic-project'
            RepositoryName = 'synthetic-repo'; GitHubRepositoryUrl = 'https://github.com/example/workshop.git'
            LocalPath = 'C:\SyntheticTarget'; GitUserName = 'Synthetic Workshop'; GitUserEmail = 'workshop@example.invalid'
            AgentPoolName = 'synthetic-pool'; NumbertOfBuildAgents = 5
            PersonalAccessToken = 'must-not-use-yaml-pat'
            BuildAgents = @{ UserName = 'worker'; AzureLocation = 'synthetic-region'; AzureRoleSize = 'synthetic-size'; Password = '<StoredInKeyVault>' }
        }
        $capture = @{}
        Mock Import-Module {} -ParameterFilter { $Name -like '*Store.psm1' }
        Mock Open-M365DscSecretStore {}
        Mock Test-M365DscSecret { $false }
        Mock Set-M365DscSecretJson {
            $capture.Settings = $Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        }
        Mock Read-Host {
            if ($AsSecureString) {
                $text = if ($Prompt -like '*PAT*') { 'synthetic-prompt-pat' } else { 'Synthetic-Long-Password-123!' }
                return ConvertTo-SecureString $text -AsPlainText -Force
            }
            throw "Unexpected settings prompt: $Prompt"
        }
        Mock Invoke-RestMethod {}
    }
    It 'Reuses configured project and worker values but always securely asks for the PAT and a placeholder password' {
        $config | ConvertTo-Yaml | Set-Content -LiteralPath $configPath
        $before = Get-Content -LiteralPath $configPath -Raw
        & $initializer -Path $databasePath -ProjectSettingsPath $configPath
        $capture.Settings.ProjectName | Should -Be 'synthetic-project'
        $capture.Settings.NumbertOfBuildAgents | Should -Be 5
        $capture.Settings.BuildAgents.AzureRoleSize | Should -Be 'synthetic-size'
        $capture.Settings.PersonalAccessToken | Should -Be 'synthetic-prompt-pat'
        Should -Invoke Read-Host -Times 0 -ParameterFilter { -not $AsSecureString }
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like '*PAT*' -and $AsSecureString }
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -eq 'Worker VM administrator password' -and $AsSecureString }
        (Get-Content -LiteralPath $configPath -Raw) | Should -Be $before
    }
    It 'Prompts only for missing or placeholder settings and reuses a configured VM password' {
        $config.ProjectName = '<ProjectName>'
        $config.BuildAgents.Remove('AzureLocation')
        $config.BuildAgents.Password = 'Synthetic-Configured-Password-123!'
        Mock Read-Host { 'synthetic-new-project' } -ParameterFilter { $Prompt -eq 'Private project setting: ProjectName' }
        Mock Read-Host { 'synthetic-new-region' } -ParameterFilter { $Prompt -eq 'Worker setting: AzureLocation' }
        $config | ConvertTo-Yaml | Set-Content -LiteralPath $configPath
        & $initializer -Path $databasePath -ProjectSettingsPath $configPath
        $capture.Settings.ProjectName | Should -Be 'synthetic-new-project'
        $capture.Settings.BuildAgents.AzureLocation | Should -Be 'synthetic-new-region'
        $capture.Settings.BuildAgents.Password | Should -Be 'Synthetic-Configured-Password-123!'
        Should -Invoke Read-Host -Times 0 -ParameterFilter { $Prompt -eq 'Worker VM administrator password' }
        Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { -not $AsSecureString }
    }
    It 'Preserves existing encrypted settings and does not ask for their credentials again' {
        Mock Test-M365DscSecret { $true }
        & $initializer -Path $databasePath -ProjectSettingsPath (Join-Path $TestDrive 'missing.yml')
        Should -Invoke Read-Host -Times 0 -ParameterFilter { $Prompt -like '*PAT*' -or $Prompt -like '*Worker*' -or -not $AsSecureString }
        Should -Invoke Set-M365DscSecretJson -Times 0
    }
    It 'Rejects an invalid configured agent count rather than silently using a default' {
        $config.NumbertOfBuildAgents = -1
        $config | ConvertTo-Yaml | Set-Content -LiteralPath $configPath
        { & $initializer -Path $databasePath -ProjectSettingsPath $configPath } | Should -Throw '*positive integer*'
        Should -Invoke Set-M365DscSecretJson -Times 0
    }
    It 'Prompts for worker settings when their YAML mapping is absent' {
        $config.Remove('BuildAgents')
        Mock Read-Host { 'synthetic-worker-value' } -ParameterFilter { $Prompt -like 'Worker setting:*' }
        $config | ConvertTo-Yaml | Set-Content -LiteralPath $configPath
        & $initializer -Path $databasePath -ProjectSettingsPath $configPath
        $capture.Settings.BuildAgents.UserName | Should -Be 'synthetic-worker-value'
        Should -Invoke Read-Host -Times 3 -Exactly -ParameterFilter { $Prompt -like 'Worker setting:*' }
    }
}
