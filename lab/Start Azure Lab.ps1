<#
.SYNOPSIS
    Imports the workshop repository into Azure DevOps and provisions the Azure lab.

.DESCRIPTION
    Reads configuration from source/Global/ProjectSettings.yml and source/Global/Azure.yml,
    then runs the Azure preparation, dependency, tenant, project, VM, and agent setup steps.
    Tenant administrator sign-in and consent remain interactive.

.NOTES
    Run from an elevated PowerShell 7.6.10 or later session. Set all configuration values
    in the two YAML files before starting. If a run fails, rerun this script to resume from
    the failed stage; use -Restart to discard its saved progress and start over.
#>

[CmdletBinding()]
param
(
    [Parameter()]
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
$script:BootstrapPhase = 0
$script:BootstrapPhaseCount = 12

function Write-BootstrapPhase
{
    param
    (
        [Parameter(Mandatory)]
        [ValidateRange(1, 12)]
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

function Invoke-BootstrapStage
{
    param
    (
        [Parameter(Mandatory)]
        [ValidateRange(3, 12)]
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

function ConvertFrom-SecureStringPlainText
{
    param
    (
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try
    {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function ConvertTo-ProtectedDatumValue
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [securestring]$ProtectionPassword
    )

    $Value | Protect-Datum -Password $ProtectionPassword -MaxLineLength 9999
}

function ConvertTo-SecureStringFromConfiguration
{
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        '',
        Justification = 'The VM password is read from the protected Datum configuration and is passed as a SecureString to the VM script.'
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
        foreach ($field in @('AzTenantId', 'AzTenantName', 'AzSubscriptionId'))
        {
            if ([string]::IsNullOrWhiteSpace([string]$environment.$field) -or [string]$environment.$field -match '^<.+>$')
            {
                throw "Set 'Environments.$environmentName.$field' in 'source/Global/Azure.yml'."
            }
        }

        foreach ($field in @('HasExchangeOnline', 'HasSharePointOnline'))
        {
            if ($null -eq $environment.$field -or $environment.$field -isnot [bool])
            {
                throw "'Environments.$environmentName.$field' in 'source/Global/Azure.yml' must be true or false."
            }
        }

        foreach ($field in @('AzTenantId', 'AzSubscriptionId'))
        {
            $parsedGuid = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$environment.$field, [ref]$parsedGuid) -or $parsedGuid -eq [Guid]::Empty)
            {
                throw "'Environments.$environmentName.$field' in 'source/Global/Azure.yml' must be a non-empty GUID."
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

function Set-ProjectSettingsProtectedValues
{
    param
    (
        [Parameter(Mandatory)]
        [object]$ProjectSettings,

        [Parameter(Mandatory)]
        [string]$ConfigurationPath,

        [Parameter(Mandatory)]
        [securestring]$ProtectionPassword
    )

    $rawConfiguration = Get-Content -LiteralPath $ConfigurationPath -Raw
    $patIsProtected = $rawConfiguration -match '(?m)^PersonalAccessToken:\s*[''"]?\[ENC='
    $passwordIsProtected = $rawConfiguration -match '(?m)^\s+Password:\s*[''"]?\[ENC='
    if ($patIsProtected -and $passwordIsProtected)
    {
        return
    }

    if (-not $patIsProtected)
    {
        $ProjectSettings.PersonalAccessToken = ConvertTo-ProtectedDatumValue `
            -Value ([string]$ProjectSettings.PersonalAccessToken) `
            -ProtectionPassword $ProtectionPassword
    }
    if (-not $passwordIsProtected)
    {
        $ProjectSettings.BuildAgents.Password = ConvertTo-ProtectedDatumValue `
            -Value ([string]$ProjectSettings.BuildAgents.Password) `
            -ProtectionPassword $ProtectionPassword
    }

    $ProjectSettings |
        ConvertTo-Yaml |
        Set-Content -LiteralPath $ConfigurationPath -Encoding utf8
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
$sourceBuildScript = Join-Path -Path $repositoryRoot -ChildPath 'build.ps1'
Write-BootstrapPhase -Index 1 -Description 'Restore dependencies for the source checkout'
Write-Host "Running file: '$sourceBuildScript' -UsePSResourceGet -ResolveDependency."
try
{
    & $pwshCommand.Source -NoLogo -NoProfile -File $sourceBuildScript -UsePSResourceGet -ResolveDependency
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

$sourceRequiredModules = Join-Path -Path $repositoryRoot -ChildPath 'output\RequiredModules'
if ($env:PSModulePath -notlike "*$sourceRequiredModules*")
{
    $env:PSModulePath = "$sourceRequiredModules;$env:PSModulePath"
}
Import-Module -Name Datum -ErrorAction Stop
Import-Module -Name Datum.ProtectedData -ErrorAction Stop

Write-BootstrapPhase -Index 2 -Description 'Read and validate configuration; protect local credentials'
$sourceDatum = New-DatumStructure -DefinitionFile (Join-Path -Path $repositoryRoot -ChildPath 'source\Datum.yml')
$sourceProjectSettings = $sourceDatum.Global.ProjectSettings
$script:OrganizationName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'OrganizationName' -Path 'source/Global/ProjectSettings.yml: OrganizationName')
$script:ProjectName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'ProjectName' -Path 'source/Global/ProjectSettings.yml: ProjectName')
$script:RepositoryName = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'RepositoryName' -Path 'source/Global/ProjectSettings.yml: RepositoryName')
$localPathValue = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'LocalPath' -Path 'source/Global/ProjectSettings.yml: LocalPath')
$null = Get-RequiredConfigurationValue -Configuration $sourceProjectSettings -Name 'AgentPoolName' -Path 'source/Global/ProjectSettings.yml: AgentPoolName'
$plainBuildAgentPassword = [string](Get-RequiredConfigurationValue -Configuration $sourceProjectSettings.BuildAgents -Name 'Password' -Path 'source/Global/ProjectSettings.yml: BuildAgents.Password')
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
$passwordForValidation = ConvertTo-SecureStringFromConfiguration -Value $plainBuildAgentPassword
try
{
    Assert-BuildAgentPassword -Password $passwordForValidation
}
finally
{
    $passwordForValidation.Dispose()
}

$resolvedLocalPath = [IO.Path]::GetFullPath($localPathValue)
$repositoryPrefix = $repositoryRoot.TrimEnd('\') + '\'
if ($resolvedLocalPath.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedLocalPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase))
{
    throw 'LocalPath must be outside the source checkout.'
}

$script:EnvironmentNames = @(Get-EnvironmentNames -Datum $sourceDatum)
$protectionPassword = [string]$sourceDatum.__Definition.DatumHandlers.'Datum.ProtectedData::ProtectedDatum'.CommandOptions.PlainTextPassword
if ([string]::IsNullOrWhiteSpace($protectionPassword))
{
    throw "Datum ProtectedData has no PlainTextPassword configured in 'source/Datum.yml'."
}
$secureProtectionPassword = ConvertTo-SecureStringFromConfiguration -Value $protectionPassword

try
{
    Set-ProjectSettingsProtectedValues `
        -ProjectSettings $sourceProjectSettings `
        -ConfigurationPath $sourceSettingsPath `
        -ProtectionPassword $secureProtectionPassword
}
finally
{
    $secureProtectionPassword.Dispose()
}

$plainBuildAgentPassword = $null
$protectionPassword = $null
$secureProtectionPassword = $null

$resumeIdentity = [ordered]@{
    RepositoryRoot       = $repositoryRoot
    OrganizationName     = $script:OrganizationName
    ProjectName          = $script:ProjectName
    RepositoryName       = $script:RepositoryName
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
                TenantId            = [string]$environment.AzTenantId
                SubscriptionId      = [string]$environment.AzSubscriptionId
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
        $savedStages = @($script:BootstrapCheckpoint.CompletedStages)
        if ($script:BootstrapCheckpoint.SchemaVersion -ne 1 -or
            $script:BootstrapCheckpoint.Fingerprint -ne $identityHash -or
            @($savedStages | Where-Object { $_ -notin $allowedStages }).Count -gt 0 -or
            ($script:BootstrapCheckpoint.CurrentStage -and $script:BootstrapCheckpoint.CurrentStage -notin $allowedStages))
        {
            throw 'The checkpoint schema or contents are invalid.'
        }

        $script:BootstrapCheckpoint.CompletedStages = $savedStages
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
        SchemaVersion   = 1
        Fingerprint     = $identityHash
        CompletedStages = @()
        CurrentStage    = $null
    }
}

$sourceDatum = $null
$sourceProjectSettings = $null

try
{
    Invoke-BootstrapStage -Index 3 -Name 'import-repository' `
        -Description 'Import GitHub repository and prepare the Azure DevOps checkout' `
        -Action {
            $repositoryImportScript = Join-Path -Path $repositoryRoot -ChildPath 'lab\Azure\05 Import GitHub Repository.ps1'
            Invoke-LabScript -Path $repositoryImportScript
        }

    # Keep mutable project settings current on resume without overwriting generated Azure app credentials.
    $localProjectSettingsPath = Join-Path -Path $resolvedLocalPath -ChildPath 'source\Global\ProjectSettings.yml'
    Copy-Item -LiteralPath $sourceSettingsPath -Destination $localProjectSettingsPath -Force

    Push-Location -LiteralPath $resolvedLocalPath
    try
    {
        Invoke-BootstrapStage -Index 4 -Name 'verify-import' `
            -Description 'Verify the imported Azure script versions' `
            -Action {
                foreach ($scriptAndParameter in @(
                        @{ Path = 'lab\Azure\00 Prep.ps1'; Parameter = 'ProjectName' }
                        @{ Path = 'lab\Azure\30 Create Agent VMs.ps1'; Parameter = 'BuildAgentPassword' }
                        @{ Path = 'lab\Azure\31 Agent Setup.ps1'; Parameter = 'EnvironmentName' }
                    ))
                {
                    $scriptPath = Join-Path -Path $resolvedLocalPath -ChildPath $scriptAndParameter.Path
                    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf))
                    {
                        throw "Required imported script '$($scriptAndParameter.Path)' was not found in the Azure DevOps clone. The clone likely contains an older GitHub import with the legacy 'lab\' layout. Publish the current Azure scripts to GitHub, refresh the Azure DevOps repository from that version, then remove this clone or set LocalPath to an empty directory before retrying."
                    }

                    $tokens = $null
                    $parseErrors = $null
                    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
                    if ($parseErrors)
                    {
                        $parseDetails = ($parseErrors | ForEach-Object {
                                "line $($_.Extent.StartLineNumber): $($_.Message)"
                            }) -join '; '
                        throw "Imported script '$($scriptAndParameter.Path)' has PowerShell parse errors: $parseDetails"
                    }

                    $parameterNames = @($scriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                    if ($scriptAndParameter.Parameter -notin $parameterNames)
                    {
                        throw "Imported script '$($scriptAndParameter.Path)' is outdated. Import the current GitHub default branch before retrying."
                    }
                }
            }

        Invoke-BootstrapStage -Index 5 -Name 'prepare-machine' `
            -Description 'Prepare the Azure lab machine' `
            -Action {
                Invoke-LabScript -Path (Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\00 Prep.ps1') `
                    -Arguments @{ ProjectName = $script:ProjectName }
            }

        Invoke-BootstrapStage -Index 6 -Name 'restore-target-dependencies' `
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

        Invoke-BootstrapStage -Index 7 -Name 'initialize-target-build' `
            -Description 'Initialize the imported repository build' `
            -Action {
                $targetBuildScript = Join-Path -Path $resolvedLocalPath -ChildPath 'build.ps1'
                Write-Host "Running file: '$targetBuildScript' -Tasks init."
                & $targetBuildScript -Tasks init
                if (-not $?)
                {
                    throw 'The imported repository build initialization task failed.'
                }
                Write-Host 'Completed imported repository build initialization.' -ForegroundColor Green
            }

        $targetProjectSettingsPath = Join-Path -Path $resolvedLocalPath -ChildPath 'source\Global\ProjectSettings.yml'
        $targetDatum = New-DatumStructure -DefinitionFile (Join-Path -Path $resolvedLocalPath -ChildPath 'source\Datum.yml')
        $targetProjectSettings = $targetDatum.Global.ProjectSettings
        if ([string]$targetProjectSettings.OrganizationName -ne $script:OrganizationName -or
            [string]$targetProjectSettings.ProjectName -ne $script:ProjectName -or
            [string]$targetProjectSettings.RepositoryName -ne $script:RepositoryName)
        {
            throw 'The imported ProjectSettings.yml does not match the Azure DevOps organization, project, or repository used for this setup.'
        }
        $script:targetEnvironmentNames = @(Get-EnvironmentNames -Datum $targetDatum)
        $targetPat = [string](Get-RequiredConfigurationValue -Configuration $targetProjectSettings -Name 'PersonalAccessToken' -Path 'ProjectSettings.yml: PersonalAccessToken')
        $targetBuildPassword = [string](Get-RequiredConfigurationValue -Configuration $targetProjectSettings.BuildAgents -Name 'Password' -Path 'ProjectSettings.yml: BuildAgents.Password')
        $script:secureBuildAgentPassword = ConvertTo-SecureStringFromConfiguration -Value $targetBuildPassword
        Assert-BuildAgentPassword -Password $script:secureBuildAgentPassword
        $targetProtectionPassword = [string]$targetDatum.__Definition.DatumHandlers.'Datum.ProtectedData::ProtectedDatum'.CommandOptions.PlainTextPassword
        $secureTargetProtectionPassword = ConvertTo-SecureStringFromConfiguration -Value $targetProtectionPassword
        try
        {
            Set-ProjectSettingsProtectedValues `
                -ProjectSettings $targetProjectSettings `
                -ConfigurationPath $targetProjectSettingsPath `
                -ProtectionPassword $secureTargetProtectionPassword
        }
        finally
        {
            $secureTargetProtectionPassword.Dispose()
        }
        $secureTargetProtectionPassword = $null
        $targetProtectionPassword = $null
        $targetBuildPassword = $null
        $targetDatum = $null
        $targetProjectSettings = $null
        $script:GitAuthorizationHeader = "AUTHORIZATION: Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$targetPat")))"
        $targetPat = $null

        Invoke-BootstrapStage -Index 8 -Name 'register-applications' `
            -Description 'Register tenant applications and store credentials' `
            -Action {
                $appRegistrationScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\10 Setup App Registrations.ps1'
                Invoke-LabScript -Path $appRegistrationScript -Arguments @{}
            }

        Invoke-BootstrapStage -Index 9 -Name 'test-connections' `
            -Description 'Test tenant application connections' `
            -Action {
                $connectionTestScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\11 Test Connection.ps1'
                Invoke-LabScript -Path $connectionTestScript -Arguments @{ EnvironmentName = $script:targetEnvironmentNames }
            }

        Invoke-BootstrapStage -Index 10 -Name 'configure-devops' `
            -Description 'Configure Azure DevOps environments, agent pool, and pipelines' `
            -Action {
                $projectSetupScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\20 Configure AzDo Project.ps1'
                Invoke-LabScriptWithGitAuthorization -Path $projectSetupScript -Arguments @{}
            }

        Invoke-BootstrapStage -Index 11 -Name 'create-vms' `
            -Description 'Install Bicep if needed and create Azure agent VMs' `
            -Action {
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
                    if ($LASTEXITCODE -ne 0)
                    {
                        throw "Bicep CLI installation failed with exit code $LASTEXITCODE."
                    }
                    $bicepInstallPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Bicep CLI'
                    if (Test-Path -LiteralPath (Join-Path -Path $bicepInstallPath -ChildPath 'bicep.exe'))
                    {
                        $env:PATH = "$bicepInstallPath;$env:PATH"
                    }
                    if (-not (Get-Command -Name bicep -ErrorAction SilentlyContinue))
                    {
                        throw 'Bicep installed but was not found on PATH. Open a new PowerShell session and rerun the VM setup stage.'
                    }
                }
                else
                {
                    Write-Host "Using Bicep CLI at '$($bicepCommand.Source)'."
                }

                $vmCreationScript = Join-Path -Path $resolvedLocalPath -ChildPath 'lab\Azure\30 Create Agent VMs.ps1'
                Invoke-LabScript -Path $vmCreationScript -Arguments @{
                    EnvironmentName    = $script:targetEnvironmentNames
                    BuildAgentPassword = $script:secureBuildAgentPassword
                }
                $script:secureBuildAgentPassword.Dispose()
                $script:secureBuildAgentPassword = $null
            }

        Invoke-BootstrapStage -Index 12 -Name 'configure-agents' `
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
