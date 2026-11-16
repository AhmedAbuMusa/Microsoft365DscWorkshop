[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$defaultModulePaths = @(
    if ($PSVersionTable.PSEdition -eq 'Core')
    {
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'PowerShell\Modules'
        Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules'
    }
    else
    {
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WindowsPowerShell\Modules'
    }
    Join-Path -Path $PSHOME -ChildPath 'Modules'
    Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'
    Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\Modules'
)
$currentModulePaths = $env:PSModulePath -split [System.IO.Path]::PathSeparator | Where-Object { $_ }
$env:PSModulePath = (@($defaultModulePaths) + $currentModulePaths | Select-Object -Unique) -join [System.IO.Path]::PathSeparator

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
$requiredModuleVersions = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + ";$requiredModulesPath"
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

Import-Module -Name Microsoft.Graph.Identity.Governance -RequiredVersion '2.41.1' -ErrorAction Stop
Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml

foreach ($envName in $datum.Global.Azure.Environments.Keys)
{
    $environment = $datum.Global.Azure.Environments.$envName

    if ($EnvironmentName -and $envName -notin $EnvironmentName)
    {
        Write-Host "Skipping environment '$envName'." -ForegroundColor Yellow
        continue
    }

    $setupIdentity = $environment.Identities | Where-Object Name -EQ M365DscSetupApplication
    Write-Host "Testing connection to environment '$envName'" -ForegroundColor Magenta

    $param = @{
        TenantId               = $environment.AzTenantId
        TenantName             = $environment.AzTenantName
        SubscriptionId         = $environment.AzSubscriptionId
        ServicePrincipalId     = $setupIdentity.ApplicationId
        ServicePrincipalSecret = $setupIdentity.ApplicationSecret | ConvertTo-SecureString -AsPlainText -Force
    }

    # 'HasExchangeOnline' is maintained by the user and controls whether Exchange Online is expected.
    $skipExchangeOnline = $environment.HasExchangeOnline -eq $false
    $param.SkipExchangeOnline = $skipExchangeOnline

    Connect-M365Dsc @param -ErrorAction Stop

    Test-M365DscConnection -TenantId $environment.AzTenantId -SubscriptionId $environment.AzSubscriptionId -SkipExchangeOnline:$skipExchangeOnline -ErrorAction Stop

    $identityName = Get-M365DscAgentIdentityName -ProjectName $datum.Global.ProjectSettings.ProjectName -EnvironmentName $envName
    $identity = Get-M365DscIdentity -Name $identityName
    if ($null -ne $identity)
    {
        Remove-M365DscIdentityPermission -Identity $identity -SkipGraphApiPermissions
        Remove-M365DscIdentity -Name $identity.DisplayName
        Write-Host "Successfully removed identity '$($identity.DisplayName)' for environment '$envName'."
    }
    else
    {
        Write-Host "Identity '$identityName' does not exist."
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
    Write-Host "Successfully connected to Azure environment '$envName'."

    $projectName = $datum.Global.ProjectSettings.ProjectName
    $vmName = Get-M365DscAgentVmName -ProjectName $projectName -EnvironmentName $envName
    $vm = Get-M365DscAgentVm -ProjectName $projectName -EnvironmentName $envName
    if ($null -eq $vm)
    {
        Write-Host "VM '$vmName' was not found; no Azure VM resources were removed."
        continue
    }

    $resourceGroup = Get-AzResourceGroup -Name $vm.ResourceGroupName -ErrorAction Stop
    $isBicepResourceGroup = $resourceGroup.Tags.ManagedBy -eq 'Bicep' `
        -and $resourceGroup.Tags.Project -eq $projectName `
        -and $resourceGroup.Tags.Environment -eq [string]$envName
    $isAutomatedLabResourceGroup = (
        $resourceGroup.Tags.ManagedBy -eq 'AutomatedLab' `
            -and $resourceGroup.Tags.Project -eq $projectName `
            -and $resourceGroup.Tags.Environment -eq [string]$envName
    ) -or $resourceGroup.Tags.AutomatedLab -eq "$projectName$envName"

    if ($isAutomatedLabResourceGroup)
    {
        Write-Host "Removing AutomatedLab-managed resource group '$($vm.ResourceGroupName)' for environment '$envName'."
        Remove-AzResourceGroup -Name $vm.ResourceGroupName -Force -ErrorAction Stop | Out-Null
        continue
    }

    if ($isBicepResourceGroup)
    {
        $groupResources = @(Get-AzResource -ResourceGroupName $vm.ResourceGroupName -ErrorAction Stop)
        $unmanagedResources = @($groupResources | Where-Object {
            $_.Tags.ManagedBy -ne 'Bicep' `
                -or $_.Tags.Project -ne $datum.Global.ProjectSettings.ProjectName `
                -or $_.Tags.Environment -ne [string]$envName
        })
        if ($unmanagedResources.Count -eq 0)
        {
            Write-Host "Removing Bicep-managed resource group '$($vm.ResourceGroupName)' for environment '$envName'."
            Remove-AzResourceGroup -Name $vm.ResourceGroupName -Force -ErrorAction Stop | Out-Null
            continue
        }

        Write-Warning "Resource group '$($vm.ResourceGroupName)' contains resources without matching Bicep ownership tags. Removing only VM '$vmName' and its attached disks and network interfaces."
    }

    $diskIds = @(
        $vm.StorageProfile.OsDisk.ManagedDisk.Id
        $vm.StorageProfile.DataDisks | ForEach-Object { $_.ManagedDisk.Id }
    ) | Where-Object { $_ }
    $networkInterfaceIds = @($vm.NetworkProfile.NetworkInterfaces | ForEach-Object Id)
    $publicIpIds = @(
        foreach ($networkInterfaceId in $networkInterfaceIds)
        {
            $networkInterface = Get-AzResource -ResourceId $networkInterfaceId -ExpandProperties -ErrorAction Stop
            $networkInterface.Properties.ipConfigurations |
                ForEach-Object { $_.properties.publicIPAddress.id }
        }
    ) | Where-Object { $_ }
    $snapshotPrefix = $vmName
    if ($snapshotPrefix.Length -gt 55)
    {
        $snapshotPrefix = $snapshotPrefix.Substring(0, 55)
    }
    Remove-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vmName -Force -ErrorAction Stop | Out-Null

    foreach ($diskId in $diskIds)
    {
        $diskIdParts = $diskId -split '/'
        $diskResourceGroupName = $diskIdParts[4]
        $diskName = $diskIdParts[-1]
        Remove-AzDisk -ResourceGroupName $diskResourceGroupName -DiskName $diskName -Force -ErrorAction Stop | Out-Null
    }
    foreach ($networkInterfaceId in $networkInterfaceIds)
    {
        Remove-AzResource -ResourceId $networkInterfaceId -Force -ErrorAction Stop | Out-Null
    }
    foreach ($publicIpId in $publicIpIds)
    {
        $publicIp = Get-AzResource -ResourceId $publicIpId -ExpandProperties -ErrorAction Stop
        if (-not $publicIp.Properties.ipConfiguration)
        {
            Remove-AzResource -ResourceId $publicIpId -Force -ErrorAction Stop | Out-Null
        }
        else
        {
            Write-Warning "Public IP '$publicIpId' is still associated with a network interface and was left in place."
        }
    }
    $snapshots = Get-AzSnapshot -ResourceGroupName $vm.ResourceGroupName -ErrorAction Stop |
        Where-Object Name -Like "$snapshotPrefix-AfterInstall*"
    foreach ($snapshot in $snapshots)
    {
        Remove-AzSnapshot -ResourceGroupName $vm.ResourceGroupName -SnapshotName $snapshot.Name -Force -ErrorAction Stop | Out-Null
    }
    Write-Host "Removed VM '$vmName' and its attached disks and network interfaces."
}

Write-Host 'Finished worker cleanup.'
