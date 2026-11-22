<#
.SYNOPSIS
    Imports the workshop repository into Azure DevOps and provisions the Azure lab.

.DESCRIPTION
    Reads configuration from source/Global/ProjectSettings.yml and source/Global/Azure.yml,
    then runs the Azure preparation, dependency, tenant, project, VM, and agent setup steps.
    Tenant administrator sign-in and consent remain interactive.

.NOTES
    Run from a fresh elevated PowerShell 7.6.10 or later session. Set all configuration
    values in the two YAML files before starting. If a run fails, rerun this script to
    resume from the failed stage; use -Restart to discard its saved progress and start over.
    Use -ForceDependencyRestore only when dependency packages must also be refreshed.
    Every start synchronizes GitHub's default branch into Azure DevOps and its local
    checkout. A changed repository commit invalidates completed downstream stages.
#>

[CmdletBinding()]
param
(
    [Parameter()]
    [switch]$Restart,

    [Parameter()]
    [switch]$ForceDependencyRestore
)

$ErrorActionPreference = 'Stop'
$script:BootstrapPhase = 0
$script:BootstrapPhaseCount = 13

function Write-BootstrapPhase
{
    param
    (
        [Parameter(Mandatory)]
        [ValidateRange(1, 13)]
        [int]$Index,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $script:BootstrapPhase = $Index
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ('Phase {0:D2}/{1:D2}: {2}' -f $Index, $script:BootstrapPhaseCount, $Description) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Assert-FreshAzureSession
{
    $loadedAzAccounts = Get-Module -Name Az.Accounts
    $assemblyLoading = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Azure.PowerShell.AssemblyLoading' } |
        Select-Object -First 1

    if ($loadedAzAccounts -or $assemblyLoading)
    {
        throw 'This bootstrap requires a fresh elevated PowerShell 7 session. Az.Accounts or its assembly is already loaded; close this session and start a new elevated session before running the bootstrap.'
    }
}

function Add-BicepInstallDirectoriesToPath
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string[]]$ExecutablePaths = @(
            (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Bicep CLI\bicep.exe')
            (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WinGet\Links\bicep.exe')
        )
    )

    foreach ($executablePath in $ExecutablePaths)
    {
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf))
        {
            continue
        }

        $installDirectory = Split-Path -Path $executablePath -Parent
        $pathEntries = @($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator))
        if ($installDirectory -notin $pathEntries)
        {
            $env:PATH = "$installDirectory$([IO.Path]::PathSeparator)$env:PATH"
        }
    }
}

function Save-BootstrapCheckpoint
{
    $checkpointDirectory = Split-Path -Path $script:BootstrapCheckpointPath -Parent
    $null = New-Item -ItemType Directory -Path $checkpointDirectory -Force
    $temporaryPath = "$($script:BootstrapCheckpointPath).$PID.tmp"
    $script:BootstrapCheckpoint |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $script:BootstrapCheckpointPath -Force
}

function Update-BootstrapCheckpointSchema
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Checkpoint
    )

    switch ([int]$Checkpoint['SchemaVersion'])
    {
        1
        {
            $Checkpoint['CompletedStages'] = @($Checkpoint['CompletedStages'] | Where-Object {
                    $_ -notin @('prepare-machine', 'verify-import', 'initialize-target-build')
                })
            $Checkpoint['SchemaVersion'] = 3
            return $true
        }
        2
        {
            $Checkpoint['CompletedStages'] = @($Checkpoint['CompletedStages'] | Where-Object {
                    $_ -notin @('verify-import', 'initialize-target-build')
                })
            $Checkpoint['SchemaVersion'] = 3
            return $true
        }
        3
        {
            return $false
        }
        default
        {
            throw 'The checkpoint schema version is not supported.'
        }
    }
}

function Invoke-BootstrapStage
{
    param
    (
        [Parameter(Mandatory)]
        [ValidateRange(3, 13)]
        [int]$Index,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $script:BootstrapPhase = $Index
    if ($Name -in $script:BootstrapCheckpoint.CompletedStages)
    {
        $phaseLabel = '{0:D2}/{1:D2}' -f $Index, $script:BootstrapPhaseCount
        Write-Host "Skipping completed phase $phaseLabel`: $Description" -ForegroundColor DarkGray
        return
    }

    function Update-BootstrapRepositoryCheckpoint
    {
        param
        (
            [Parameter(Mandatory)]
            [string]$Commit
        )

        if ($script:BootstrapCheckpoint['RepositoryCommit'] -eq $Commit)
        {
            return
        }

        $script:BootstrapCheckpoint.CompletedStages = @($script:BootstrapCheckpoint.CompletedStages | Where-Object {
                $_ -in @('bootstrap-project-settings', 'import-repository')
            })
        $script:BootstrapCheckpoint['RepositoryCommit'] = $Commit
        Save-BootstrapCheckpoint
        Write-Host 'Repository revision changed; completed downstream provisioning stages will run again.' -ForegroundColor Yellow
    }

    Write-BootstrapPhase -Index $Index -Description $Description
    $script:BootstrapCheckpoint.CurrentStage = $Name
    Save-BootstrapCheckpoint
    try
    {
        & $Action
        $script:BootstrapCheckpoint.CompletedStages = @(
            $script:BootstrapCheckpoint.CompletedStages
            $Name
        ) | Select-Object -Unique
        $script:BootstrapCheckpoint.CurrentStage = $null
        Save-BootstrapCheckpoint
    }
    catch
    {
        Write-Host "Bootstrap failed during phase $($Index)/$($script:BootstrapPhaseCount): $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function ConvertTo-SecureStringFromKeyVault
{
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        '',
        Justification = 'The build-agent password is retrieved from Key Vault and passed as a SecureString to the VM script.'
    )]
    param
    (
        [Parameter(Mandatory)]
        [string]$Value
    )

    ConvertTo-SecureString -String $Value -AsPlainText -Force
}

function Get-RequiredConfigurationValue
{
    param
    (
        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $value = $Configuration.$Name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value) -or [string]$value -match '^<.+>$')
    {
        throw "Set '$Path' in the YAML configuration before running this script."
    }

    $value
}

