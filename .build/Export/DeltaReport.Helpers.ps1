function Convert-DeltaReportTenantIdentifiers
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$TenantIdentifierMap
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "Delta report '$Path' was not found."
    }

    $content = [System.IO.File]::ReadAllText($Path)
    foreach ($identifier in @($TenantIdentifierMap.Keys | Sort-Object { ([string]$_).Length } -Descending))
    {
        if ([string]::IsNullOrWhiteSpace([string]$identifier))
        {
            continue
        }

        $pattern = [regex]::Escape([string]$identifier)
        $map = $TenantIdentifierMap
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param ($match)
            $map[$match.Value]
        }
        $content = [regex]::Replace(
            $content,
            $pattern,
            $evaluator,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}
