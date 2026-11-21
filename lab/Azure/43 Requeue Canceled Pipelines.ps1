[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Parameter()]
    [int[]]$BuildIds,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$LookbackDays = 30
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
$pipelineNames = 'build', 'export', 'deltaReport', 'push', 'reapply', 'test'
$selectedPipelines = foreach ($pipelineName in $pipelineNames)
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
$buildsUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/build/builds?definitions=$definitionIds&statusFilter=completed&resultFilter=canceled&queryOrder=queueTimeDescending&`$top=100&api-version=7.1"
$canceledBuilds = @(Invoke-VSTeamRequest -Url $buildsUri -Method Get -ErrorAction Stop | Select-Object -ExpandProperty value)
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$LookbackDays)
$canceledBuilds = @($canceledBuilds | Where-Object {
    $_.finishTime -and ([datetime]$_.finishTime).ToUniversalTime() -ge $cutoff
})

function Format-LocalDateTime
{
    param (
        [Parameter()]
        [object]$Value
    )

    if (-not $Value)
    {
        return 'not available'
    }

    return ([datetime]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
}

if ($canceledBuilds.Count -eq 0)
{
    Write-Host "No canceled M365DSC pipeline runs were found in the last $LookbackDays day(s)." -ForegroundColor Yellow
    return
}

if ($BuildIds)
{
    $unknownBuildIds = @($BuildIds | Where-Object { $_ -notin $canceledBuilds.id })
    if ($unknownBuildIds.Count -gt 0)
    {
        throw "Build ID(s) not found among recent canceled M365DSC runs: $($unknownBuildIds -join ', ')."
    }

    $selectedBuilds = @($canceledBuilds | Where-Object { $_.id -in $BuildIds })
}
else
{
    Write-Host "`nCanceled M365DSC runs from the last $LookbackDays day(s) (times shown in local time):" -ForegroundColor Yellow
    foreach ($build in $canceledBuilds)
    {
        $durationStart = if ($build.startTime) { [datetime]$build.startTime } else { [datetime]$build.queueTime }
        $duration = if ($build.finishTime -and $durationStart)
        {
            (([datetime]$build.finishTime) - $durationStart).ToString('c')
        }
        else
        {
            'not available'
        }
        $buildUrl = $build._links.web.href
        if (-not $buildUrl)
        {
            $buildUrl = "https://dev.azure.com/$organizationName/$projectPath/_build/results?buildId=$($build.id)&view=results"
        }
        $requestedBy = if ($build.requestedBy.displayName) { $build.requestedBy.displayName } else { 'not available' }
        $buildNumber = if ($build.buildNumber) { $build.buildNumber } else { 'not available' }

        Write-Host "`n[$($build.id)] $($build.definition.name) - canceled" -ForegroundColor Cyan
        Write-Host "  Build number : $buildNumber"
        Write-Host "  Queued       : $(Format-LocalDateTime $build.queueTime)"
        Write-Host "  Started      : $(Format-LocalDateTime $build.startTime)"
        Write-Host "  Finished     : $(Format-LocalDateTime $build.finishTime)"
        Write-Host "  Duration     : $duration"
        Write-Host "  Requested by : $requestedBy"
        Write-Host "  Reason       : $($build.reason)"
        Write-Host "  Branch       : $($build.sourceBranch)"
        Write-Host "  Commit       : $($build.sourceVersion)"
        Write-Host "  Run details  : $buildUrl" -ForegroundColor DarkCyan
    }

    $selection = Read-Host 'Enter the build ID(s) to requeue, separated by commas, or press Enter to cancel'
    if ([string]::IsNullOrWhiteSpace($selection))
    {
        Write-Host 'No runs selected; nothing was queued.'
        return
    }

    $selectedIds = @(
        $selection -split ',' |
            ForEach-Object { $_.Trim() } |
                Where-Object { $_ } |
                    ForEach-Object {
                        $parsedId = 0
                        if (-not [int]::TryParse($_, [ref]$parsedId))
                        {
                            throw "Invalid build ID '$($_)'. Enter numeric IDs separated by commas."
                        }

                        $parsedId
                    } |
                        Select-Object -Unique
    )
    $unknownBuildIds = @($selectedIds | Where-Object { $_ -notin $canceledBuilds.id })
    if ($unknownBuildIds.Count -gt 0)
    {
        throw "Build ID(s) were not listed as recent canceled M365DSC runs: $($unknownBuildIds -join ', ')."
    }

    $selectedBuilds = @($canceledBuilds | Where-Object { $_.id -in $selectedIds })
}

foreach ($build in $selectedBuilds)
{
    if (-not $build.sourceBranch -or -not $build.sourceVersion)
    {
        throw "Canceled run $($build.id) does not contain both a source branch and commit; refusing to requeue it with a different source."
    }

    $queueUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/build/builds?api-version=7.1"
    $queueRequest = @{
        definition    = @{
            id = $build.definition.id
        }
        sourceBranch  = $build.sourceBranch
        sourceVersion = $build.sourceVersion
    } | ConvertTo-Json -Depth 10 -Compress

    $target = "$($build.definition.name) canceled run $($build.id) ($($build.sourceBranch) @ $($build.sourceVersion))"
    if ($PSCmdlet.ShouldProcess($target, 'Queue a new run from the same branch and commit'))
    {
        $newBuild = Invoke-VSTeamRequest -Url $queueUri -Method Post -ContentType 'application/json' -Body $queueRequest -ErrorAction Stop
        if (-not $newBuild.id)
        {
            throw "Azure DevOps did not return a build ID when requeueing canceled run $($build.id)."
        }

        Write-Host "Queued '$($build.definition.name)' as new run $($newBuild.id), based on canceled run $($build.id)." -ForegroundColor Green
    }
}
