<#
.SYNOPSIS
    Imports the configured GitHub repository into Azure DevOps and prepares its local checkout.

.DESCRIPTION
    Reads source/Global/ProjectSettings.yml, creates or reuses the configured Azure DevOps
    project and repository, imports GitHub content, and clones it to LocalPath. On every
    run, fast-forwards the GitHub default branch into Azure DevOps and the local checkout.
    Local ProjectSettings.yml and Azure.yml are preserved.

.EXAMPLE
    & '.\lab\Azure\05 Import GitHub Repository.ps1'

.NOTES
    Requires PowerShell 7.6.10 or later, Git, restored repository dependencies, and a
    configured source/Global/ProjectSettings.yml.
#>

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.6.10')
{
    throw 'PowerShell 7.6.10 or later is required. Start the script from pwsh, not Windows PowerShell.'
}
if (-not $IsWindows)
{
    throw 'The Azure lab repository import supports Windows only.'
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
$requiredModulesPath = Join-Path -Path $repositoryRoot -ChildPath 'output\RequiredModules'
if ((Test-Path -LiteralPath $requiredModulesPath -PathType Container) -and
    $env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = "$requiredModulesPath;$env:PSModulePath"
}

Import-Module -Name Datum -ErrorAction Stop
Import-Module -Name Datum.ProtectedData -ErrorAction Stop
Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force -ErrorAction Stop

$script:GitCommand = Get-Command -Name git -ErrorAction SilentlyContinue
if (-not $script:GitCommand)
{
    throw 'Git is required but was not found on PATH.'
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

function Invoke-AzureDevOpsRestMethod
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post')]
        [string]$Method,

        [Parameter()]
        [object]$Body
    )

    $request = @{
        Uri     = $Uri
        Method  = $Method
        Headers = @{ Authorization = $script:AuthorizationHeader }
    }
    if ($PSBoundParameters.ContainsKey('Body'))
    {
        $request.ContentType = 'application/json'
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 20
    }

    Invoke-RestMethod @request
}

function Get-AzureDevOpsHttpStatusCode
{
    param
    (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode)
    {
        return [int]$response.StatusCode
    }

    return 0
}

function Wait-AzureDevOpsOperation
{
    param
    (
        [Parameter(Mandatory)]
        [string]$OperationId,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $operationUri = "https://dev.azure.com/$script:OrganizationName/_apis/operations/$OperationId`?api-version=7.1"
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 0; $attempt -lt 180; $attempt++)
    {
        $operation = Invoke-AzureDevOpsRestMethod -Uri $operationUri -Method Get
        if ($operation.status -in @('succeeded', 'completed'))
        {
            return
        }
        if ($operation.status -in @('failed', 'cancelled', 'aborted'))
        {
            throw "$Description failed in Azure DevOps (status: '$($operation.status)')."
        }

        if ($attempt % 3 -eq 0)
        {
            Write-Host "$Description is still in progress (elapsed: $([math]::Floor($stopwatch.Elapsed.TotalSeconds)) seconds)."
        }
        Start-Sleep -Seconds 10
    }

    throw "$Description did not finish within 30 minutes. Check Azure DevOps before retrying."
}

function Get-AzureDevOpsProject
{
    $encodedProjectName = [Uri]::EscapeDataString($script:ProjectName)
    $projectUri = "https://dev.azure.com/$script:OrganizationName/_apis/projects/$encodedProjectName`?api-version=7.1"
    try
    {
        Invoke-AzureDevOpsRestMethod -Uri $projectUri -Method Get
    }
    catch
    {
        if ((Get-AzureDevOpsHttpStatusCode -ErrorRecord $_) -eq 404)
        {
            return $null
        }

        throw
    }
}

