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

$pipelineNamesForConfirmation = $PipelineNames -join ', '
if (-not $PSCmdlet.ShouldProcess("M365DSC pipelines on '$branchRef': $pipelineNamesForConfirmation", 'Queue all pipelines in parallel and wait for completion'))
{
    return
}

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules -ErrorAction Stop).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $requiredModulesPath
}

Import-Module -Name VSTeam -RequiredVersion '7.15.2' -ErrorAction Stop
Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$datum = Get-M365DscProjectSecrets -Datum $datum -CredentialType personal-access-token
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

Write-Host "Using current Git branch '$branchRef'. Azure DevOps runs the branch's pushed version; uncommitted local changes are not included."
$projectPath = [System.Uri]::EscapeDataString($projectName)
$pipelinesUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines?api-version=7.1"
$pipelines = (Invoke-VSTeamRequest -Url $pipelinesUri -Method Get -ErrorAction Stop).value
$pipelineRuns = [System.Collections.Generic.List[object]]::new()

foreach ($pipelineName in $PipelineNames)
{
    $displayName = "M365DSC $pipelineName"
    $pipeline = @($pipelines | Where-Object name -EQ $displayName)
    if ($pipeline.Count -ne 1)
    {
        throw "Expected exactly one Azure DevOps pipeline named '$displayName'; found $($pipeline.Count)."
    }

    $pipelineRuns.Add([ordered]@{
        Name       = $displayName
        PipelineId = $pipeline[0].id
        State      = 'not-queued'
        Result     = $null
        RunId      = $null
        RunUri     = $null
        Error      = $null
        MonitorFailures = 0
        MonitorError    = $null
        LastKnownState  = $null
    })
}

$runRequest = @{
    resources = @{
        repositories = @{
            self = @{
                refName = $branchRef
            }
        }
    }
} | ConvertTo-Json -Depth 10 -Compress

