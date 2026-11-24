[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$EncodedArguments,
    [Parameter(Mandatory)][string]$LogPath
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\BootstrapLogging.psm1" -ErrorAction Stop
$arguments = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedArguments)) |
    ConvertFrom-Json -AsHashtable -ErrorAction Stop
try
{
    & $ScriptPath @arguments *>&1 | Write-M365DscBootstrapOutput -LogPath $LogPath
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
catch
{
    $_ | Write-M365DscBootstrapOutput -LogPath $LogPath
    exit 1
}
