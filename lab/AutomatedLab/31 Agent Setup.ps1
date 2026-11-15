[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$azureScript = Join-Path -Path $PSScriptRoot -ChildPath '..\Azure\31 Agent Setup.ps1'
& $azureScript @PSBoundParameters
