[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$azureScript = Join-Path -Path $PSScriptRoot -ChildPath '..\Azure\89 Stop Workers.ps1'
& $azureScript @PSBoundParameters