function Set-GitAuthorizationHeader
{
    param
    (
        [Parameter(Mandatory)]
        [string]$AuthorizationHeader
    )

    $script:GitEnvironmentBackup = @{}
    $countValue = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
    $count = 0
    if ($countValue -and -not [int]::TryParse($countValue, [ref]$count))
    {
        throw 'GIT_CONFIG_COUNT is set to a non-numeric value. Clear it before running this script.'
    }

    $script:GitEnvironmentBackup.GIT_CONFIG_COUNT = $countValue
    $script:GitEnvironmentBackup.GIT_TERMINAL_PROMPT = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT', 'Process')
    $keyName = "GIT_CONFIG_KEY_$count"
    $valueName = "GIT_CONFIG_VALUE_$count"
    $script:GitEnvironmentBackup[$keyName] = [Environment]::GetEnvironmentVariable($keyName, 'Process')
    $script:GitEnvironmentBackup[$valueName] = [Environment]::GetEnvironmentVariable($valueName, 'Process')
    [Environment]::SetEnvironmentVariable($keyName, 'http.https://dev.azure.com/.extraheader', 'Process')
    [Environment]::SetEnvironmentVariable($valueName, $AuthorizationHeader, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', [string]($count + 1), 'Process')
    [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
}

function Restore-GitAuthorizationHeader
{
    if (-not $script:GitEnvironmentBackup)
    {
        return
    }

    foreach ($name in $script:GitEnvironmentBackup.Keys)
    {
        [Environment]::SetEnvironmentVariable($name, $script:GitEnvironmentBackup[$name], 'Process')
    }
    $script:GitEnvironmentBackup = $null
}

function Test-SourceDependencyRestoreComplete
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$RequiredModulesPath,

        [switch]$ForceRestore
    )

    if ($ForceRestore)
    {
        Write-Verbose 'Dependency restoration was explicitly requested.'
        return $false
    }

    $requiredModulesManifestPath = Join-Path -Path $RepositoryRoot -ChildPath 'RequiredModules.psd1'
    $resolverDefaultsPath = Join-Path -Path $RepositoryRoot -ChildPath 'Resolve-Dependency.psd1'
    if (-not (Test-Path -LiteralPath $requiredModulesManifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $resolverDefaultsPath -PathType Leaf))
    {
        Write-Verbose 'Dependency manifests are missing; dependency restore is required.'
        return $false
    }

    $requiredModules = Import-PowerShellDataFile -Path $requiredModulesManifestPath
    $resolverDefaults = Import-PowerShellDataFile -Path $resolverDefaultsPath
    $availableModules = @(
        Get-Module -ListAvailable |
            Where-Object { $_.ModuleBase.StartsWith($RequiredModulesPath, [StringComparison]::OrdinalIgnoreCase) }
    )
    $requirements = [System.Collections.Generic.List[object]]::new()

    foreach ($requiredModule in $requiredModules.GetEnumerator() | Where-Object Key -ne 'PSDependOptions')
    {
        $version = if ($requiredModule.Value -is [System.Collections.IDictionary])
        {
            [string]$requiredModule.Value.Version
        }
        else
        {
            [string]$requiredModule.Value
        }

        $requirements.Add(@{
                Name    = $requiredModule.Key
                Version = $version
            })
    }

    $requirements.Add(@{ Name = 'PSDepend'; Version = 'latest' })
    if ($resolverDefaults.WithYAML)
    {
        $requirements.Add(@{ Name = 'PowerShell-Yaml'; Version = 'latest' })
    }
    if ($resolverDefaults.UsePSResourceGet)
    {
        $requirements.Add(@{
                Name    = 'Microsoft.PowerShell.PSResourceGet'
                Version = [string]$resolverDefaults.PSResourceGetVersion
            })
    }
    if ($resolverDefaults.UsePowerShellGetCompatibilityModule)
    {
        $requirements.Add(@{
                Name    = 'PowerShellGet'
                Version = [string]$resolverDefaults.UsePowerShellGetCompatibilityModuleVersion
            })
    }

    foreach ($requirement in $requirements)
    {
        $moduleMatches = @($availableModules | Where-Object Name -eq $requirement.Name)
        if ($moduleMatches.Count -eq 0)
        {
            Write-Verbose "Required module '$($requirement.Name)' is not installed in '$RequiredModulesPath'."
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($requirement.Version) -or $requirement.Version -eq 'latest')
        {
            continue
        }

        $matchingVersion = $false
        foreach ($module in $moduleMatches)
        {
            $installedVersion = [string]$module.Version
            $prerelease = [string]$module.PrivateData.PSData.Prerelease
            if ($prerelease)
            {
                $installedVersion = '{0}-{1}' -f $installedVersion, $prerelease
            }
            if ($installedVersion -eq $requirement.Version)
            {
                $matchingVersion = $true
                break
            }
        }
        if (-not $matchingVersion)
        {
            Write-Verbose "Required module '$($requirement.Name)' version '$($requirement.Version)' is not installed in '$RequiredModulesPath'."
            return $false
        }
    }

    return $true
}