function Ensure-AzureDevOpsProject
{
    $project = Get-AzureDevOpsProject
    if ($project)
    {
        if ($project.state -ne 'wellFormed')
        {
            throw "Azure DevOps project '$script:ProjectName' exists but is not ready (state: '$($project.state)')."
        }

        Write-Host "Using existing Azure DevOps project '$script:ProjectName'."
        return
    }

    $createProjectUri = "https://dev.azure.com/$script:OrganizationName/_apis/projects`?api-version=7.1"
    $createProjectBody = @{
        name         = $script:ProjectName
        description  = 'Microsoft365DSC workshop lab'
        visibility   = 'private'
        capabilities = @{
            versioncontrol = @{ sourceControlType = 'Git' }
            processTemplate = @{ templateTypeId = '6b724908-ef14-45cf-84f8-768b5384da45' }
        }
    }
    $operation = Invoke-AzureDevOpsRestMethod -Uri $createProjectUri -Method Post -Body $createProjectBody
    if (-not $operation.id)
    {
        throw "Azure DevOps did not return an operation ID while creating project '$script:ProjectName'."
    }

    Wait-AzureDevOpsOperation -OperationId $operation.id -Description "Creating project '$script:ProjectName'"
}

function Ensure-AzureDevOpsRepository
{
    $encodedProjectName = [Uri]::EscapeDataString($script:ProjectName)
    $repositoriesUri = "https://dev.azure.com/$script:OrganizationName/$encodedProjectName/_apis/git/repositories?api-version=7.1"
    $repositories = (Invoke-AzureDevOpsRestMethod -Uri $repositoriesUri -Method Get).value
    $repository = $repositories | Where-Object name -EQ $script:RepositoryName | Select-Object -First 1
    if (-not $repository)
    {
        $repository = Invoke-AzureDevOpsRestMethod -Uri $repositoriesUri -Method Post -Body @{ name = $script:RepositoryName }
    }

    $importRequestsUri = "https://dev.azure.com/$script:OrganizationName/$encodedProjectName/_apis/git/repositories/$($repository.id)/importRequests"
    $importUri = "$importRequestsUri`?api-version=7.1"
    $imports = (Invoke-AzureDevOpsRestMethod -Uri $importUri -Method Get).value
    $matchingImport = $imports |
        Where-Object { $_.parameters.gitSource.url.TrimEnd('/') -eq $script:GitHubRepositoryUrl.TrimEnd('/') } |
        Select-Object -First 1

    if ($matchingImport)
    {
        if ($matchingImport.status -in @('completed', 'succeeded'))
        {
            Write-Host "Repository '$script:RepositoryName' was already imported from the configured GitHub repository."
            return
        }
        if ($matchingImport.status -in @('failed', 'abandoned'))
        {
            throw "The previous GitHub import for '$script:RepositoryName' failed (status: '$($matchingImport.status)')."
        }

        $importRequestId = $matchingImport.importRequestId
    }
    elseif ($imports)
    {
        throw "Repository '$script:RepositoryName' has an import request for a different GitHub source. Refusing to start another import."
    }
    elseif ($repository.defaultBranch)
    {
        throw "Repository '$script:RepositoryName' already has content but no matching import request. Refusing to overwrite it."
    }
    else
    {
        $importRequest = Invoke-AzureDevOpsRestMethod -Uri $importUri -Method Post -Body @{
            parameters = @{ gitSource = @{ url = $script:GitHubRepositoryUrl } }
        }
        $importRequestId = $importRequest.importRequestId
    }

    if (-not $importRequestId)
    {
        throw "Azure DevOps did not return an import request ID for repository '$script:RepositoryName'."
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 0; $attempt -lt 180; $attempt++)
    {
        $importStatusUri = "$importRequestsUri/$importRequestId`?api-version=7.1"
        $importStatus = Invoke-AzureDevOpsRestMethod -Uri $importStatusUri -Method Get
        if ($importStatus.status -in @('completed', 'succeeded'))
        {
            Write-Host "Imported GitHub source into Azure DevOps repository '$script:RepositoryName'."
            return
        }
        if ($importStatus.status -in @('failed', 'abandoned'))
        {
            throw "GitHub import into '$script:RepositoryName' failed (status: '$($importStatus.status)')."
        }

        if ($attempt % 3 -eq 0)
        {
            Write-Host "GitHub import into '$script:RepositoryName' is still in progress (elapsed: $([math]::Floor($stopwatch.Elapsed.TotalSeconds)) seconds)."
        }
        Start-Sleep -Seconds 10
    }

    throw 'The repository import did not finish within 30 minutes. Check Azure DevOps before retrying.'
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

function Test-GitRemoteMatches
{
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string]$ExpectedRemote
    )

    $actualRemote = (& $script:GitCommand.Source -C $RepositoryPath remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0)
    {
        return $false
    }

    $actualUri = $null
    $expectedUri = $null
    if (-not [Uri]::TryCreate([string]$actualRemote, [UriKind]::Absolute, [ref]$actualUri) -or
        -not [Uri]::TryCreate($ExpectedRemote, [UriKind]::Absolute, [ref]$expectedUri))
    {
        return $false
    }

    $actualPath = [Uri]::UnescapeDataString($actualUri.AbsolutePath).TrimEnd('/')
    $expectedPath = [Uri]::UnescapeDataString($expectedUri.AbsolutePath).TrimEnd('/')
    return $actualUri.Host -eq $expectedUri.Host -and $actualPath -eq $expectedPath
}

