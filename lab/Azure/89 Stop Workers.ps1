[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
$requiredModuleVersions = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')
$existingModulePaths = $env:PSModulePath -split [System.IO.Path]::PathSeparator |
    Where-Object { $_ -and $_ -ne $requiredModulesPath }
$env:PSModulePath = (@($requiredModulesPath) + $existingModulePaths) -join [System.IO.Path]::PathSeparator

$loadedAzModules = @(Get-Module -Name 'Az.*')
if ($loadedAzModules.Count -gt 0)
{
    $loadedModuleNames = $loadedAzModules | ForEach-Object { "$($_.Name) $($_.Version)" }
    throw "This script requires a fresh PowerShell session. Close and reopen PowerShell, then rerun it. Already-loaded Az modules: $($loadedModuleNames -join ', ')."
}

try
{
    Import-Module -Name Az.Accounts -RequiredVersion $requiredModuleVersions['Az.Accounts'] -ErrorAction Stop
    Import-Module -Name Az.Compute -RequiredVersion $requiredModuleVersions['Az.Compute'] -ErrorAction Stop
    Import-Module -Name Az.Resources -RequiredVersion $requiredModuleVersions['Az.Resources'] -ErrorAction Stop
}
catch
{
    throw "Failed to load the pinned Azure PowerShell modules. If an Az assembly is already loaded, close and reopen the PowerShell terminal before rerunning. $($_.Exception.Message)"
}

if ($EnvironmentName)
{
    Write-Host "Filtering environments to: $($EnvironmentName -join ', ')" -ForegroundColor Magenta
}

Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force
$projectSettings = Get-Content $PSScriptRoot\..\..\source\Global\ProjectSettings.yml | ConvertFrom-Yaml -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml

foreach ($envName in $datum.Global.Azure.Environments.Keys)
{
    if ($EnvironmentName -and $envName -notin $EnvironmentName)
    {
        Write-Host "Skipping environment '$envName'" -ForegroundColor Yellow
        continue
    }

    $environment = $datum.Global.Azure.Environments.$envName
    $setupIdentity = $environment.Identities | Where-Object Name -EQ M365DscSetupApplication
    Write-Host "Connecting to environment '$envName'" -ForegroundColor Magenta

    $param = @{
        TenantId               = $environment.AzTenantId
        TenantName             = $environment.AzTenantName
        SubscriptionId         = $environment.AzSubscriptionId
        ServicePrincipalId     = $setupIdentity.ApplicationId
        ServicePrincipalSecret = $setupIdentity.ApplicationSecret | ConvertTo-SecureString -AsPlainText -Force
    }

    # 'HasExchangeOnline' is maintained by the user and controls whether Exchange Online is expected.
    $param.SkipExchangeOnline = $environment.HasExchangeOnline -eq $false

    Connect-M365Dsc @param -ErrorAction Stop
    Set-AzContext -TenantId $environment.AzTenantId -SubscriptionId $environment.AzSubscriptionId -ErrorAction Stop | Out-Null

    $vmName = Get-M365DscAgentVmName -ProjectName $projectSettings.ProjectName -EnvironmentName $envName
    $vm = Get-M365DscAgentVm -ProjectName $projectSettings.ProjectName -EnvironmentName $envName
    if ($null -eq $vm)
    {
        throw "Expected one VM named '$vmName' in subscription '$($environment.AzSubscriptionId)', but none was found."
    }

    Write-Host "Stopping VM '$vmName' in resource group '$($vm.ResourceGroupName)' for environment '$envName'." -ForegroundColor Magenta
    if ($vm.PowerState -eq 'VM running')
    {
        Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vmName -Force -ErrorAction Stop | Out-Null
    }
    else
    {
        Write-Host "VM '$vmName' is already stopped."
    }
}
