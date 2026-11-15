$ErrorActionPreference = 'Stop'

$requestedEnvironments = @($env:SELECTED_ENVIRONMENTS -split ',' | ForEach-Object { $_.Trim() })
if ($requestedEnvironments.Count -eq 0 -or @($requestedEnvironments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
{
    throw 'The environments parameter must contain a comma-separated list of environment names.'
}

if ($requestedEnvironments -contains '*')
{
    if ($requestedEnvironments.Count -ne 1)
    {
        throw 'The * wildcard cannot be combined with environment names.'
    }

    throw 'The * wildcard is not supported; select explicit environment names in the pipeline parameter.'
}

$environmentNames = [System.Collections.Generic.List[string]]::new()
$seenEnvironments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($requestedEnvironment in $requestedEnvironments)
{
    if (-not $seenEnvironments.Add($requestedEnvironment))
    {
        throw "Environment '$requestedEnvironment' is selected more than once."
    }

    $environmentNames.Add($requestedEnvironment)
}

$matrix = [ordered]@{}
for ($index = 0; $index -lt $environmentNames.Count; $index++)
{
    $matrix["Environment$index"] = @{
        BuildEnvironment = $environmentNames[$index]
    }
}

$matrixJson = ConvertTo-Json -InputObject $matrix -Compress
$escapedMatrixJson = $matrixJson.Replace('%', '%AZP25').Replace(';', '%3B').Replace(']', '%5D').Replace("`r", '%0D').Replace("`n", '%0A')
Write-Host "##vso[task.setvariable variable=buildEnvironmentMatrix;isOutput=true]$escapedMatrixJson"
