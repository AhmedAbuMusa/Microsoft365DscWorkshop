[CmdletBinding()]
param
(
    [Parameter()]
    [switch]
    $IncludeExchangeOnlineManagement
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
$requiredModulesPath = Join-Path -Path $repositoryRoot -ChildPath 'output\RequiredModules'
$requiredModulesFile = Join-Path -Path $repositoryRoot -ChildPath 'RequiredModules.psd1'
if (-not (Test-Path -LiteralPath $requiredModulesPath))
{
    throw "Required module folder '$requiredModulesPath' does not exist. Restore dependencies before running this preflight."
}

$requiredModules = Import-PowerShellDataFile -Path $requiredModulesFile
$modulePathEntries = @($requiredModulesPath) + @(
    $env:PSModulePath -split [System.IO.Path]::PathSeparator |
        Where-Object { $_ -and $_.TrimEnd('\') -ne $requiredModulesPath.TrimEnd('\') }
)
$env:PSModulePath = $modulePathEntries -join [System.IO.Path]::PathSeparator

Write-Output "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Output "PowerShell home: $PSHOME"
Write-Output "Runtime: $([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
Write-Output "Module path: $env:PSModulePath"

if ($PSVersionTable.PSEdition -ne 'Core')
{
    throw 'Build preflight requires PowerShell Core.'
}

$minimumPowerShellVersion = [version]'7.4.0'
if ($PSVersionTable.PSVersion -lt $minimumPowerShellVersion)
{
    throw "Build preflight requires PowerShell $minimumPowerShellVersion or newer (.NET 8+); found $($PSVersionTable.PSVersion). Upgrade the self-hosted agent runtime."
}

$moduleNames = @(
    'Pester',
    'Az.Accounts',
    'Az.Resources',
    'Az.Compute',
    'Az.ManagedServiceIdentity'
)
if ($IncludeExchangeOnlineManagement)
{
    $moduleNames += 'ExchangeOnlineManagement'
}

foreach ($moduleName in $moduleNames)
{
    $requiredVersion = $requiredModules[$moduleName]
    if ($requiredVersion -is [hashtable])
    {
        $requiredVersion = $requiredVersion.Version
    }

    if (-not $requiredVersion -or $requiredVersion -eq 'latest')
    {
        throw "Module '$moduleName' must have an explicit version in '$requiredModulesFile'."
    }

    $availableModules = @(Get-Module -Name $moduleName -ListAvailable | Sort-Object -Property Version -Descending)
    $availablePaths = $availableModules | ForEach-Object { "$($_.Version): $($_.ModuleBase)" }
    Write-Output "Available '$moduleName' modules: $($availablePaths -join '; ')"

    $restoredModule = $availableModules |
        Where-Object {
            $_.Version -eq [version]$requiredVersion -and
            $_.ModuleBase.StartsWith($requiredModulesPath, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -First 1
    if (-not $restoredModule)
    {
        throw "Pinned '$moduleName' version '$requiredVersion' was not restored under '$requiredModulesPath'."
    }

    Import-Module -Name $moduleName -RequiredVersion $requiredVersion -Force -ErrorAction Stop
    $loadedModule = Get-Module -Name $moduleName |
        Where-Object Version -EQ ([version]$requiredVersion) |
        Select-Object -First 1
    if (-not $loadedModule -or
        -not $loadedModule.ModuleBase.StartsWith($requiredModulesPath, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "Pinned '$moduleName' version '$requiredVersion' did not load from '$requiredModulesPath'."
    }

    Write-Output "Loaded '$moduleName' $($loadedModule.Version) from '$($loadedModule.ModuleBase)'."

    if ($moduleName -eq 'Pester')
    {
        $null = New-PesterConfiguration
        Write-Output 'Pester configuration type initialized successfully.'
    }
}
