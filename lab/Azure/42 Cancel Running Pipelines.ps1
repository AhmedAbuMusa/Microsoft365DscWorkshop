[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter()]
    [ValidateSet('build', 'export', 'deltaReport', 'push', 'reapply', 'test')]
    [string[]]$PipelineNames = @('build', 'export', 'deltaReport', 'push', 'reapply', 'test')
)

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules -ErrorAction Stop).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $requiredModulesPath
}

Import-Module -Name VSTeam -RequiredVersion '7.15.2' -ErrorAction Stop
Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$datum = Get-M365DscProjectSettingsFromKeyVault -Datum $datum -CredentialType personal-access-token
$organizationName = $datum.Global.ProjectSettings.OrganizationName
$projectName = $datum.Global.ProjectSettings.ProjectName
$personalAccessToken = $datum.Global.ProjectSettings.PersonalAccessToken

if (-not $organizationName -or $organizationName -eq '<OrganizationName>' -or
    -not $projectName -or $projectName -eq '<ProjectName>' -or
    -not $personalAccessToken -or $personalAccessToken -eq '<PersonalAccessToken>')
{
    throw 'Configure the Azure DevOps organization and project in ProjectSettings.yml, then store a valid PAT in the configured Key Vault.'
}

Set-VSTeamAccount -Account "https://dev.azure.com/$organizationName/" -PersonalAccessToken $personalAccessToken -ErrorAction Stop

$projectPath = [System.Uri]::EscapeDataString($projectName)
$pipelinesUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines?api-version=7.1"
$pipelines = (Invoke-VSTeamRequest -Url $pipelinesUri -Method Get -ErrorAction Stop).value
$selectedPipelines = foreach ($pipelineName in $PipelineNames)
{
    $displayName = "M365DSC $pipelineName"
    $pipelineMatches = @($pipelines | Where-Object name -EQ $displayName)
    if ($pipelineMatches.Count -ne 1)
    {
        throw "Expected exactly one Azure DevOps pipeline named '$displayName'; found $($pipelineMatches.Count)."
    }

    $pipelineMatches[0]
}

$definitionIds = ($selectedPipelines.id -join ',')
$buildsBaseUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/build/builds?definitions=$definitionIds&queryOrder=queueTimeDescending&`$top=1000&api-version=7.1"
$queuedBuildsUri = "$buildsBaseUri&statusFilter=notStarted"
$runningBuildsUri = "$buildsBaseUri&statusFilter=inProgress"
$queuedBuilds = @(Invoke-VSTeamRequest -Url $queuedBuildsUri -Method Get -ErrorAction Stop | Select-Object -ExpandProperty value)
$runningBuilds = @(Invoke-VSTeamRequest -Url $runningBuildsUri -Method Get -ErrorAction Stop | Select-Object -ExpandProperty value)
$activeBuilds = @($queuedBuilds + $runningBuilds | Sort-Object queueTime)

if ($activeBuilds.Count -eq 0)
{
    Write-Host "No queued or running M365DSC pipelines found for: $($PipelineNames -join ', ')." -ForegroundColor Green
    return
}

Write-Host "`nFound $($activeBuilds.Count) queued or running M365DSC pipeline(s) ($($queuedBuilds.Count) queued, $($runningBuilds.Count) running):" -ForegroundColor Yellow
$activeBuilds |
    Select-Object @{ Name = 'Pipeline'; Expression = { $_.definition.name } }, id,
        @{ Name = 'State'; Expression = { if ($_.status -eq 'notStarted') { 'queued' } else { 'running' } } },
        sourceBranch, queueTime |
    Format-Table -AutoSize

$cancellationRequestsSent = 0
foreach ($build in $activeBuilds)
{
    $buildUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/build/builds/$($build.id)?api-version=7.1"
    $cancelRequest = @{
        id     = $build.id
        status = 'cancelling'
    } | ConvertTo-Json -Compress

    $buildState = if ($build.status -eq 'notStarted') { 'queued' } else { 'running' }
    if ($PSCmdlet.ShouldProcess("$($build.definition.name) $buildState run $($build.id)", 'Cancel pipeline'))
    {
        $null = Invoke-VSTeamRequest -Url $buildUri -Method Patch -ContentType 'application/json' -Body $cancelRequest -ErrorAction Stop
        $cancellationRequestsSent++
        Write-Host "Cancellation requested for '$($build.definition.name)' $buildState run $($build.id)." -ForegroundColor Cyan
    }
}

if ($cancellationRequestsSent -gt 0)
{
    Write-Host "`nSent $cancellationRequestsSent cancellation request(s). Azure DevOps will complete cancellation asynchronously." -ForegroundColor Yellow
    Write-Host 'To rerun a canceled build from its original commit, use .\lab\Azure\43 Requeue Canceled Pipelines.ps1.'
}
elseif ($WhatIfPreference)
{
    Write-Host "`nWhatIf: no cancellation requests were sent." -ForegroundColor Yellow
}
else
{
    Write-Host "`nNo cancellation requests were sent." -ForegroundColor Yellow
}
