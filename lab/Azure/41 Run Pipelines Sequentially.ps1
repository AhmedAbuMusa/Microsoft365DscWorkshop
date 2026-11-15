[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Parameter()]
    [ValidateCount(1, 6)]
    [ValidateSet('build', 'export', 'deltaReport', 'push', 'reapply', 'test')]
    [string[]]$PipelineNames = @('build', 'export', 'deltaReport', 'push', 'reapply', 'test'),

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 360,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$PollIntervalSeconds = 15
)

$repositoryRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..') -ErrorAction Stop).Path
$branchName = (& git -C $repositoryRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0)
{
    throw "Could not determine the current Git branch in '$repositoryRoot'."
}
if (-not $branchName)
{
    throw 'The repository is in a detached HEAD state. Check out a branch before queueing pipelines.'
}
$branchRef = "refs/heads/$branchName"

$pipelineNamesForConfirmation = $PipelineNames -join ' -> '
if (-not $PSCmdlet.ShouldProcess("M365DSC pipelines on '$branchRef': $pipelineNamesForConfirmation", 'Queue each pipeline in order and wait for success'))
{
    return
}

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules -ErrorAction Stop).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $requiredModulesPath
}

Import-Module -Name VSTeam -RequiredVersion '7.15.2' -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$organizationName = $datum.Global.ProjectSettings.OrganizationName
$projectName = $datum.Global.ProjectSettings.ProjectName
$personalAccessToken = $datum.Global.ProjectSettings.PersonalAccessToken

if (-not $organizationName -or $organizationName -eq '<OrganizationName>' -or
    -not $projectName -or $projectName -eq '<ProjectName>' -or
    -not $personalAccessToken -or $personalAccessToken -eq '<PersonalAccessToken>')
{
    throw 'Azure DevOps organization, project, and PAT must be configured in source/Global/ProjectSettings.yml.'
}

Set-VSTeamAccount -Account "https://dev.azure.com/$organizationName/" -PersonalAccessToken $personalAccessToken -ErrorAction Stop

Write-Host "Using current Git branch '$branchRef'. Azure DevOps runs the branch's pushed version; uncommitted local changes are not included."
$projectPath = [System.Uri]::EscapeDataString($projectName)
$pipelinesUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines?api-version=7.1"
$pipelines = (Invoke-VSTeamRequest -Url $pipelinesUri -Method Get -ErrorAction Stop).value

foreach ($pipelineName in $PipelineNames)
{
    $displayName = "M365DSC $pipelineName"
    $pipeline = @($pipelines | Where-Object name -EQ $displayName)
    if ($pipeline.Count -ne 1)
    {
        throw "Expected exactly one Azure DevOps pipeline named '$displayName'; found $($pipeline.Count)."
    }

    Write-Host "Queueing '$displayName' and waiting for it to complete."
    $pipelineId = $pipeline[0].id
    $runsUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines/$pipelineId/runs?api-version=7.1"
    $runRequest = @{
        resources = @{
            repositories = @{
                self = @{
                    refName = $branchRef
                }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $run = Invoke-VSTeamRequest -Url $runsUri -Method Post -ContentType 'application/json' -Body $runRequest -ErrorAction Stop
    if (-not $run.id)
    {
        throw "Azure DevOps did not return a run ID for '$displayName'."
    }

    Write-Host "Queued '$displayName' as run $($run.id) (state: $($run.state))."
    $runUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines/$pipelineId/runs/$($run.id)?api-version=7.1"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    do
    {
        if ((Get-Date) -ge $deadline)
        {
            throw "Timed out after $TimeoutMinutes minutes waiting for '$displayName' run $($run.id). The run may still be active in Azure DevOps."
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        $run = Invoke-VSTeamRequest -Url $runUri -Method Get -ErrorAction Stop
        Write-Host "'$displayName' run $($run.id): $($run.state) $($run.result)"
    }
    until ($run.state -eq 'completed')

    if ($run.result -ne 'succeeded')
    {
        throw "'$displayName' run $($run.id) completed with result '$($run.result)'. Stopping the sequence."
    }

    Write-Host "'$displayName' succeeded."
}

Write-Host 'All requested pipelines completed successfully.' -ForegroundColor Green
