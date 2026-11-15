$defaultModulePaths = @(
    if ($PSVersionTable.PSEdition -eq 'Core')
    {
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'PowerShell\Modules'
        Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules'
    }
    else
    {
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WindowsPowerShell\Modules'
    }
    Join-Path -Path $PSHOME -ChildPath 'Modules'
    Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'
    Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\Modules'
)
$currentModulePaths = $env:PSModulePath -split [System.IO.Path]::PathSeparator | Where-Object { $_ }
$env:PSModulePath = (@($defaultModulePaths) + $currentModulePaths | Select-Object -Unique) -join [System.IO.Path]::PathSeparator

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + ";$requiredModulesPath"
}

Import-Module -Name VSTeam -RequiredVersion '7.15.2' -ErrorAction Stop

$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml

# ----------------------------------------------------------
#            Setting project parameters
# ----------------------------------------------------------
if ($datum.Global.ProjectSettings.OrganizationName -eq '<OrganizationName>' -or $null -eq $datum.Global.ProjectSettings.OrganizationName)
{
    $datum.Global.ProjectSettings.OrganizationName = Read-Host -Prompt 'Enter the name of your Azure DevOps organization'
    $datum.Global.ProjectSettings | ConvertTo-Yaml | Out-File $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
}

if ($datum.Global.ProjectSettings.ProjectName -eq '<ProjectName>' -or $null -eq $datum.Global.ProjectSettings.ProjectName)
{
    $guessedProjectName = $PSScriptRoot.Split('\')[-3]
    $choice = Read-Host -Prompt "Enter the name of your Azure DevOps project or press <Enter> to use the default ($guessedProjectName)"
    if ($choice -eq '')
    {
        $datum.Global.ProjectSettings.ProjectName = $guessedProjectName
    }
    else
    {
        $datum.Global.ProjectSettings.ProjectName = $choice
    }
    $datum.Global.ProjectSettings | ConvertTo-Yaml | Out-File $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
}

if ($datum.Global.ProjectSettings.AgentPoolName -eq '<AgentPoolName>' -or $null -eq $datum.Global.ProjectSettings.AgentPoolName)
{
    $proposedAgentPoolName = "$($datum.Global.ProjectSettings.ProjectName)DSC"
    $choice = Read-Host -Prompt "Enter the name of your Azure DevOps agent pool or press <Enter> to use the default ($proposedAgentPoolName)"
    if ($choice -eq '')
    {
        $datum.Global.ProjectSettings.AgentPoolName = $proposedAgentPoolName
    }
    else
    {
        $datum.Global.ProjectSettings.AgentPoolName = $choice
    }
    $datum.Global.ProjectSettings | ConvertTo-Yaml | Out-File $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
}

if ($datum.Global.ProjectSettings.PersonalAccessToken -eq '<PersonalAccessToken>' -or $null -eq $datum.Global.ProjectSettings.PersonalAccessToken)
{
    $pat = Read-Host -Prompt 'Enter your Azure DevOps Personal Access Token'
    $pass = $datum.__Definition.DatumHandlers.'Datum.ProtectedData::ProtectedDatum'.CommandOptions.PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force
    $datum.Global.ProjectSettings.PersonalAccessToken = $pat | Protect-Datum -Password $pass -MaxLineLength 9999

    $datum.Global.ProjectSettings | ConvertTo-Yaml | Out-File $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
}

if ((git status -s) -like '*source/Global/ProjectSettings.yml')
{
    git add $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to stage ProjectSettings.yml.'
    }

    git commit -m 'Updated Azure DevOps Organization Data' | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to commit ProjectSettings.yml.'
    }

    git push
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to push ProjectSettings.yml. The commit remains local; synchronize the branch before rerunning this script.'
    }
}

Set-VSTeamAccount -Account "https://dev.azure.com/$($datum.Global.ProjectSettings.OrganizationName)/" -PersonalAccessToken $datum.Global.ProjectSettings.PersonalAccessToken -ErrorAction Stop
Write-Host "Connected to Azure DevOps organization '$($datum.Global.ProjectSettings.OrganizationName)' with PAT."

# ----------------------------------------------------------
#            Creating project and agent pool
# ----------------------------------------------------------
try
{
    Get-VSTeamPool | Out-Null
}
catch
{
    Write-Error "No data returned from Azure DevOps organization '$($datum.Global.ProjectSettings.OrganizationName)'. The authentication might have failed, please check the Organization Name and the PAT."
    return
}

