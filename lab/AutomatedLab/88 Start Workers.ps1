[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$azureScript = Join-Path -Path $PSScriptRoot -ChildPath '..\Azure\88 Start Workers.ps1'
& $azureScript @PSBoundParameters