function Copy-WorkshopConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$TargetRoot
    )

    foreach ($relativePath in @('source\Global\ProjectSettings.yml', 'source\Global\Azure.yml'))
    {
        $sourcePath = Join-Path -Path $SourceRoot -ChildPath $relativePath
        $targetPath = Join-Path -Path $TargetRoot -ChildPath $relativePath
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    }
}

function Invoke-RepositoryGit
{
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = & $script:GitCommand.Source @Arguments
    if ($LASTEXITCODE -ne 0)
    {
        $command = if ($Arguments[0] -eq '-C') { $Arguments[2] } else { $Arguments[0] }
        throw "Repository synchronization Git command '$command' failed with exit code $LASTEXITCODE."
    }
    return $result
}

function Get-GitHubRepositoryHead
{
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryUrl
    )

    $remoteHead = @(Invoke-RepositoryGit -Arguments @('ls-remote', '--symref', $RepositoryUrl, 'HEAD'))
    $branchLine = $remoteHead | Where-Object { $_ -match '^ref: refs/heads/.+\s+HEAD$' } | Select-Object -First 1
    if (-not $branchLine -or $branchLine -notmatch '^ref: refs/heads/(.+)\s+HEAD$')
    {
        throw 'The GitHub repository does not advertise a default branch.'
    }

    return $Matches[1]
}

function Sync-GitHubRepository
{
    param
    (
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string]$RepositoryUrl,

        [Parameter(Mandatory)]
        [string]$Branch
    )

    $gitPrefix = @('-C', $RepositoryPath)
    $localBranch = Invoke-RepositoryGit -Arguments ($gitPrefix + @('symbolic-ref', '--short', 'HEAD'))
    if ($localBranch -ne $Branch)
    {
        throw "Local checkout must be on GitHub's default branch '$Branch', not '$localBranch'."
    }

    $configurationPaths = @('source/Global/ProjectSettings.yml', 'source/Global/Azure.yml')
    $stagedPaths = @(Invoke-RepositoryGit -Arguments ($gitPrefix + @('diff', '--cached', '--name-only')))
    $changedPaths = @(Invoke-RepositoryGit -Arguments ($gitPrefix + @('diff', '--name-only', 'HEAD')))
    if ($stagedPaths.Count -gt 0 -or @($changedPaths | Where-Object { $_ -notin $configurationPaths }).Count -gt 0)
    {
        throw 'Local checkout has staged changes or edits outside ProjectSettings.yml and Azure.yml. Commit or stash them before synchronizing.'
    }

    Invoke-RepositoryGit -Arguments ($gitPrefix + @('fetch', '--no-tags', $RepositoryUrl, "+refs/heads/${Branch}:refs/bootstrap/github-default")) | Out-Null
    $sourceCommit = Invoke-RepositoryGit -Arguments ($gitPrefix + @('rev-parse', 'refs/bootstrap/github-default'))
    $localCommit = Invoke-RepositoryGit -Arguments ($gitPrefix + @('rev-parse', 'HEAD'))
    & $script:GitCommand.Source -C $RepositoryPath merge-base --is-ancestor $localCommit $sourceCommit
    if ($LASTEXITCODE -eq 1)
    {
        throw 'Local checkout contains commits not present on GitHub. Refusing to overwrite them.'
    }
    if ($LASTEXITCODE -ne 0)
    {
        throw "Could not compare the local checkout with GitHub (Git exit code $LASTEXITCODE)."
    }

    Invoke-RepositoryGit -Arguments ($gitPrefix + @('push', '--no-force', '--no-mirror', '--no-follow-tags', 'origin', "${sourceCommit}:refs/heads/$Branch")) | Out-Null
    Invoke-RepositoryGit -Arguments ($gitPrefix + @('fetch', '--no-tags', 'origin', "+refs/heads/${Branch}:refs/remotes/origin/$Branch")) | Out-Null

    if ($localCommit -ne $sourceCommit)
    {
        $configurationBackups = @{}
        try
        {
            foreach ($relativePath in $configurationPaths)
            {
                $path = Join-Path -Path $RepositoryPath -ChildPath ($relativePath -replace '/', '\')
                $configurationBackups[$path] = [IO.File]::ReadAllBytes($path)
            }
            Invoke-RepositoryGit -Arguments ($gitPrefix + @('restore', '--worktree', '--') + $configurationPaths) | Out-Null
            Invoke-RepositoryGit -Arguments ($gitPrefix + @('merge', '--ff-only', $sourceCommit)) | Out-Null
        }
        finally
        {
            foreach ($path in $configurationBackups.Keys)
            {
                [IO.File]::WriteAllBytes($path, $configurationBackups[$path])
            }
        }
    }

    $updatedCommit = Invoke-RepositoryGit -Arguments ($gitPrefix + @('rev-parse', 'HEAD'))
    $remoteCommit = @(Invoke-RepositoryGit -Arguments ($gitPrefix + @('ls-remote', 'origin', "refs/heads/$Branch")))
    if ($updatedCommit -ne $sourceCommit -or $remoteCommit.Count -ne 1 -or
        ($remoteCommit[0] -split '\s+')[0] -ne $sourceCommit)
    {
        throw 'GitHub, Azure DevOps, and the local checkout did not converge to the same commit. Retry synchronization.'
    }

    Write-Host "Synchronized GitHub branch '$Branch' at '$sourceCommit' into Azure DevOps and the local checkout." -ForegroundColor Green
}

