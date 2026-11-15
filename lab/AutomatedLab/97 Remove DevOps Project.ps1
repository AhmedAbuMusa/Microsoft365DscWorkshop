[CmdletBinding()]
param ()

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

Write-Host 'Finished DevOps project cleanup.'
