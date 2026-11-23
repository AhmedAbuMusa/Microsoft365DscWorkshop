[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')][string]$EnvironmentName,
    [int[]]$TrustedPipelineId,
    [switch]$IncludeLcmCertificate,
    $Datum
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Store.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot\PipelineSecrets.psm1" -Force -ErrorAction Stop
if (-not $Datum)
{
    Import-Module Datum -ErrorAction Stop
    $Datum = New-DatumStructure -DefinitionFile "$PSScriptRoot\..\..\..\source\Datum.yml"
}
Publish-M365DscKdbxPipelineSecrets -Datum $Datum -EnvironmentName $EnvironmentName `
    -TrustedPipelineId $TrustedPipelineId -IncludeLcmCertificate:$IncludeLcmCertificate