function Get-ImportedAzureScriptIssues
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter()]
        [string]$Revision
    )

    $requiredScripts = @(
        @{ Path = 'lab\Azure\00 Prep.ps1'; Parameter = 'ProjectName' }
        @{ Path = 'lab\Azure\30 Create Agent VMs.ps1'; Parameter = 'BuildAgentPassword' }
        @{ Path = 'lab\Azure\31 Agent Setup.ps1'; Parameter = 'EnvironmentName' }
        @{
            Path           = 'lab\Azure\AzHelpers.psm1'
            RequiredPattern = '(?m)^\s*function\s+Get-M365DscProjectSettingsFromKeyVault\b'
        }
    )
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($scriptAndParameter in $requiredScripts)
    {
        $scriptPath = Join-Path -Path $RepositoryPath -ChildPath $scriptAndParameter.Path
        if ($Revision)
        {
            $gitPath = $scriptAndParameter.Path -replace '\\', '/'
            $scriptContent = & $script:GitCommand.Source -C $RepositoryPath show "${Revision}:$gitPath" 2>$null
            if ($LASTEXITCODE -ne 0)
            {
                $issues.Add("Required script '$($scriptAndParameter.Path)' is missing from '$Revision'.")
                continue
            }
            $scriptContent = $scriptContent -join [Environment]::NewLine
        }
        elseif (Test-Path -LiteralPath $scriptPath -PathType Leaf)
        {
            $scriptContent = Get-Content -LiteralPath $scriptPath -Raw
        }
        else
        {
            $issues.Add("Required script '$($scriptAndParameter.Path)' is missing.")
            continue
        }

        $tokens = $null
        $parseErrors = $null
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $scriptContent,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors)
        {
            $parseDetails = ($parseErrors | ForEach-Object {
                    "line $($_.Extent.StartLineNumber): $($_.Message)"
                }) -join '; '
            $issues.Add("Imported script '$($scriptAndParameter.Path)' has PowerShell parse errors: $parseDetails")
            continue
        }

        if ($scriptAndParameter.Parameter)
        {
            $parameterNames = @($scriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            if ($scriptAndParameter.Parameter -notin $parameterNames)
            {
                $issues.Add("Imported script '$($scriptAndParameter.Path)' is outdated and does not declare parameter '$($scriptAndParameter.Parameter)'.")
            }
        }
        if ($scriptAndParameter.RequiredPattern -and $scriptContent -notmatch $scriptAndParameter.RequiredPattern)
        {
            $issues.Add("Imported script '$($scriptAndParameter.Path)' is outdated and does not implement the required project-credentials Key Vault support.")
        }
    }

    $requiredBuildFiles = @(
        @{
            Path        = 'build.yaml'
            Pattern     = '(?ms)^\s+azureinit:\s*\r?\n\s+- test7\s*\r?\n\s+- LoadDatumConfigData\s*\r?\n\s+- ConfigDataPreparation\b'
            Description = "Azure initialization workflow 'azureinit'"
        }
        @{
            Path        = 'build.ps1'
            Pattern     = '(?s)(?=.*Invoke-Build\s+@PSBoundParameters\s+-Task\s+\$Tasks\s+-File\s+\$MyInvocation\.MyCommand\.Path\s+-Result\s+\$buildResult)(?=.*\$buildResult\.Value\.Error)'
            Description = 'Invoke-Build failure propagation'
        }
    )
    foreach ($buildFile in $requiredBuildFiles)
    {
        $buildFilePath = Join-Path -Path $RepositoryPath -ChildPath $buildFile.Path
        if ($Revision)
        {
            $gitPath = $buildFile.Path -replace '\\', '/'
            $buildFileContent = & $script:GitCommand.Source -C $RepositoryPath show "${Revision}:$gitPath" 2>$null
            if ($LASTEXITCODE -ne 0)
            {
                $issues.Add("Required file '$($buildFile.Path)' is missing from '$Revision'.")
                continue
            }
            $buildFileContent = $buildFileContent -join [Environment]::NewLine
        }
        elseif (Test-Path -LiteralPath $buildFilePath -PathType Leaf)
        {
            $buildFileContent = Get-Content -LiteralPath $buildFilePath -Raw
        }
        else
        {
            $issues.Add("Required file '$($buildFile.Path)' is missing.")
            continue
        }

        if ($buildFileContent -notmatch $buildFile.Pattern)
        {
            $issues.Add("Required file '$($buildFile.Path)' does not contain the $($buildFile.Description).")
        }
    }

    return $issues.ToArray()
}

function Confirm-AzureDevOpsCloneRefresh
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Upstream,

        [Parameter(Mandatory)]
        [int]$Behind,

        [Parameter(Mandatory)]
        [int]$Ahead
    )

    $approval = Read-Host -Prompt "Local clone is $Behind commit(s) behind and $Ahead commit(s) ahead of '$Upstream'. Refresh it from the latest Azure DevOps version? Tracked local changes and commits will be overwritten except source/Global/ProjectSettings.yml and source/Global/Azure.yml, which are preserved. Untracked files will remain. [y/N]"
    return $approval -match '^(?i:y|yes)$'
}

function Update-OutdatedAzureDevOpsClone
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string]$AuthorizationHeader,

        [Parameter()]
        [string]$BackupRoot = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft365DscWorkshop\AzureLabBootstrap\CloneBackups')
    )

    $upstream = & $script:GitCommand.Source -C $RepositoryPath rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$upstream))
    {
        throw "The local clone at '$RepositoryPath' has no upstream tracking branch; it cannot be refreshed automatically."
    }

    Set-GitAuthorizationHeader -AuthorizationHeader $AuthorizationHeader
    try
    {
        & $script:GitCommand.Source -C $RepositoryPath fetch --prune origin
        if ($LASTEXITCODE -ne 0)
        {
            throw "Could not fetch the latest Azure DevOps branch '$upstream'."
        }
    }
    finally
    {
        Restore-GitAuthorizationHeader
    }

    $behind = 0
    $behindText = & $script:GitCommand.Source -C $RepositoryPath rev-list --count "HEAD..$upstream"
    if ($LASTEXITCODE -ne 0 -or -not [int]::TryParse([string]$behindText, [ref]$behind))
    {
        throw "Could not determine whether the local clone is behind '$upstream'."
    }

    $ahead = 0
    $aheadText = & $script:GitCommand.Source -C $RepositoryPath rev-list --count "$upstream..HEAD"
    if ($LASTEXITCODE -ne 0 -or -not [int]::TryParse([string]$aheadText, [ref]$ahead))
    {
        throw "Could not determine whether the local clone has commits ahead of '$upstream'."
    }

    if ($behind -eq 0)
    {
        throw "The required Azure scripts are outdated, but the local clone is not behind '$upstream'. Verify the Azure DevOps repository and branch before retrying."
    }

    $remoteIssues = @(Get-ImportedAzureScriptIssues -RepositoryPath $RepositoryPath -Revision $upstream)
    if ($remoteIssues.Count -gt 0)
    {
        throw "The latest Azure DevOps version at '$upstream' does not contain compatible Azure scripts: $($remoteIssues -join ' ')"
    }

    if (-not (Confirm-AzureDevOpsCloneRefresh -Upstream $upstream -Behind $behind -Ahead $ahead))
    {
        throw "The local clone was not changed. Approve the refresh when prompted or configure a new empty LocalPath."
    }

    $backupDirectory = Join-Path -Path $BackupRoot -ChildPath ([guid]::NewGuid().ToString('N'))
    $configurationBackups = [System.Collections.Generic.List[object]]::new()
    $configurationPaths = @(
        'source\Global\ProjectSettings.yml'
        'source\Global\Azure.yml'
    )

    try
    {
        foreach ($relativePath in $configurationPaths)
        {
            $configurationPath = Join-Path -Path $RepositoryPath -ChildPath $relativePath
            if (Test-Path -LiteralPath $configurationPath -PathType Leaf)
            {
                $backupPath = Join-Path -Path $backupDirectory -ChildPath $relativePath
                $backupParent = Split-Path -Path $backupPath -Parent
                $null = New-Item -ItemType Directory -Path $backupParent -Force
                Copy-Item -LiteralPath $configurationPath -Destination $backupPath -Force
                $configurationBackups.Add(@{
                        Path       = $configurationPath
                        BackupPath = $backupPath
                    })
            }
        }
    }
    catch
    {
        if (Test-Path -LiteralPath $backupDirectory)
        {
            Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }

        throw "Could not safely back up local configuration before refreshing the clone: $($_.Exception.Message)"
    }

    $refreshError = $null
    try
    {
        & $script:GitCommand.Source -C $RepositoryPath reset --hard $upstream
        if ($LASTEXITCODE -ne 0)
        {
            throw "Git reset to '$upstream' failed with exit code $LASTEXITCODE."
        }
    }
    catch
    {
        $refreshError = $_.Exception.Message
    }

    $restoreErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($configurationBackup in $configurationBackups)
    {
        try
        {
            Copy-Item -LiteralPath $configurationBackup.BackupPath -Destination $configurationBackup.Path -Force
        }
        catch
        {
            $restoreErrors.Add("$($configurationBackup.Path): $($_.Exception.Message)")
        }
    }

    if ($restoreErrors.Count -gt 0)
    {
        throw "Could not restore local configuration after refreshing the clone. Backups were retained at '$backupDirectory'. $($restoreErrors -join '; ')"
    }

    if ($refreshError)
    {
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not refresh the local clone: $refreshError"
    }

    if (Test-Path -LiteralPath $backupDirectory)
    {
        try
        {
            Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction Stop
        }
        catch
        {
            Write-Warning "The clone was refreshed, but temporary configuration backups could not be removed from '$backupDirectory': $($_.Exception.Message)"
        }
    }

    Write-Host "Refreshed local Azure DevOps clone to '$upstream'; local configuration files were preserved." -ForegroundColor Green
}