try
{
    Get-VSTeamProject -Name $datum.Global.ProjectSettings.ProjectName -WarningAction SilentlyContinue | Out-Null
    Write-Host "Project '$($datum.Global.ProjectSettings.ProjectName)' already exists."
}
catch
{
    $project = Add-VSTeamProject -ProjectName $datum.Global.ProjectSettings.ProjectName -Description 'Microsoft365DSCWorkshop Demo Project' -Visibility public -ProcessTemplate Agile
    if ($null -eq $project)
    {
        Write-Error "Failed to create project '$($datum.Global.ProjectSettings.ProjectName)'. Please check the warnings above."
        return
    }
    else
    {
        Write-Host "Project '$($datum.Global.ProjectSettings.ProjectName)' created."
    }
}

$uri = "https://dev.azure.com/$($datum.Global.ProjectSettings.OrganizationName)/$($datum.Global.ProjectSettings.ProjectName)/_apis/distributedtask/queues/?api-version=5.1"
$queues = Invoke-VSTeamRequest -Url $uri

if (-not ($queues.value.name -eq $datum.Global.ProjectSettings.AgentPoolName))
{
    $requestBodyAgentPool = @{
        name          = $datum.Global.ProjectSettings.AgentPoolName
        autoProvision = $true
        autoUpdate    = $true
        autoSize      = $true
        isHosted      = $false
        poolType      = 'automation'
    } | ConvertTo-Json

    $queue = Invoke-VSTeamRequest -Url $uri -Method POST -ContentType 'application/json' -Body $requestBodyAgentPool
    Write-Host "Agent pool '$($datum.Global.ProjectSettings.AgentPoolName)' created."

    $url = "https://dev.azure.com/$($datum.Global.ProjectSettings.OrganizationName)/$($datum.Global.ProjectSettings.ProjectName)/_apis/pipelines/pipelinePermissions/queue/$($queue.id)?api-version=7.1-preview.1"
    $body = @{
        allPipelines = @{
            authorized = 'true'
        }
    } | ConvertTo-Json

    Write-Host "Allowing all pipelines to use agent pool '$($datum.Global.ProjectSettings.AgentPoolName)' in project '$($datum.Global.ProjectSettings.ProjectName)'."
    $response = Invoke-VSTeamRequest -Url $url -Body $body -ContentType application/json -Method PATCH
}
else
{
    Write-Host "Agent pool '$($datum.Global.ProjectSettings.AgentPoolName)' already exists."
}

Write-Host ''
Write-Host "Disabling features in project '$($datum.Global.ProjectSettings.ProjectName)'."
$project = Get-VSTeamProject -Name $datum.Global.ProjectSettings.ProjectName

$featuresToDisable = 'ms.feed.feed', #Artifacts
'ms.vss-work.agile', #Boards
'ms.vss-test-web.test' #Test Plans
#'ms.vss-code.version-control' #Repos

foreach ($featureToDisable in $featuresToDisable)
{
    $id = "host/project/$($project.Id)/$featureToDisable"
    $buildFeature = Invoke-VSTeamRequest -Area FeatureManagement -Resource FeatureStates -Id $id
    $buildFeature.state = 'disabled'
    $buildFeature = $buildFeature | ConvertTo-Json

    Write-Host "Disabling feature '$featureToDisable' in project '$($datum.Global.ProjectSettings.ProjectName)'."
    Invoke-VSTeamRequest -Method Patch -ContentType 'application/json' -Body $buildFeature -Area FeatureManagement -Resource FeatureStates -Id $id -Version '7.1-preview.1' | Out-Null
}

# ----------------------------------------------------------
#            Creating environments in project
# ----------------------------------------------------------
Write-Host ''
Write-Host "Creating environments in project '$($datum.Global.ProjectSettings.ProjectName)'."

$environments = $datum.Global.Azure.Environments.Keys
$existingEnvironments = Invoke-VSTeamRequest -Method Get -Area distributedtask -Resource environments -Version '7.1-preview.1' -ProjectName $datum.Global.ProjectSettings.ProjectName

foreach ($environment in $environments)
{
    if (-not ($existingEnvironments.value | Where-Object { $_.name -eq $environment }))
    {
        Write-Host "Creating environment '$environment' in project '$($datum.Global.ProjectSettings.ProjectName)'."
        $requestBodyEnvironment = @{
            name = $environment
        } | ConvertTo-Json

        $environment = Invoke-VSTeamRequest -Method Post -ContentType application/json -Body $requestBodyEnvironment -ProjectName $datum.Global.ProjectSettings.ProjectName -Area distributedtask -Resource environments -Version 7.1
        $url = "https://dev.azure.com/$($datum.Global.ProjectSettings.OrganizationName)/$($datum.Global.ProjectSettings.ProjectName)/_apis/pipelines/pipelinePermissions/environment/$($environment.id)?api-version=7.1-preview.1"
        $body = @{
            allPipelines = @{
                authorized = 'true'
            }
        } | ConvertTo-Json

        Write-Host "Allowing all pipelines to use environment '$environment' in project '$($datum.Global.ProjectSettings.ProjectName)'."
        $response = Invoke-VSTeamRequest -Url $url -Body $body -ContentType application/json -Method PATCH
    }
    else
    {
        Write-Host "Environment '$environment' already exists in project '$($datum.Global.ProjectSettings.ProjectName)'."
    }
}