$sourceSettingsPath = Join-Path -Path $repositoryRoot -ChildPath 'source\Global\ProjectSettings.yml'
$sourceAzurePath = Join-Path -Path $repositoryRoot -ChildPath 'source\Global\Azure.yml'
if (-not (Test-Path -LiteralPath $sourceSettingsPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceAzurePath -PathType Leaf))
{
    throw 'Both source/Global/ProjectSettings.yml and source/Global/Azure.yml are required.'
}

$datum = New-DatumStructure -DefinitionFile (Join-Path -Path $repositoryRoot -ChildPath 'source\Datum.yml')
$datum = Get-M365DscProjectSettingsFromKeyVault -Datum $datum -CredentialType personal-access-token
$projectSettings = $datum.Global.ProjectSettings
$script:OrganizationName = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'OrganizationName' -Path 'source/Global/ProjectSettings.yml: OrganizationName')
$script:ProjectName = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'ProjectName' -Path 'source/Global/ProjectSettings.yml: ProjectName')
$script:RepositoryName = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'RepositoryName' -Path 'source/Global/ProjectSettings.yml: RepositoryName')
$script:GitHubRepositoryUrl = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'GitHubRepositoryUrl' -Path 'source/Global/ProjectSettings.yml: GitHubRepositoryUrl')
$localPathValue = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'LocalPath' -Path 'source/Global/ProjectSettings.yml: LocalPath')
$gitUserName = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'GitUserName' -Path 'source/Global/ProjectSettings.yml: GitUserName')
$gitUserEmail = [string](Get-RequiredConfigurationValue -Configuration $projectSettings -Name 'GitUserEmail' -Path 'source/Global/ProjectSettings.yml: GitUserEmail')
$plainPat = [string]$projectSettings.PersonalAccessToken

if ($script:OrganizationName -notmatch '^[A-Za-z0-9._-]+$')
{
    throw "Invalid OrganizationName in 'source/Global/ProjectSettings.yml'."
}
if ($script:ProjectName -notmatch '^[A-Za-z0-9._ -]+$' -or
    $script:RepositoryName -notmatch '^[A-Za-z0-9._ -]+$')
{
    throw 'ProjectName and RepositoryName in ProjectSettings.yml may contain only letters, digits, spaces, periods, underscores, and hyphens.'
}