function Invoke-LabScript
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [hashtable]$Arguments = @{}
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "Required lab script '$Path' was not found."
    }

    Write-Host "Running file: '$Path'." -ForegroundColor Yellow
    try
    {
        & $Path @Arguments
        Write-Host "Completed file: '$Path'." -ForegroundColor Green
    }
    catch
    {
        Write-Host "Failed file: '$Path'." -ForegroundColor Red
        throw
    }
}

function Invoke-LabScriptWithGitAuthorization
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [hashtable]$Arguments = @{}
    )

    Set-GitAuthorizationHeader -AuthorizationHeader $script:GitAuthorizationHeader
    try
    {
        Invoke-LabScript -Path $Path -Arguments $Arguments
    }
    finally
    {
        Restore-GitAuthorizationHeader
    }
}

function Get-EnvironmentNames
{
    param
    (
        [Parameter(Mandatory)]
        [object]$Datum
    )

    $environments = @($Datum.Global.Azure.Environments.Keys)
    if ($environments.Count -eq 0)
    {
        throw "Configure at least one environment in 'source/Global/Azure.yml'."
    }

    foreach ($environmentName in $environments)
    {
        $environment = $Datum.Global.Azure.Environments[$environmentName]
        foreach ($field in @('AzTenantName'))
        {
            if ([string]::IsNullOrWhiteSpace([string]$environment.$field) -or [string]$environment.$field -match '^<.+>$')
            {
                throw "Set 'Environments.$environmentName.$field' in 'source/Global/Azure.yml'; tenant and subscription IDs are discovered at sign-in and stored in Key Vault."
            }
        }

        foreach ($field in @('HasExchangeOnline', 'HasSharePointOnline'))
        {
            if ($null -eq $environment.$field -or $environment.$field -isnot [bool])
            {
                throw "'Environments.$environmentName.$field' in 'source/Global/Azure.yml' must be true or false."
            }
        }

    }

    return $environments
}

function Assert-BuildAgentPassword
{
    param
    (
        [Parameter(Mandatory)]
        [securestring]$Password
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try
    {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $characterClassCount = @(
            [bool]($plainPassword -cmatch '[A-Z]')
            [bool]($plainPassword -cmatch '[a-z]')
            [bool]($plainPassword -match '\d')
            [bool]($plainPassword -match '[^A-Za-z0-9]')
        ).Where({ $_ }).Count
        if ($plainPassword.Length -lt 12 -or $characterClassCount -lt 3)
        {
            throw 'BuildAgents.Password must be at least 12 characters and include at least three of uppercase, lowercase, numeric, and special characters.'
        }
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Remove-StaleMicrosoft365DscVersions
{
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $moduleSpecification = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $RepositoryRoot -ChildPath 'RequiredModules.psd1')
    $pinnedVersion = [string]$moduleSpecification.Microsoft365DSC
    $modulePath = Join-Path -Path $RepositoryRoot -ChildPath 'output\RequiredModules\Microsoft365DSC'
    if (-not (Test-Path -LiteralPath $modulePath))
    {
        return
    }

    $loadedFromPath = Get-Module -Name Microsoft365DSC |
        Where-Object { $_.ModuleBase.StartsWith($modulePath, [StringComparison]::OrdinalIgnoreCase) }
    if ($loadedFromPath)
    {
        throw "Microsoft365DSC is already loaded from '$modulePath'. Close this PowerShell session and retry."
    }

    Get-ChildItem -LiteralPath $modulePath -Directory |
        Where-Object Name -NE $pinnedVersion |
        Remove-Item -Recurse -Force -ErrorAction Stop
}

function Initialize-TargetDependencies
{
    param
    (
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$TargetRoot
    )

    $sourceManifest = Join-Path -Path $SourceRoot -ChildPath 'RequiredModules.psd1'
    $targetManifest = Join-Path -Path $TargetRoot -ChildPath 'RequiredModules.psd1'
    $sourceManifestText = (Get-Content -LiteralPath $sourceManifest -Raw).Replace("`r`n", "`n")
    $targetManifestText = (Get-Content -LiteralPath $targetManifest -Raw).Replace("`r`n", "`n")
    if ($sourceManifestText -cne $targetManifestText)
    {
        throw 'The GitHub import has a different RequiredModules.psd1 from this checkout. Update the GitHub default branch before importing it.'
    }

    $sourceModules = Join-Path -Path $SourceRoot -ChildPath 'output\RequiredModules'
    $targetModules = Join-Path -Path $TargetRoot -ChildPath 'output\RequiredModules'
    if (-not (Test-Path -LiteralPath $targetModules))
    {
        Write-Host "Copying restored dependencies into '$targetModules'."
        $null = New-Item -ItemType Directory -Path $targetModules -Force
        Copy-Item -Path (Join-Path -Path $sourceModules -ChildPath '*') -Destination $targetModules -Recurse -Force
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path -Path $targetModules -ChildPath 'Datum')))
    {
        $pwshCommand = Get-Command -Name pwsh -ErrorAction Stop
        $buildScript = Join-Path -Path $TargetRoot -ChildPath 'build.ps1'
        Write-Host "Running file: '$buildScript' -UsePSResourceGet -ResolveDependency."
        & $pwshCommand.Source -NoLogo -NoProfile -File $buildScript -UsePSResourceGet -ResolveDependency
        if ($LASTEXITCODE -ne 0)
        {
            throw "Dependency restore for the imported repository failed with exit code $LASTEXITCODE."
        }
        Write-Host "Completed dependency restore for '$TargetRoot'." -ForegroundColor Green
    }
    else
    {
        Write-Host "Using dependencies already present in '$targetModules'."
    }
}

