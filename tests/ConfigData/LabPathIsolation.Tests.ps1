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
                'Assert-FreshAzureSession',
                'Add-BicepInstallDirectoriesToPath',
                'Test-SourceDependencyRestoreComplete',
                'Invoke-LabScript',
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

Describe 'Project settings credential bootstrap' {
    It 'Prepares the Key Vault before importing the Azure DevOps repository' {
        $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
        $credentialStage = $bootstrapContent.IndexOf("Name 'bootstrap-project-settings'", [StringComparison]::Ordinal)
        $importStage = $bootstrapContent.IndexOf("Name 'import-repository'", [StringComparison]::Ordinal)

        $credentialStage | Should -BeGreaterThan -1
        $credentialStage | Should -BeLessThan $importStage
    }

    It 'Opens the configured organization and stores validated credentials without writing them to YAML' {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\04 Setup Project Settings Key Vault.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        $parseErrors | Should -BeNullOrEmpty
        $content | Should -Match 'Start-Process -FilePath \$tokenPage'
        $content | Should -Match 'Read-Host .* -AsSecureString'
        $content | Should -Match 'Test-AzureDevOpsPersonalAccessToken'
        $content | Should -Match 'Set-M365DscKeyVaultSecret'
        $content | Should -Not -Match '(?im)^\s*(Set-Content|Out-File)\b'
    }
}

Describe 'Azure worker shutdown module loading' {
    It 'Loads the repository-pinned Az modules before connecting to Azure' {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\89 Stop Workers.ps1'
        $scriptContent = Get-Content -LiteralPath $scriptPath -Raw

        $scriptContent | Should -Match 'Import-Module -Name Az\.Accounts -RequiredVersion \$requiredModuleVersions'
        $scriptContent | Should -Match 'Import-Module -Name Az\.Compute -RequiredVersion \$requiredModuleVersions'
        $scriptContent.IndexOf('Import-Module -Name Az.Compute') |
            Should -BeLessThan $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1')
        $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1') |
            Should -BeLessThan $scriptContent.IndexOf('Connect-M365Dsc @param')
        $scriptContent | Should -Match 'Already-loaded Az modules'
    }
}

Describe 'Worker removal module loading' {
    It 'Loads the pinned Microsoft Graph application modules before connecting for <ScriptPath>' -ForEach @(
        @{ ScriptPath = '..\..\lab\AutomatedLab\96 Remove Workers.ps1' }
        @{ ScriptPath = '..\..\lab\Azure\96 Remove Workers.ps1' }
    ) {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $ScriptPath
        $scriptContent = Get-Content -LiteralPath $scriptPath -Raw

        $scriptContent | Should -Match 'Import-Module -Name Microsoft\.Graph\.Applications -RequiredVersion \$requiredModuleVersions'
        $scriptContent | Should -Match 'Import-Module -Name Microsoft\.Graph\.Identity\.DirectoryManagement -RequiredVersion \$requiredModuleVersions'
        $scriptContent.IndexOf('Import-Module -Name Microsoft.Graph.Applications') |
            Should -BeLessThan $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1')
        $scriptContent.IndexOf('Import-Module -Name $PSScriptRoot\AzHelpers.psm1') |
            Should -BeLessThan $scriptContent.IndexOf('Connect-M365Dsc @param')
        $scriptContent | Should -Match 'Already-loaded Azure or Graph modules'
    }
}