# ------------------------------------------------------------------
#        Configuring environment-driven pipelines and pool defaults
# ------------------------------------------------------------------
Write-Host 'Changing build pipelines to use only the configured environments' -ForegroundColor Yellow

$azureConfigurationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Global\Azure.yml'
$azureConfiguration = Get-Content -Path $azureConfigurationPath -Raw | ConvertFrom-Yaml -Ordered -ErrorAction Stop
$environments = @($azureConfiguration.Environments.Keys | ForEach-Object { [string]$_ })
if (-not $environments)
{
    throw "No environments were found in 'source\Global\Azure.yml'. Configure at least one environment before updating pipelines."
}

# deltaReport uses windows-latest and has no poolName parameter to adapt.
$pipelinesToAdapt = 'build.yml', 'export.yml', 'pull.yml', 'push.yml', 'reapply.yml', 'test.yml'
$pipelinesToAdapt = @(
    Get-ChildItem -Path $PSScriptRoot\..\..\pipelines -File | Where-Object Name -In $pipelinesToAdapt
    Get-Item -Path $PSScriptRoot\..\..\pipelines\Troubleshooting\winrmDiagnostics.yml -ErrorAction Stop
)

Write-Host "Known environments: $($environments -join ', ')"
Write-Host 'Pipelines to adapt:'
$pipelinesToAdapt | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ''

foreach ($pipeline in $pipelinesToAdapt)
{
    $pipelineChanged = $false
    Write-Host "Adapting pipeline $($pipeline.FullName)"
    $pipelineYaml = Get-Content $pipeline.FullName -Raw | ConvertFrom-Yaml -Ordered
    $buildEnvironmentsParameter = @($pipelineYaml.parameters | Where-Object Name -EQ buildEnvironments)
    if ($buildEnvironmentsParameter.Count -gt 1)
    {
        throw "Pipeline '$($pipeline.Name)' has more than one 'buildEnvironments' parameter."
    }

    if ($buildEnvironmentsParameter.Count -eq 1)
    {
        [void]$pipelineYaml.parameters.Remove($buildEnvironmentsParameter[0])
        $pipelineChanged = $true
    }

    Write-Host "  Setting agent pool name to '$($datum.Global.ProjectSettings.AgentPoolName)' in pipeline '$($pipeline.Name)'."
    if (($pipelineYaml.parameters | Where-Object name -EQ poolName).default -ne $datum.Global.ProjectSettings.AgentPoolName)
    {
        Write-Host "  Setting agent pool name to '$($datum.Global.ProjectSettings.AgentPoolName)' in pipeline '$($pipeline.Name)'."
        ($pipelineYaml.parameters | Where-Object name -EQ poolName).default = $datum.Global.ProjectSettings.AgentPoolName
        $pipelineChanged = $true
    }
    else
    {
        Write-Host "  Agent pool name is already set to '$($datum.Global.ProjectSettings.AgentPoolName)' in pipeline '$($pipeline.Name)'."
    }

    $configuredBuildEnvironments = [System.Collections.Generic.List[object]]::new()
    for ($environmentIndex = 0; $environmentIndex -lt $environments.Count; $environmentIndex++)
    {
        $environmentDefinition = [ordered]@{
            Name = [string]$environments[$environmentIndex]
        }
        if ($pipeline.Name -in @('build.yml', 'push.yml', 'reapply.yml') -and $environmentIndex -gt 0)
        {
            $environmentDefinition.DependsOn = [string]$environments[$environmentIndex - 1]
        }

        $configuredBuildEnvironments.Add($environmentDefinition)
    }

    $templateCallsUpdated = 0
    $usesDynamicEnvironmentMatrix = @($pipelineYaml.stages | Where-Object {
            $_.template -eq 'environmentMatrixTemplate.yml' -or
            $_.template -match '[\\/]environmentMatrixTemplate\.yml$'
        }).Count -gt 0

    foreach ($stage in $pipelineYaml.stages)
    {
        if ($stage.parameters -and $stage.parameters.Contains('buildEnvironments'))
        {
            $templateCallsUpdated++

            $currentBuildEnvironments = @($stage.parameters.buildEnvironments)
            $environmentDefinitionsMatch = $currentBuildEnvironments.Count -eq $configuredBuildEnvironments.Count
            for ($environmentIndex = 0; $environmentDefinitionsMatch -and $environmentIndex -lt $configuredBuildEnvironments.Count; $environmentIndex++)
            {
                if ([string]$currentBuildEnvironments[$environmentIndex].Name -cne $configuredBuildEnvironments[$environmentIndex].Name -or
                    [string]$currentBuildEnvironments[$environmentIndex].DependsOn -cne [string]$configuredBuildEnvironments[$environmentIndex].DependsOn)
                {
                    $environmentDefinitionsMatch = $false
                }
            }

            if (-not $environmentDefinitionsMatch)
            {
                $stage.parameters.buildEnvironments = $configuredBuildEnvironments
                $pipelineChanged = $true
            }
        }
    }
    if ($templateCallsUpdated -eq 0 -and -not $usesDynamicEnvironmentMatrix)
    {
        throw "Pipeline '$($pipeline.Name)' has neither a dynamic environment matrix template nor a stage template that accepts 'buildEnvironments'."
    }

    if ($usesDynamicEnvironmentMatrix)
    {
        Write-Host "  Environment matrix in '$($pipeline.Name)' uses the pipeline environment parameters synchronized from 'source\Global\Azure.yml'."
    }

    if ($templateCallsUpdated -gt 0)
    {
        Write-Host "  Set $templateCallsUpdated stage template(s) to configured environments: $($environments -join ', ')."
    }

    if ($pipelineChanged)
    {
        Write-Host "  Saving changes to pipeline '$($pipeline.Name)'."
        $pipelineYaml | ConvertTo-Yaml | Out-File -FilePath $pipeline.FullName
    }
}

