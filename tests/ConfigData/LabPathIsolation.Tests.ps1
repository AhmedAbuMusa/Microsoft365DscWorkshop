BeforeAll {
    $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
    $tokens = $null
    $parseErrors = $null
    $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $bootstrapPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $bootstrapFunctions = $bootstrapAst.FindAll({
            param($astNode)
            $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $astNode.Name -in @(
                'Set-GitAuthorizationHeader',
                'Restore-GitAuthorizationHeader',
                'Test-SourceDependencyRestoreComplete',
                'Get-ImportedAzureScriptIssues',
                'Confirm-AzureDevOpsCloneRefresh',
                'Update-OutdatedAzureDevOpsClone'
            )
        }, $true)
    foreach ($functionAst in $bootstrapFunctions)
    {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
}

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

Describe 'Azure bootstrap dependency restore' {
    It 'Runs the dependency resolver directly in an isolated PowerShell process' {
        $labRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab'
        $bootstrapPath = Join-Path -Path $labRoot -ChildPath 'Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw

        $bootstrapContent | Should -Match ([regex]::Escape("ChildPath 'Resolve-Dependency.ps1'"))
        $bootstrapContent | Should -Match ([regex]::Escape('$dependencyRestoreArguments = @(''-UsePSResourceGet'')'))
        $bootstrapContent | Should -Match ([regex]::Escape('$dependencyRestoreArguments += ''-WithYAML'''))
        $bootstrapContent | Should -Match ([regex]::Escape('$dependencyRestoreArguments += ''-WithYAML:$false'''))
        $bootstrapContent | Should -Match ([regex]::Escape('-File $sourceDependencyScript @dependencyRestoreArguments'))
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-File $sourceBuildScript -UsePSResourceGet -ResolveDependency'))
    }

    It 'Skips dependency restore only when every required package version is present' {
        $repositoryRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
        $requiredModules = Import-PowerShellDataFile (Join-Path -Path $repositoryRoot -ChildPath 'RequiredModules.psd1')
        $resolverDefaults = Import-PowerShellDataFile (Join-Path -Path $repositoryRoot -ChildPath 'Resolve-Dependency.psd1')
        $requirements = foreach ($entry in $requiredModules.GetEnumerator() | Where-Object Key -ne 'PSDependOptions')
        {
            $version = if ($entry.Value -is [System.Collections.IDictionary]) { [string]$entry.Value.Version } else { [string]$entry.Value }
            @{ Name = $entry.Key; Version = $version }
        }
        $requirements += @{ Name = 'PSDepend'; Version = 'latest' }
        if ($resolverDefaults.WithYAML) { $requirements += @{ Name = 'PowerShell-Yaml'; Version = 'latest' } }
        if ($resolverDefaults.UsePSResourceGet) { $requirements += @{ Name = 'Microsoft.PowerShell.PSResourceGet'; Version = [string]$resolverDefaults.PSResourceGetVersion } }
        if ($resolverDefaults.UsePowerShellGetCompatibilityModule) { $requirements += @{ Name = 'PowerShellGet'; Version = [string]$resolverDefaults.UsePowerShellGetCompatibilityModuleVersion } }

        $requiredModulesPath = Join-Path -Path $TestDrive -ChildPath 'RequiredModules'
        $dependencyModuleFixtures = @(
            foreach ($requirement in $requirements)
            {
                $version = $requirement.Version
                $prerelease = $null
                if ($version -match '^(.+)-([^-]+)$')
                {
                    $version = $Matches[1]
                    $prerelease = $Matches[2]
                }
                if ($version -eq 'latest') { $version = '1.0.0' }

                [pscustomobject]@{
                    Name        = $requirement.Name
                    ModuleBase  = $requiredModulesPath
                    Version     = [version]$version
                    PrivateData = @{ PSData = @{ Prerelease = $prerelease } }
                }
            }
        )
        $previousFixtures = Get-Variable -Name 'AzureBootstrapDependencyModuleFixtures' -Scope Global -ErrorAction SilentlyContinue
        $global:AzureBootstrapDependencyModuleFixtures = $dependencyModuleFixtures
        Mock Get-Module { $global:AzureBootstrapDependencyModuleFixtures }
        try
        {
            Test-SourceDependencyRestoreComplete `
                -RepositoryRoot $repositoryRoot `
                -RequiredModulesPath $requiredModulesPath `
                -Verbose |
                Should -BeTrue

            Test-SourceDependencyRestoreComplete `
                -RepositoryRoot $repositoryRoot `
                -RequiredModulesPath $requiredModulesPath `
                -ForceRestore |
                Should -BeFalse

            $global:AzureBootstrapDependencyModuleFixtures = @($dependencyModuleFixtures | Where-Object Name -ne 'Az.Security')
            Test-SourceDependencyRestoreComplete `
                -RepositoryRoot $repositoryRoot `
                -RequiredModulesPath $requiredModulesPath |
                Should -BeFalse
        }
        finally
        {
            Remove-Variable -Name 'AzureBootstrapDependencyModuleFixtures' -Scope Global -ErrorAction SilentlyContinue
            if ($previousFixtures)
            {
                Set-Variable -Name 'AzureBootstrapDependencyModuleFixtures' -Scope Global -Value $previousFixtures.Value
            }
        }
    }
}

Describe 'Azure DevOps clone refresh approval' {
    It 'Detects when the imported checkout is missing the current Azure scripts' {
        $issues = @(Get-ImportedAzureScriptIssues -RepositoryPath $TestDrive)

        $issues.Count | Should -Be 3
        $issues[0] | Should -Match 'lab\\Azure\\00 Prep.ps1'
    }

    It 'Accepts a checkout containing all required scripts and parameters' {
        $scriptDefinitions = @(
            @{ Path = 'lab\Azure\00 Prep.ps1'; Parameter = 'ProjectName' }
            @{ Path = 'lab\Azure\30 Create Agent VMs.ps1'; Parameter = 'BuildAgentPassword' }
            @{ Path = 'lab\Azure\31 Agent Setup.ps1'; Parameter = 'EnvironmentName' }
        )
        foreach ($scriptDefinition in $scriptDefinitions)
        {
            $scriptPath = Join-Path -Path $TestDrive -ChildPath $scriptDefinition.Path
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $scriptPath -Parent) -Force
            "param([string]`$$($scriptDefinition.Parameter))" |
                Set-Content -LiteralPath $scriptPath
        }

        Get-ImportedAzureScriptIssues -RepositoryPath $TestDrive | Should -BeNullOrEmpty
    }

    It 'Requires affirmative approval before refreshing an outdated clone' {
        Mock Read-Host { 'n' }
        Confirm-AzureDevOpsCloneRefresh -Upstream 'origin/main' -Behind 43 -Ahead 0 |
            Should -BeFalse

        Mock Read-Host { 'yes' }
        Confirm-AzureDevOpsCloneRefresh -Upstream 'origin/main' -Behind 43 -Ahead 0 |
            Should -BeTrue
    }

    It 'Refreshes tracked files after approval while preserving local configuration' {
        $testRoot = Join-Path -Path $TestDrive -ChildPath 'clone-refresh'
        $originPath = Join-Path -Path $testRoot -ChildPath 'origin.git'
        $seedPath = Join-Path -Path $testRoot -ChildPath 'seed'
        $clonePath = Join-Path -Path $testRoot -ChildPath 'clone'
        $null = New-Item -ItemType Directory -Path $testRoot -Force

        git init --bare $originPath | Out-Null
        git init $seedPath | Out-Null
        git -C $seedPath checkout -b main | Out-Null
        git -C $seedPath config user.name 'Bootstrap test'
        git -C $seedPath config user.email 'bootstrap-test@example.invalid'

        foreach ($relativePath in @('source\Global\ProjectSettings.yml', 'source\Global\Azure.yml'))
        {
            $filePath = Join-Path -Path $seedPath -ChildPath $relativePath
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $filePath -Parent) -Force
            Set-Content -LiteralPath $filePath -Value 'remote-config-v1'
        }
        Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'README.md') -Value 'remote-v1'
        git -C $seedPath add --all
        git -C $seedPath commit -m 'Initial repository' | Out-Null
        git -C $seedPath remote add origin $originPath
        git -C $seedPath push -u origin main | Out-Null
        git clone --branch main $originPath $clonePath | Out-Null

        Set-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\ProjectSettings.yml') -Value 'local-project-settings'
        Set-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\Azure.yml') -Value 'local-azure-settings'
        Set-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'README.md') -Value 'local-code-change'

        $scriptDefinitions = @(
            @{ Path = 'lab\Azure\00 Prep.ps1'; Parameter = 'ProjectName' }
            @{ Path = 'lab\Azure\30 Create Agent VMs.ps1'; Parameter = 'BuildAgentPassword' }
            @{ Path = 'lab\Azure\31 Agent Setup.ps1'; Parameter = 'EnvironmentName' }
        )
        foreach ($scriptDefinition in $scriptDefinitions)
        {
            $scriptPath = Join-Path -Path $seedPath -ChildPath $scriptDefinition.Path
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $scriptPath -Parent) -Force
            "param([string]`$$($scriptDefinition.Parameter))" |
                Set-Content -LiteralPath $scriptPath
        }
        Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'README.md') -Value 'remote-v2'
        foreach ($relativePath in @('source\Global\ProjectSettings.yml', 'source\Global\Azure.yml'))
        {
            Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath $relativePath) -Value 'remote-config-v2'
        }
        git -C $seedPath add --all
        git -C $seedPath commit -m 'Add current Azure scripts' | Out-Null
        git -C $seedPath push origin main | Out-Null

        $script:GitCommand = Get-Command -Name git
        $oldCommit = git -C $clonePath rev-parse HEAD
        Mock Read-Host { 'n' }
        {
            Update-OutdatedAzureDevOpsClone `
                -RepositoryPath $clonePath `
                -AuthorizationHeader 'AUTHORIZATION: Basic dGVzdA==' `
                -BackupRoot (Join-Path -Path $testRoot -ChildPath 'backups')
        } | Should -Throw 'The local clone was not changed*'
        (git -C $clonePath rev-parse HEAD) | Should -Be $oldCommit

        Mock Read-Host { 'y' }
        Update-OutdatedAzureDevOpsClone `
            -RepositoryPath $clonePath `
            -AuthorizationHeader 'AUTHORIZATION: Basic dGVzdA==' `
            -BackupRoot (Join-Path -Path $testRoot -ChildPath 'backups')

        (Get-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'README.md') -Raw).Trim() |
            Should -Be 'remote-v2'
        (Get-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\ProjectSettings.yml') -Raw).Trim() |
            Should -Be 'local-project-settings'
        (Get-Content -LiteralPath (Join-Path -Path $clonePath -ChildPath 'source\Global\Azure.yml') -Raw).Trim() |
            Should -Be 'local-azure-settings'
        Get-ImportedAzureScriptIssues -RepositoryPath $clonePath | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path -Path $testRoot -ChildPath 'backups') -Directory -ErrorAction SilentlyContinue).Count |
            Should -Be 0
    }
}