$githubUri = $null
if (-not [Uri]::TryCreate($script:GitHubRepositoryUrl, [UriKind]::Absolute, [ref]$githubUri) -or
    $githubUri.Scheme -ne 'https' -or $githubUri.Host -ne 'github.com')
{
    throw 'GitHubRepositoryUrl in ProjectSettings.yml must be an HTTPS URL hosted on github.com.'
}

$resolvedLocalPath = [IO.Path]::GetFullPath($localPathValue)
$repositoryPrefix = $repositoryRoot.TrimEnd('\') + '\'
if ($resolvedLocalPath.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedLocalPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase))
{
    throw 'LocalPath must be outside the source checkout.'
}

$encodedProjectName = [Uri]::EscapeDataString($script:ProjectName)
$encodedRepositoryName = [Uri]::EscapeDataString($script:RepositoryName)
$cloneUrl = "https://$script:OrganizationName@dev.azure.com/$script:OrganizationName/$encodedProjectName/_git/$encodedRepositoryName"

if (Test-Path -LiteralPath $resolvedLocalPath)
{
    if (-not (Test-Path -LiteralPath $resolvedLocalPath -PathType Container))
    {
        throw "LocalPath '$resolvedLocalPath' exists and is not a directory."
    }

    if (@(Get-ChildItem -LiteralPath $resolvedLocalPath -Force).Count -gt 0 -and
        -not (Test-GitRemoteMatches -RepositoryPath $resolvedLocalPath -ExpectedRemote $cloneUrl))
    {
        throw "LocalPath '$resolvedLocalPath' is not empty or a clone of the configured Azure DevOps repository."
    }
}

$script:AuthorizationHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plainPat"))
$script:GitAuthorizationHeader = "AUTHORIZATION: $($script:AuthorizationHeader)"
$plainPat = $null
$datum = $null
$projectSettings = $null

try
{
    $githubBranch = Get-GitHubRepositoryHead -RepositoryUrl $script:GitHubRepositoryUrl
    Write-Host "Ensuring Azure DevOps project '$script:ProjectName' exists."
    Ensure-AzureDevOpsProject

    Write-Host "Importing '$script:GitHubRepositoryUrl' into Azure DevOps repository '$script:RepositoryName'."
    Ensure-AzureDevOpsRepository
    $script:AuthorizationHeader = $null

    if (-not (Test-Path -LiteralPath $resolvedLocalPath))
    {
        $null = New-Item -ItemType Directory -Path $resolvedLocalPath -Force
    }

    $newClone = @(Get-ChildItem -LiteralPath $resolvedLocalPath -Force).Count -eq 0
    if ($newClone)
    {
        Set-GitAuthorizationHeader -AuthorizationHeader $script:GitAuthorizationHeader
        try
        {
            & $script:GitCommand.Source clone --branch $githubBranch $cloneUrl $resolvedLocalPath
            if ($LASTEXITCODE -ne 0)
            {
                throw "Failed to clone '$script:RepositoryName' from Azure DevOps."
            }
        }
        finally
        {
            Restore-GitAuthorizationHeader
        }

        Copy-WorkshopConfiguration -SourceRoot $repositoryRoot -TargetRoot $resolvedLocalPath
    }

    Set-GitAuthorizationHeader -AuthorizationHeader $script:GitAuthorizationHeader
    try
    {
        Sync-GitHubRepository -RepositoryPath $resolvedLocalPath -RepositoryUrl $script:GitHubRepositoryUrl -Branch $githubBranch
    }
    finally
    {
        Restore-GitAuthorizationHeader
    }

    & $script:GitCommand.Source -C $resolvedLocalPath config user.name $gitUserName
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to configure GitUserName in the local repository.'
    }
    & $script:GitCommand.Source -C $resolvedLocalPath config user.email $gitUserEmail
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to configure GitUserEmail in the local repository.'
    }

    Write-Host "Azure DevOps repository '$script:RepositoryName' is ready at '$resolvedLocalPath'." -ForegroundColor Green
}
finally
{
    Restore-GitAuthorizationHeader
    $script:AuthorizationHeader = $null
    $script:GitAuthorizationHeader = $null
    $plainPat = $null
    $protectionPassword = $null
    $secureProtectionPassword = $null
    $datum = $null
    $projectSettings = $null
}