$repositoryRoot = (Resolve-Path -Path $PSScriptRoot\..\..).Path

# 'git diff' reports paths relative to the repository root, so git must run there as well
$changedFiles = git -C $repositoryRoot diff --name-only | Where-Object { $_ -match '^pipelines/(?:[^/]+/)*[^/]+\.yml$' }
if ($changedFiles.Count -gt 0)
{
    Write-Host 'Committing changes to pipelines.'
    foreach ($changedFile in $changedFiles)
    {
        git -C $repositoryRoot add $changedFile
        if ($LASTEXITCODE -ne 0)
        {
            throw "Failed to stage pipeline file '$changedFile'."
        }
    }

    git -C $repositoryRoot commit --only -m 'Updated pipelines to use only the configured environments' -- $changedFiles | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to commit pipeline changes.'
    }

    git -C $repositoryRoot push
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Failed to push pipeline changes. The commit remains local; synchronize the branch before rerunning this script.'
    }
}
else
{
    Write-Host 'No changes to commit, no pipeline was changed.'
}

# ----------------------------------------------------------
#                  Creating pipelines
# ----------------------------------------------------------

Write-Host 'Creating pipelines in project.'
$pipelineNames = 'build', 'deltaReport', 'export', 'push', 'reapply', 'test', 'winrmDiagnostics'
foreach ($pipelineName in $pipelineNames)
{
    $displayName = if ($pipelineName -eq 'winrmDiagnostics') { 'M365DSC WinRM Diagnostics' } else { "M365DSC $pipelineName" }
    if (Invoke-VSTeamRequest -Area pipelines -Version 7.1 -Method Get -ProjectName $datum.Global.ProjectSettings.ProjectName | Select-Object -ExpandProperty value | Where-Object { $_.name -eq $displayName })
    {
        Write-Host "Pipeline '$displayName' already exists in project '$($datum.Global.ProjectSettings.ProjectName)'."
        continue
    }

    $repo = Get-VSTeamGitRepository -Name $datum.Global.ProjectSettings.ProjectName -ProjectName $datum.Global.ProjectSettings.ProjectName
    $pipelinePath = if ($pipelineName -eq 'winrmDiagnostics') { 'pipelines/Troubleshooting/winrmDiagnostics.yml' } else { "pipelines/$pipelineName.yml" }
    $pipelineParams = @{
        configuration = @{
            path       = $pipelinePath
            repository = @{
                id   = $repo.Id
                type = 'azureReposGit'
            }
            type       = 'yaml'
        }
        name          = $displayName
    }

    Write-Host "Creating pipeline '$displayName' in project '$($datum.Global.ProjectSettings.ProjectName)'."
    $pipelineParams = $pipelineParams | ConvertTo-Json -Compress
    Invoke-VSTeamRequest -Area pipelines -Version 7.1 -Method Post -Body $pipelineParams -JSON -ProjectName $datum.Global.ProjectSettings.ProjectName | Out-Null
}

Write-Host 'All done.'