if ($PSVersionTable.PSVersion -lt [version]'7.6.10')
{
    throw 'PowerShell 7.6.10 or later is required. Start the script from pwsh, not Windows PowerShell.'
}
if (-not $IsWindows)
{
    throw 'The Azure lab bootstrapper supports Windows only.'
}

$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = [Security.Principal.WindowsPrincipal]::new($windowsIdentity)
if (-not $windowsPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    throw 'Run this bootstrapper from an elevated PowerShell 7 session; the Azure preparation script installs machine-wide modules.'
}

Assert-FreshAzureSession

$script:GitCommand = Get-Command -Name git -ErrorAction SilentlyContinue
if (-not $script:GitCommand)
{
    throw 'Git is required but was not found on PATH.'
}

$repositoryRoot = (& $script:GitCommand.Source -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repositoryRoot)
{
    throw 'Run this script from a checkout of the Microsoft365DscWorkshop repository.'
}
$repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot).Path
$sourceSettingsPath = Join-Path -Path $repositoryRoot -ChildPath 'source\Global\ProjectSettings.yml'
$sourceAzurePath = Join-Path -Path $repositoryRoot -ChildPath 'source\Global\Azure.yml'
if (-not (Test-Path -LiteralPath $sourceSettingsPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceAzurePath -PathType Leaf))
{
    throw 'Both source/Global/ProjectSettings.yml and source/Global/Azure.yml are required.'
}

$pwshCommand = Get-Command -Name pwsh -ErrorAction SilentlyContinue
if (-not $pwshCommand)
{
    throw 'PowerShell 7 (pwsh) is required to restore the repository dependencies in an isolated process.'
}

Remove-StaleMicrosoft365DscVersions -RepositoryRoot $repositoryRoot
$sourceRequiredModules = Join-Path -Path $repositoryRoot -ChildPath 'output\RequiredModules'
if ($env:PSModulePath -notlike "*$sourceRequiredModules*")
{
    $env:PSModulePath = "$sourceRequiredModules;$env:PSModulePath"
}