Describe 'Azure bootstrap session isolation' {
    It 'Stops before setup when Az.Accounts is already loaded' {
        Mock Get-Module { [pscustomobject]@{ Name = 'Az.Accounts' } }

        { Assert-FreshAzureSession } | Should -Throw '*fresh elevated PowerShell 7 session*'
    }

    It 'Propagates preparation script failures to the bootstrap stage' {
        $preparationScript = Join-Path -Path $TestDrive -ChildPath 'failed-preparation.ps1'
        "throw 'Simulated preparation failure'" | Set-Content -LiteralPath $preparationScript

        { Invoke-LabScript -Path $preparationScript } | Should -Throw '*Simulated preparation failure*'
    }

    It 'Makes the preparation script terminate when an Azure assembly is already loaded' {
        $preparationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\00 Prep.ps1'
        $tokens = $null
        $parseErrors = $null
        $preparationAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $preparationPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty
        $sessionGuard = $preparationAst.Find({
                param($astNode)
                $astNode -is [System.Management.Automation.Language.IfStatementAst] -and
                $astNode.Extent.Text -match '\$loadedAzAccounts' -and
                $astNode.Extent.Text -match '\$assemblyLoading'
            }, $true)

        $sessionGuard | Should -Not -BeNullOrEmpty
        $sessionGuard.Extent.Text | Should -Match '\bthrow\b'
        $sessionGuard.Extent.Text | Should -Not -Match '\breturn\b'
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

    It 'Adds an existing Bicep install directory to the process PATH' {
        $previousPath = $env:PATH
        $installDirectory = Join-Path -Path $TestDrive -ChildPath 'Bicep CLI'
        $null = New-Item -ItemType Directory -Path $installDirectory -Force
        $executablePath = Join-Path -Path $installDirectory -ChildPath 'bicep.exe'
        Set-Content -LiteralPath $executablePath -Value 'test executable'
        try
        {
            Add-BicepInstallDirectoriesToPath -ExecutablePaths @($executablePath)

            @($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator)) |
                Should -Contain $installDirectory
        }
        finally
        {
            $env:PATH = $previousPath
        }
    }

    It 'Runs the Azure-specific build initialization workflow in a clean process' {
        $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
        $buildConfigurationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\build.yaml'
        $buildConfiguration = Get-Content -LiteralPath $buildConfigurationPath -Raw

        $bootstrapContent | Should -Match ([regex]::Escape('-NoLogo -NoProfile -File $targetBuildScript -Tasks azureinit'))
        $buildConfiguration | Should -Match '(?ms)^\s+azureinit:\s*\r?\n\s+- test7\s*\r?\n\s+- LoadDatumConfigData\s*\r?\n\s+- ConfigDataPreparation'
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-Tasks shellinit'))
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-Tasks init'))
    }

    It 'Keeps checkpoint restart separate from forced dependency restoration' {
        $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
        $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw

        $bootstrapContent | Should -Match '\[switch\]\$ForceDependencyRestore'
        $bootstrapContent | Should -Match ([regex]::Escape('-ForceRestore:$ForceDependencyRestore'))
        $bootstrapContent | Should -Not -Match ([regex]::Escape('-ForceRestore:$Restart'))
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

        $issues.Count | Should -Be 6
        $issues[0] | Should -Match 'lab\\Azure\\00 Prep.ps1'
        $issues[4] | Should -Match 'build.yaml'
        $issues[5] | Should -Match 'build.ps1'
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
        $helperPath = Join-Path -Path $TestDrive -ChildPath 'lab\Azure\AzHelpers.psm1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $helperPath -Parent) -Force
        'function Get-M365DscProjectSettingsFromKeyVault { param([object]$Datum) }' |
            Set-Content -LiteralPath $helperPath

        "  azureinit:`r`n    - test7`r`n    - LoadDatumConfigData`r`n    - ConfigDataPreparation" |
            Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'build.yaml')
        @'
        $buildResult = @{}
        Invoke-Build @PSBoundParameters -Task $Tasks -File $MyInvocation.MyCommand.Path -Result $buildResult
        if ($buildResult.Value.Error) { throw $buildResult.Value.Error }
'@ | Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'build.ps1')

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
        $helperPath = Join-Path -Path $seedPath -ChildPath 'lab\Azure\AzHelpers.psm1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $helperPath -Parent) -Force
        'function Get-M365DscProjectSettingsFromKeyVault { param([object]$Datum) }' |
            Set-Content -LiteralPath $helperPath
        "  azureinit:`r`n    - test7`r`n    - LoadDatumConfigData`r`n    - ConfigDataPreparation" |
            Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'build.yaml')
        @'
$buildResult = @{}
Invoke-Build @PSBoundParameters -Task $Tasks -File $MyInvocation.MyCommand.Path -Result $buildResult
if ($buildResult.Value.Error) { throw $buildResult.Value.Error }
'@ | Set-Content -LiteralPath (Join-Path -Path $seedPath -ChildPath 'build.ps1')
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