foreach ($pipelineRun in $pipelineRuns)
{
    if ($pipelineRun.Name -eq 'M365DSC deltaReport' -and 'export' -in $PipelineNames)
    {
        continue
    }

    $runsUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines/$($pipelineRun.PipelineId)/runs?api-version=7.1"
    try
    {
        $run = Invoke-VSTeamRequest -Url $runsUri -Method Post -ContentType 'application/json' -Body $runRequest -ErrorAction Stop
        if (-not $run.id)
        {
            throw 'Azure DevOps did not return a run ID.'
        }

        $pipelineRun.RunId = $run.id
        $pipelineRun.State = $run.state
        $pipelineRun.Result = $run.result
        $pipelineRun.RunUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines/$($pipelineRun.PipelineId)/runs/$($run.id)?api-version=7.1"
        Write-Host "Queued $($pipelineRun.Name) as run $($run.id)." -ForegroundColor Cyan
    }
    catch
    {
        $pipelineRun.State = 'queue-unconfirmed'
        $pipelineRun.Error = "Azure DevOps did not confirm whether a run was queued. Verify the pipeline run list before retrying. $($_.Exception.Message)"
    }
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$terminalStates = 'completed', 'queue-unconfirmed', 'skipped', 'monitoring-unavailable', 'monitoring-timed-out'
$deferredDeltaReport = $pipelineRuns | Where-Object { $_.Name -eq 'M365DSC deltaReport' -and $_.State -eq 'not-queued' } | Select-Object -First 1
$exportRun = $pipelineRuns | Where-Object { $_.Name -eq 'M365DSC export' } | Select-Object -First 1
if ($deferredDeltaReport)
{
    Write-Host 'M365DSC deltaReport is pending; it will be queued after M365DSC export succeeds.' -ForegroundColor Yellow
}

$totalRuns = $pipelineRuns.Count
$lastProgressSnapshot = $null
while (@($pipelineRuns | Where-Object { $_.State -notin $terminalStates }).Count -gt 0)
{
    foreach ($pipelineRun in $pipelineRuns | Where-Object { $_.State -ne 'not-queued' -and $_.State -notin $terminalStates })
    {
        if ((Get-Date) -ge $deadline)
        {
            $pipelineRun.LastKnownState = $pipelineRun.State
            $pipelineRun.State = 'monitoring-timed-out'
            $pipelineRun.Error = "Stopped polling after $TimeoutMinutes minutes. The last known Azure DevOps state was '$($pipelineRun.LastKnownState)'; the run may still be active."
            continue
        }

        try
        {
            $run = Invoke-VSTeamRequest -Url $pipelineRun.RunUri -Method Get -ErrorAction Stop
            $pipelineRun.State = $run.state
            $pipelineRun.Result = $run.result
            $pipelineRun.MonitorFailures = 0
            $pipelineRun.MonitorError = $null
        }
        catch
        {
            $pipelineRun.MonitorFailures++
            $pipelineRun.MonitorError = $_.Exception.Message
            $isTransientMonitorError = $_.Exception.ToString() -match '(?i)(?:\b408\b|\b429\b|\b5\d{2}\b|timed?\s*out|timeout|service unavailable|temporarily unavailable|too many requests|unable to connect|connection.*(?:reset|closed|refused|aborted)|(?:host|name) could not be resolved|no such host|name resolution|network is unreachable)'

            if ($isTransientMonitorError)
            {
                Write-Warning "Could not refresh $($pipelineRun.Name) status (poll retry $($pipelineRun.MonitorFailures)); keeping its last known state '$($pipelineRun.State)' and retrying after $PollIntervalSeconds second(s): $($pipelineRun.MonitorError)"
            }
            else
            {
                $pipelineRun.LastKnownState = $pipelineRun.State
                $pipelineRun.State = 'monitoring-unavailable'
                $pipelineRun.Error = "Could not retrieve the current Azure DevOps status. Last known state: '$($pipelineRun.LastKnownState)'. This does not mean the pipeline failed. $($pipelineRun.MonitorError)"
            }
        }
    }

    if ($deferredDeltaReport -and $exportRun.State -in $terminalStates)
    {
        if ($exportRun.State -eq 'completed' -and $exportRun.Result -eq 'succeeded')
        {
            $runsUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines/$($deferredDeltaReport.PipelineId)/runs?api-version=7.1"
            try
            {
                $run = Invoke-VSTeamRequest -Url $runsUri -Method Post -ContentType 'application/json' -Body $runRequest -ErrorAction Stop
                if (-not $run.id)
                {
                    throw 'Azure DevOps did not return a run ID.'
                }

                $deferredDeltaReport.RunId = $run.id
                $deferredDeltaReport.State = $run.state
                $deferredDeltaReport.Result = $run.result
                $deferredDeltaReport.RunUri = "https://dev.azure.com/$organizationName/$projectPath/_apis/pipelines/$($deferredDeltaReport.PipelineId)/runs/$($run.id)?api-version=7.1"
                Write-Host "Queued $($deferredDeltaReport.Name) as run $($run.id), after export succeeded." -ForegroundColor Cyan
            }
            catch
            {
                $deferredDeltaReport.State = 'queue-unconfirmed'
                $deferredDeltaReport.Error = "Azure DevOps did not confirm whether a run was queued. Verify the pipeline run list before retrying. $($_.Exception.Message)"
            }
        }
        else
        {
            $deferredDeltaReport.State = 'skipped'
            $deferredDeltaReport.Error = "Not queued because M365DSC export was not confirmed successful (state: $($exportRun.State), result: $($exportRun.Result))."
        }

        $deferredDeltaReport = $null
    }

    $completedRuns = @($pipelineRuns | Where-Object { $_.State -eq 'completed' }).Count
    $activeRuns = @($pipelineRuns | Where-Object { $_.State -notin $terminalStates })
    if ($activeRuns.Count -gt 0)
    {
        $progressLines = foreach ($pipelineRun in $pipelineRuns)
        {
            $pipelineStatus = if ($pipelineRun.State -eq 'completed')
            {
                $pipelineRun.Result
            }
            elseif ($pipelineRun.State -eq 'queue-unconfirmed')
            {
                'queue unconfirmed'
            }
            elseif ($pipelineRun.State -eq 'skipped')
            {
                'skipped'
            }
            elseif ($pipelineRun.State -eq 'monitoring-unavailable')
            {
                "monitoring unavailable (last known: $($pipelineRun.LastKnownState))"
            }
            elseif ($pipelineRun.State -eq 'monitoring-timed-out')
            {
                "monitoring timed out (last known: $($pipelineRun.LastKnownState))"
            }
            elseif ($pipelineRun.State -eq 'not-queued')
            {
                'pending'
            }
            elseif ($pipelineRun.State -eq 'inProgress')
            {
                'running'
            }
            elseif ($pipelineRun.State -eq 'notStarted')
            {
                'queued'
            }
            else
            {
                $pipelineRun.State
            }
            if ($pipelineRun.MonitorFailures -gt 0)
            {
                $pipelineStatus = "$pipelineStatus (poll retry $($pipelineRun.MonitorFailures))"
            }
            "$($pipelineRun.Name -replace '^M365DSC ', ''):$pipelineStatus"
        }
        $progressSnapshot = "$completedRuns/$totalRuns`n" + ($progressLines -join "`n")

        if ($progressSnapshot -ne $lastProgressSnapshot)
        {
            Write-Host "`nPipelines [$completedRuns/$totalRuns completed]" -ForegroundColor Cyan
            foreach ($progressLine in $progressLines)
            {
                Write-Host "  $progressLine"
            }
            $lastProgressSnapshot = $progressSnapshot
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

$failedRuns = @($pipelineRuns | Where-Object {
    $_.State -ne 'completed' -or $_.Result -ne 'succeeded'
})
$nameWidth = ($pipelineRuns | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$rowFormat = '{0,-' + $nameWidth + '}  {1,-16} {2,-10} {3}'
Write-Host ''
Write-Host ($rowFormat -f 'Pipeline', 'Status', 'Run ID', 'Details') -ForegroundColor White
Write-Host ('-' * ($nameWidth + 46)) -ForegroundColor DarkGray
foreach ($pipelineRun in $pipelineRuns)
{
    if ($pipelineRun.State -eq 'completed' -and $pipelineRun.Result -eq 'succeeded')
    {
        $status = 'Succeeded'
        $details = $pipelineRun.Result
        $color = 'Green'
    }
    elseif ($pipelineRun.State -eq 'completed')
    {
        $status = 'Failed'
        $details = $pipelineRun.Result
        $color = 'Red'
    }
    else
    {
        $status = switch ($pipelineRun.State)
        {
            'queue-unconfirmed' { 'Queue unconfirmed' }
            'skipped' { 'Skipped' }
            'monitoring-unavailable' { 'Monitoring unavailable' }
            'monitoring-timed-out' { 'Monitoring timed out' }
            default { $pipelineRun.State }
        }
        $details = $pipelineRun.Error
        $color = 'Red'
    }

    Write-Host ($rowFormat -f $pipelineRun.Name, $status, $pipelineRun.RunId, $details) -ForegroundColor $color
}

if ($failedRuns.Count -gt 0)
{
    throw "Could not confirm success for $($failedRuns.Count) of $totalRuns requested pipeline(s). See the summary above."
}

Write-Host "`nAll $totalRuns pipeline runs succeeded." -ForegroundColor Green