$dependenciesAvailable = Test-SourceDependencyRestoreComplete `
    -RepositoryRoot $repositoryRoot `
    -RequiredModulesPath $sourceRequiredModules `
    -ForceRestore:$ForceDependencyRestore

if ($dependenciesAvailable)
{
    Write-Host 'Skipping phase 01/12: all required dependency versions are already installed.' -ForegroundColor DarkGray
}
else
{
    $yamlModuleRoot = Join-Path -Path $sourceRequiredModules -ChildPath 'powershell-yaml'
    $yamlModuleManifest = Get-ChildItem -LiteralPath $yamlModuleRoot -Filter 'powershell-yaml.psd1' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $dependencyRestoreArguments = @('-UsePSResourceGet')
    if (-not $yamlModuleManifest)
    {
        $dependencyRestoreArguments += '-WithYAML'
    }
    else
    {
        $dependencyRestoreArguments += '-WithYAML:$false'
        Write-Host "Using existing PowerShell-Yaml module at '$($yamlModuleManifest.FullName)'; it is excluded as a direct restore target, but another package may still request it as a transitive dependency." -ForegroundColor Yellow
    }

    $sourceDependencyScript = Join-Path -Path $repositoryRoot -ChildPath 'Resolve-Dependency.ps1'
    Write-BootstrapPhase -Index 1 -Description 'Restore dependencies for the source checkout'
    Write-Host "Running file: '$sourceDependencyScript' $($dependencyRestoreArguments -join ' ')."
    try
    {
        & $pwshCommand.Source -NoLogo -NoProfile -File $sourceDependencyScript @dependencyRestoreArguments
        if ($LASTEXITCODE -ne 0)
        {
            throw "Source dependency restore failed with exit code $LASTEXITCODE."
        }
    }
    catch
    {
        Write-Host "Bootstrap failed during phase $($script:BootstrapPhase)/$($script:BootstrapPhaseCount): $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    Write-Host 'Completed source checkout dependency restore.' -ForegroundColor Green
}

Import-Module -Name Datum -ErrorAction Stop
Import-Module -Name Datum.ProtectedData -ErrorAction Stop

Write-BootstrapPhase -Index 2 -Description 'Read and validate project and tenant configuration'
$sourceDatum = New-DatumStructure -DefinitionFile (Join-Path -Path $repositoryRoot -ChildPath 'source\Datum.yml')
$sourceProjectSettings = $sourceDatum.Global.ProjectSettings
$script:OrganizationName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'OrganizationName' -Path 'source/Global/ProjectSettings.yml: OrganizationName')
$script:ProjectName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'ProjectName' -Path 'source/Global/ProjectSettings.yml: ProjectName')
$script:RepositoryName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'RepositoryName' -Path 'source/Global/ProjectSettings.yml: RepositoryName')
$localPathValue = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'LocalPath' -Path 'source/Global/ProjectSettings.yml: LocalPath')
$null = Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'AgentPoolName' -Path 'source/Global/ProjectSettings.yml: AgentPoolName'
$buildAgentUserName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings.BuildAgents -Name 'UserName' -Path 'source/Global/ProjectSettings.yml: BuildAgents.UserName')
$null = Get-RequiredConfigurationValue -Configuration $sourceProjectSettings.BuildAgents -Name 'AzureLocation' -Path 'source/Global/ProjectSettings.yml: BuildAgents.AzureLocation'
$buildAgentVmSize = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings.BuildAgents -Name 'AzureRoleSize' -Path 'source/Global/ProjectSettings.yml: BuildAgents.AzureRoleSize')

if ($script:OrganizationName -notmatch '^[A-Za-z0-9._-]+$')
{
    throw "Invalid OrganizationName in 'source/Global/ProjectSettings.yml'."
}
if ($script:ProjectName -notmatch '^[A-Za-z0-9._ -]+$' -or
    $script:RepositoryName -notmatch '^[A-Za-z0-9._ -]+$')
{
    throw 'ProjectName and RepositoryName in ProjectSettings.yml may contain only letters, digits, spaces, periods, underscores, and hyphens.'
}
if ($buildAgentUserName -notmatch '^[A-Za-z0-9._-]+$' -or $buildAgentVmSize -notmatch '^[A-Za-z0-9_]+$')
{
    throw 'BuildAgents.UserName or BuildAgents.AzureRoleSize in ProjectSettings.yml contains unsupported characters.'
}
$resolvedLocalPath = [IO.Path]::GetFullPath($localPathValue)
$repositoryPrefix = $repositoryRoot.TrimEnd('\') + '\'
if ($resolvedLocalPath.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedLocalPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase))
{
    throw 'LocalPath must be outside the source checkout.'
}

$script:EnvironmentNames = @(Get-EnvironmentNames -Datum $sourceDatum)
$credentialVaultEnvironment = [string]$sourceProjectSettings.CredentialVaultEnvironment
if ([string]::IsNullOrWhiteSpace($credentialVaultEnvironment) -or
    $credentialVaultEnvironment -notin $script:EnvironmentNames)
{
    throw "Set 'CredentialVaultEnvironment' in 'source/Global/ProjectSettings.yml' to an environment defined in 'source/Global/Azure.yml'."
}

$resumeIdentity = [ordered]@{
    RepositoryRoot       = $repositoryRoot
    OrganizationName     = $script:OrganizationName
    ProjectName          = $script:ProjectName
    RepositoryName       = $script:RepositoryName
    CredentialVaultEnvironment = $credentialVaultEnvironment
    GitHubRepositoryUrl  = [string]$sourceProjectSettings.GitHubRepositoryUrl
    LocalPath            = $resolvedLocalPath
    AgentPoolName        = [string]$sourceProjectSettings.AgentPoolName
    NumberOfBuildAgents  = [string]$sourceProjectSettings.NumbertOfBuildAgents
    GitUserName          = [string]$sourceProjectSettings.GitUserName
    GitUserEmail         = [string]$sourceProjectSettings.GitUserEmail
    BuildAgentUserName   = [string]$sourceProjectSettings.BuildAgents.UserName
    BuildAgentLocation   = [string]$sourceProjectSettings.BuildAgents.AzureLocation
    BuildAgentVmSize     = [string]$sourceProjectSettings.BuildAgents.AzureRoleSize
    Environments         = @(
        foreach ($environmentName in ($script:EnvironmentNames | Sort-Object))
        {
            $environment = $sourceDatum.Global.Azure.Environments[$environmentName]
            [ordered]@{
                Name                = $environmentName
                TenantName          = [string]$environment.AzTenantName
                HasExchangeOnline   = [string]$environment.HasExchangeOnline
                HasSharePointOnline = [string]$environment.HasSharePointOnline
            }
        }
    )
}
$identityJson = ConvertTo-Json -InputObject $resumeIdentity -Depth 10 -Compress
$identityBytes = [Text.Encoding]::UTF8.GetBytes($identityJson)
$identityHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($identityBytes)).ToLowerInvariant()
$checkpointDirectory = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft365DscWorkshop\AzureLabBootstrap'
$script:BootstrapCheckpointPath = Join-Path -Path $checkpointDirectory -ChildPath "$identityHash.json"
$allowedStages = @(
    'bootstrap-project-settings'
    'import-repository'
    'verify-import'
    'prepare-machine'
    'restore-target-dependencies'
    'initialize-target-build'
    'register-applications'
    'test-connections'
    'configure-devops'
    'create-vms'
    'configure-agents'
)

if (-not $Restart -and (Test-Path -LiteralPath $script:BootstrapCheckpointPath -PathType Leaf))
{
    try
    {
        $script:BootstrapCheckpoint = Get-Content -LiteralPath $script:BootstrapCheckpointPath -Raw |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $checkpointMigrated = Update-BootstrapCheckpointSchema -Checkpoint $script:BootstrapCheckpoint
        $savedStages = @($script:BootstrapCheckpoint.CompletedStages)
        if ($script:BootstrapCheckpoint.Fingerprint -ne $identityHash -or
            @($savedStages | Where-Object { $_ -notin $allowedStages }).Count -gt 0 -or
            ($script:BootstrapCheckpoint.CurrentStage -and $script:BootstrapCheckpoint.CurrentStage -notin $allowedStages))
        {
            throw 'The checkpoint schema or contents are invalid.'
        }

        $script:BootstrapCheckpoint.CompletedStages = $savedStages
        if ($checkpointMigrated)
        {
            Save-BootstrapCheckpoint
            Write-Host 'Updated the saved checkpoint and will repeat machine preparation, which may have stopped early in a previous run.' -ForegroundColor Yellow
        }
        if ($script:BootstrapCheckpoint.CurrentStage)
        {
            Write-Host "Resuming by retrying the previously interrupted stage '$($script:BootstrapCheckpoint.CurrentStage)'." -ForegroundColor Yellow
        }
        else
        {
            Write-Host 'Resuming from the last successfully completed stage.' -ForegroundColor Yellow
        }
    }
    catch
    {
        throw "Could not load the Azure lab resume checkpoint '$script:BootstrapCheckpointPath'. Use -Restart to discard it and start over. $($_.Exception.Message)"
    }
}
else
{
    if ($Restart -and (Test-Path -LiteralPath $script:BootstrapCheckpointPath -PathType Leaf))
    {
        Write-Host 'Discarding the saved Azure lab checkpoint and starting over.' -ForegroundColor Yellow
    }

    $script:BootstrapCheckpoint = @{
        SchemaVersion   = 3
        Fingerprint     = $identityHash
        CompletedStages = @()
        CurrentStage    = $null
    }
}

$sourceDatum = $null
$sourceProjectSettings = $null

try
{
    Invoke-BootstrapStage -Index 3 -Name 'bootstrap-project-settings' `
        -Description 'Create or reuse the credential Key Vault and securely collect project credentials' `
        -Action {
            $projectSettingsKeyVaultScript = Join-Path -Path $repositoryRoot -ChildPath 'lab\Azure\04 Setup Project Settings Key Vault.ps1'
            Write-Host "Running file in a clean PowerShell process: '$projectSettingsKeyVaultScript'." -ForegroundColor Yellow
            & $pwshCommand.Source -NoLogo -NoProfile -File $projectSettingsKeyVaultScript
            if ($LASTEXITCODE -ne 0)
            {
                throw "Project-settings Key Vault setup failed with exit code $LASTEXITCODE."
            }
        }

    $script:BootstrapCheckpoint.CompletedStages = @($script:BootstrapCheckpoint.CompletedStages | Where-Object {
            $_ -notin @('import-repository', 'verify-import')
        })
    Save-BootstrapCheckpoint
    Invoke-BootstrapStage -Index 4 -Name 'import-repository' `
        -Description 'Synchronize GitHub, Azure DevOps, and the local checkout' `
        -Action {
            $repositoryImportScript = Join-Path -Path $repositoryRoot -ChildPath 'lab\Azure\05 Import GitHub Repository.ps1'
            Write-Host "Running file in a clean PowerShell process: '$repositoryImportScript'." -ForegroundColor Yellow
            & $pwshCommand.Source -NoLogo -NoProfile -File $repositoryImportScript
            if ($LASTEXITCODE -ne 0)
            {
                throw "Azure DevOps repository import failed with exit code $LASTEXITCODE."
            }
        }

    $synchronizedCommit = & $script:GitCommand.Source -C $resolvedLocalPath rev-parse HEAD
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Could not read the synchronized repository commit.'
    }
    Update-BootstrapRepositoryCheckpoint -Commit $synchronizedCommit

    # Keep mutable project settings current on resume without overwriting generated Azure app credentials.
    $localProjectSettingsPath = Join-Path -Path $resolvedLocalPath -ChildPath 'source\Global\ProjectSettings.yml'
    Copy-Item -LiteralPath $sourceSettingsPath -Destination $localProjectSettingsPath -Force

    Push-Location -LiteralPath $resolvedLocalPath
    try
    {
        Invoke-BootstrapStage -Index 5 -Name 'verify-import' `
            -Description 'Verify the imported Azure script versions' `
            -Action {
                $scriptIssues = @(Get-ImportedAzureScriptIssues -RepositoryPath $resolvedLocalPath)
                if ($scriptIssues.Count -gt 0)
                {
                    $refreshDatum = $null
                    $refreshProjectSettings = $null
                    $refreshPat = $null
                    $refreshAuthorizationHeader = $null
                    try
                    {
                        $refreshDatum = New-DatumStructure -DefinitionFile (Join-Path -Path $repositoryRoot -ChildPath 'source\Datum.yml')
                        $refreshProjectSettings = $refreshDatum.Global.ProjectSettings
                        Import-Module -Name (Join-Path -Path $repositoryRoot -ChildPath 'lab\Azure\AzHelpers.psm1') -Force -ErrorAction Stop
                        $refreshProjectSettings = Get-M365DscProjectSettingsFromKeyVault -Datum $refreshDatum
                        $refreshPat = [string]$refreshProjectSettings.Global.ProjectSettings.PersonalAccessToken
                        $refreshAuthorizationHeader = "AUTHORIZATION: Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$refreshPat")))"
                        Update-OutdatedAzureDevOpsClone `
                            -RepositoryPath $resolvedLocalPath `
                            -AuthorizationHeader $refreshAuthorizationHeader
                    }
                    finally
                    {
                        if ($refreshDatum)
                        {
                            $refreshDatum.Global.ProjectSettings.PersonalAccessToken = $null
                        }
                        $refreshPat = $null
                        $refreshAuthorizationHeader = $null
                        $refreshProjectSettings = $null
                        $refreshDatum = $null
                    }

                    $scriptIssues = @(Get-ImportedAzureScriptIssues -RepositoryPath $resolvedLocalPath)
                    if ($scriptIssues.Count -gt 0)
                    {
                        throw "The refreshed Azure DevOps clone still has incompatible Azure scripts: $($scriptIssues -join ' ')"
                    }
                }
            }

        Invoke-BootstrapStage -Index 6 -Name 'prepare-machine' `
            -Description 'Prepare the Azure lab machine' `
            -Action {
                $preparationScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\00 Prep.ps1'
                Write-Host "Running file in a clean PowerShell process: '$preparationScript'." -ForegroundColor Yellow
                & $pwshCommand.Source -NoLogo -NoProfile -File $preparationScript -ProjectName $script:ProjectName
                if ($LASTEXITCODE -ne 0)
                {
                    throw "Azure lab machine preparation failed with exit code $LASTEXITCODE."
                }
            }

        Invoke-BootstrapStage -Index 7 -Name 'restore-target-dependencies' `
            -Description 'Restore dependencies for the imported checkout' `
            -Action {
                Initialize-TargetDependencies -SourceRoot $repositoryRoot -TargetRoot $resolvedLocalPath
            }

        $targetRequiredModules = Join-Path -Path $resolvedLocalPath -ChildPath 'output\RequiredModules'
        if ((Test-Path -LiteralPath $targetRequiredModules -PathType Container) -and
            $env:PSModulePath -notlike "*$targetRequiredModules*")
        {
            $env:PSModulePath = "$targetRequiredModules;$env:PSModulePath"
        }

        Invoke-BootstrapStage -Index 8 -Name 'initialize-target-build' `
            -Description 'Initialize the imported Azure build' `
            -Action {
                $buildIssues = @(Get-ImportedAzureScriptIssues -RepositoryPath $resolvedLocalPath)
                if ($buildIssues.Count -gt 0)
                {
                    throw "The imported Azure build is not ready to initialize: $($buildIssues -join ' ')"
                }

                $targetBuildScript = Join-Path -Path $resolvedLocalPath -ChildPath 'build.ps1'
                Write-Host "Running file: '$targetBuildScript' -Tasks azureinit in a clean PowerShell process."
                & $pwshCommand.Source -NoLogo -NoProfile -File $targetBuildScript -Tasks azureinit
                if ($LASTEXITCODE -ne 0)
                {
                    throw "The imported Azure build initialization task failed with exit code $LASTEXITCODE."
                }

                $targetRequiredModulesFile = Join-Path -Path $resolvedLocalPath -ChildPath 'RequiredModules.psd1'
                $targetRequiredModulesManifest = Import-PowerShellDataFile -LiteralPath $targetRequiredModulesFile
                $azComputeRequirement = $targetRequiredModulesManifest['Az.Compute']
                $azComputeVersion = if ($azComputeRequirement -is [System.Collections.IDictionary]) {
                    [string]$azComputeRequirement.Version
                }
                else {
                    [string]$azComputeRequirement
                }
                if ([string]::IsNullOrWhiteSpace($azComputeVersion))
                {
                    throw "The imported repository does not pin an Az.Compute version in '$targetRequiredModulesFile'."
                }

                Import-Module -Name Az.Compute -RequiredVersion $azComputeVersion -ErrorAction Stop
                Write-Host 'Completed imported Azure build initialization.' -ForegroundColor Green
            }

        $targetDatum = New-DatumStructure -DefinitionFile (Join-Path -Path $resolvedLocalPath -ChildPath 'source\Datum.yml')
        Import-Module -Name (Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\AzHelpers.psm1') -Force -ErrorAction Stop
        $targetDatum = Get-M365DscProjectSettingsFromKeyVault -Datum $targetDatum
        $targetProjectSettings = $targetDatum.Global.ProjectSettings
        if ([string]$targetProjectSettings.OrganizationName -ne $script:OrganizationName -or
            [string]$targetProjectSettings.ProjectName -ne $script:ProjectName -or
            [string]$targetProjectSettings.RepositoryName -ne $script:RepositoryName)
        {
            throw 'The imported ProjectSettings.yml does not match the Azure DevOps organization, project, or repository used for this setup.'
        }
        $script:targetEnvironmentNames = @(Get-EnvironmentNames -Datum $targetDatum)
        $targetPat = [string]$targetProjectSettings.PersonalAccessToken
        $targetBuildPassword = [string]$targetProjectSettings.BuildAgents.Password
        $script:secureBuildAgentPassword = ConvertTo-SecureStringFromKeyVault -Value $targetBuildPassword
        Assert-BuildAgentPassword -Password $script:secureBuildAgentPassword
        $script:GitAuthorizationHeader = "AUTHORIZATION: Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$targetPat")))"
        $targetProjectSettings.PersonalAccessToken = $null
        $targetProjectSettings.BuildAgents.Password = $null
        $targetPat = $null
        $targetBuildPassword = $null
        $targetDatum = $null
        $targetProjectSettings = $null

        Invoke-BootstrapStage -Index 9 -Name 'register-applications' `
            -Description 'Register tenant applications and store credentials' `
            -Action {
                $appRegistrationScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\10 Setup App Registrations.ps1'
                Invoke-LabScript -Path $appRegistrationScript -Arguments @{}
            }

        Invoke-BootstrapStage -Index 10 -Name 'test-connections' `
            -Description 'Test tenant application connections' `
            -Action {
                $connectionTestScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\11 Test Connection.ps1'
                Invoke-LabScript -Path $connectionTestScript -Arguments @{ EnvironmentName = $script:targetEnvironmentNames }
            }

        Invoke-BootstrapStage -Index 11 -Name 'configure-devops' `
            -Description 'Configure Azure DevOps environments, agent pool, and pipelines' `
            -Action {
                $projectSetupScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\20 Configure AzDo Project.ps1'
                Invoke-LabScriptWithGitAuthorization -Path $projectSetupScript -Arguments @{}
            }

        Invoke-BootstrapStage -Index 12 -Name 'create-vms' `
            -Description 'Install Bicep if needed and create Azure agent VMs' `
            -Action {
                Add-BicepInstallDirectoriesToPath
                $bicepCommand = Get-Command -Name bicep -ErrorAction SilentlyContinue
                if (-not $bicepCommand)
                {
                    $wingetCommand = Get-Command -Name winget -ErrorAction SilentlyContinue
                    if (-not $wingetCommand)
                    {
                        throw 'Bicep CLI and winget are both missing. Install Bicep before creating the agent VMs.'
                    }

                    Write-Host 'Installing the Bicep CLI with winget.'
                    Write-Host "Running command: '$($wingetCommand.Source) install --exact --id Microsoft.Bicep'."
                    & $wingetCommand.Source install --exact --id Microsoft.Bicep --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
                    $wingetExitCode = $LASTEXITCODE
                    Add-BicepInstallDirectoriesToPath
                    $bicepCommand = Get-Command -Name bicep -ErrorAction SilentlyContinue
                    if (-not $bicepCommand)
                    {
                        if ($wingetExitCode -ne 0)
                        {
                            throw "Bicep CLI installation failed with exit code $wingetExitCode and no executable was found."
                        }

                        throw 'Winget completed but Bicep was not found. Open a new PowerShell session or install Bicep to a directory on PATH.'
                    }

                    if ($wingetExitCode -ne 0)
                    {
                        Write-Warning "Winget returned exit code $wingetExitCode, but the existing Bicep CLI is available at '$($bicepCommand.Source)'. Continuing."
                    }
                }

                Write-Host "Using Bicep CLI at '$($bicepCommand.Source)'."
                & $bicepCommand.Source --version
                $bicepVersionExitCode = $LASTEXITCODE
                if ($bicepVersionExitCode -ne 0)
                {
                    throw "Bicep CLI failed its version check with exit code $bicepVersionExitCode."
                }

                $vmCreationScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\30 Create Agent VMs.ps1'
                Invoke-LabScript -Path $vmCreationScript -Arguments @{
                    EnvironmentName    = $script:targetEnvironmentNames
                    BuildAgentPassword = $script:secureBuildAgentPassword
                }
                $script:secureBuildAgentPassword.Dispose()
                $script:secureBuildAgentPassword = $null
            }

        Invoke-BootstrapStage -Index 13 -Name 'configure-agents' `
            -Description 'Configure Azure DevOps agents on the new VMs' `
            -Action {
                $agentSetupScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\31 Agent Setup.ps1'
                Invoke-LabScriptWithGitAuthorization -Path $agentSetupScript -Arguments @{ EnvironmentName = $script:targetEnvironmentNames }
                $script:GitAuthorizationHeader = $null
            }
    }
    finally
    {
        Pop-Location
    }

    Remove-Item -LiteralPath $script:BootstrapCheckpointPath -Force -ErrorAction Stop
    Write-Host "Azure lab bootstrap completed for '$script:OrganizationName/$script:ProjectName'." -ForegroundColor Green
    Write-Host 'No DSC push pipeline was queued. Review and run tenant-changing pipelines explicitly.'
}
catch
{
    Write-Host "Bootstrap failed during phase $($script:BootstrapPhase)/$($script:BootstrapPhaseCount): $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally
{
    Restore-GitAuthorizationHeader
    if ($script:secureBuildAgentPassword)
    {
        $script:secureBuildAgentPassword.Dispose()
    }
    $script:secureBuildAgentPassword = $null
    $script:GitAuthorizationHeader = $null
}
