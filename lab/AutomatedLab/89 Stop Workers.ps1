[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + ";$requiredModulesPath"
}

if ($EnvironmentName)
{
    Write-Host "Filtering environments to: $($EnvironmentName -join ', ')" -ForegroundColor Magenta
}

Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force
$projectSettings = Get-Content $PSScriptRoot\..\..\source\Global\ProjectSettings.yml | ConvertFrom-Yaml -ErrorAction Stop
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$selectedEnvironmentNames = @($datum.Global.Azure.Environments.Keys | Where-Object {
        -not $EnvironmentName -or $_ -in $EnvironmentName
    })
Update-M365DscDatumFromKeyVault `
    -Datum $datum `
    -ProjectName $projectSettings.ProjectName `
    -EnvironmentName $selectedEnvironmentNames | Out-Null

foreach ($envName in $datum.Global.Azure.Environments.Keys)
{
    if ($EnvironmentName -and $envName -notin $EnvironmentName)
    {
        Write-Host "Skipping environment '$envName'" -ForegroundColor Yellow
        continue
    }

    $environment = $datum.Global.Azure.Environments.$envName
    Write-Host "Connecting to environment '$envName'" -ForegroundColor Magenta

    $param = @{
        TenantId       = $environment.AzTenantId
        TenantName     = $environment.AzTenantName
        SubscriptionId = $environment.AzSubscriptionId
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
