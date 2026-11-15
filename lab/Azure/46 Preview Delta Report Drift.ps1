<#
    .SYNOPSIS
        Previews both delta-report drift scripts without applying tenant changes.

    .DESCRIPTION
        Runs each drift script with -WhatIf in a separate profile-free PowerShell
        process so their pinned Microsoft Graph assemblies remain isolated.
#>

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'

$powerShell = Get-Command -Name pwsh -CommandType Application -ErrorAction Stop
$driftScripts = @(
    '44 Introduce Delta Report Drift.ps1',
    '45 Introduce Remaining Delta Report Drift.ps1'
)

$failedScripts = @()
foreach ($driftScript in $driftScripts)
{
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $driftScript
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf))
    {
        throw "Required drift script was not found: '$scriptPath'."
    }

    Write-Output "Previewing '$driftScript' with -WhatIf..."
    & $powerShell.Source -NoLogo -NoProfile -File $scriptPath -WhatIf -ErrorAction Stop
    if ($LASTEXITCODE -ne 0)
    {
        $failedScripts += $driftScript
        Write-Warning "'$driftScript' preview exited with code $LASTEXITCODE."
    }
}

if ($failedScripts.Count -gt 0)
{
    throw "Preview failed for: $($failedScripts -join ', ')."
}

Write-Output 'Both drift script previews completed successfully. No tenant changes were applied.'
