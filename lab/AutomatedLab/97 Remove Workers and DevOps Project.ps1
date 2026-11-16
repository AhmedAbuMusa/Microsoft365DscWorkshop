[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + ";$requiredModulesPath"
}

$workerCleanupScript = Join-Path -Path $PSScriptRoot -ChildPath '96 Remove Workers.ps1'
& $workerCleanupScript @PSBoundParameters

Import-Module -Name VSTeam -MinimumVersion 7.15.2 -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml

Set-VSTeamAccount -Account "https://dev.azure.com/$($datum.Global.ProjectSettings.OrganizationName)/" -PersonalAccessToken $datum.Global.ProjectSettings.PersonalAccessToken -ErrorAction Stop
Write-Host "Connected to Azure DevOps organization '$($datum.Global.ProjectSettings.OrganizationName)' with PAT."

try
{
    Get-VSTeamProject -Name $datum.Global.ProjectSettings.ProjectName | Out-Null
    Remove-VSTeamProject -Name $datum.Global.ProjectSettings.ProjectName -Force -ErrorAction Stop
    Write-Host "Project '$($datum.Global.ProjectSettings.ProjectName)' has been removed."

    if ($pool = Get-VSTeamPool | Where-Object Name -EQ $datum.Global.ProjectSettings.AgentPoolName)
    {
        Remove-VSTeamPool -Id $pool.Id
        Write-Host "Agent pool '$($datum.Global.ProjectSettings.AgentPoolName)' has been removed."
    }
    else
    {
        Write-Host "Agent pool '$($datum.Global.ProjectSettings.AgentPoolName)' does not exists."
    }
}
catch
{
    Write-Host "Project '$($datum.Global.ProjectSettings.ProjectName)' does not exists."
}

Write-Host 'Finished cleanup.'
