[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName,

    [Parameter()]
    [securestring]$BuildAgentPassword
)

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + ";$requiredModulesPath"
}

Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force

$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$environments = $datum.Global.Azure.Environments.Keys

if ($BuildAgentPassword)
{
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($BuildAgentPassword)
    try
    {
        $datum.Global.ProjectSettings.BuildAgents.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
}
elseif ($datum.Global.ProjectSettings.BuildAgents.Password -eq '<Password>' -or
    [string]::IsNullOrWhiteSpace([string]$datum.Global.ProjectSettings.BuildAgents.Password))
{
    $securePassword = Read-Host -Prompt 'Enter the password for the build agents' -AsSecureString
    if ($securePassword.Length -eq 0)
    {
        throw 'A non-empty build-agent password is required.'
    }

    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try
    {
        $datum.Global.ProjectSettings.BuildAgents.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
}

if ($EnvironmentName)
{
    Write-Host "Filtering environments to: $($EnvironmentName -join ', ')" -ForegroundColor Magenta
    $environments = $environments | Where-Object { $EnvironmentName -contains $_ }
}
Write-Host "Setting up environments: $($environments -join ', ')" -ForegroundColor Magenta

$vmResourceGroupNames = @{}
foreach ($envName in $environments)
{
    $environment = $datum.Global.Azure.Environments.$envName
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
}

foreach ($envName in $environments)
{
    $environment = $datum.Global.Azure.Environments.$envName
    Write-Host "Working in environment '$envName'" -ForegroundColor Magenta

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
    $identityName = Get-M365DscAgentIdentityName -ProjectName $projectName -EnvironmentName $envName
    $resourceGroupName = Get-M365DscAgentResourceGroupName -ProjectName $projectName -EnvironmentName $envName
    $location = $datum.Global.ProjectSettings.BuildAgents.AzureLocation
    $vm = Get-M365DscAgentVm -ProjectName $projectName -EnvironmentName $envName
    if ($null -ne $vm)
    {
        $resourceGroupName = $vm.ResourceGroupName
        Write-Host "Adopting existing VM '$vmName' in resource group '$resourceGroupName'."
    }
    else
    {
        $bicepCommand = Get-Command -Name bicep -ErrorAction SilentlyContinue
        if (-not $bicepCommand)
        {
            $bicepInstallPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Bicep CLI'
            $bicepExecutablePath = Join-Path -Path $bicepInstallPath -ChildPath 'bicep.exe'
            if (Test-Path -LiteralPath $bicepExecutablePath -PathType Leaf)
            {
                $env:PATH = "$bicepInstallPath;$env:PATH"
                $bicepCommand = Get-Command -Name bicep -ErrorAction SilentlyContinue
            }
        }

        if (-not $bicepCommand)
        {
            $exceptionMessage = "Bicep CLI is required to deploy new VMs. Install it with 'winget install --exact --id Microsoft.Bicep --source winget --accept-source-agreements --accept-package-agreements', then ensure its install directory is on PATH."
            Write-Host $exceptionMessage -ForegroundColor Red
            throw $exceptionMessage
        }

        Write-Host "Creating VM '$vmName' using the Bicep template."
        $resourceGroup = Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $resourceGroupName
        if (-not $resourceGroup)
        {
            New-AzResourceGroup -Name $resourceGroupName -Location $location -Tag @{
                Project     = $projectName
                Environment = [string]$envName
                ManagedBy   = 'Bicep'
            } -ErrorAction Stop | Out-Null
        }

        $deployment = New-AzResourceGroupDeployment `
            -Name "build-agent-$envName" `
            -ResourceGroupName $resourceGroupName `
            -TemplateFile $PSScriptRoot\..\templates\buildAgent.bicep `
            -TemplateParameterObject @{
                location      = $location
                vmName        = $vmName
                vmSize        = $datum.Global.ProjectSettings.BuildAgents.AzureRoleSize
                adminUsername = $datum.Global.ProjectSettings.BuildAgents.UserName
                adminPassword = $datum.Global.ProjectSettings.BuildAgents.Password
                identityName  = $identityName
                tags          = @{
                    Project     = $projectName
                    Environment = [string]$envName
                    ManagedBy   = 'Bicep'
                }
            } `
            -Tag @{
                Project     = $projectName
                Environment = [string]$envName
                ManagedBy   = 'Bicep'
            } `
            -ErrorAction Stop

        if ($deployment.ProvisioningState -ne 'Succeeded')
        {
            throw "Bicep deployment for VM '$vmName' did not succeed (state: '$($deployment.ProvisioningState)')."
        }
    }

    $vmResourceGroupNames[$envName] = $resourceGroupName
    $vmStatus = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Status -ErrorAction Stop
    $isVmRunning = @($vmStatus.Statuses | Where-Object Code -EQ 'PowerState/running').Count -gt 0
    if (-not $isVmRunning)
    {
        Start-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop | Out-Null
    }

    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop
    $snapshotPrefix = $vmName
    if ($snapshotPrefix.Length -gt 55)
    {
        $snapshotPrefix = $snapshotPrefix.Substring(0, 55)
    }
    $diskSnapshots = @(
        @{
            Name    = "$snapshotPrefix-AfterInstall"
            DiskId  = $vm.StorageProfile.OsDisk.ManagedDisk.Id
        }
    ) + @(
        $vm.StorageProfile.DataDisks | ForEach-Object {
            @{
                Name   = "$snapshotPrefix-AfterInstall-Lun$($_.Lun)"
                DiskId = $_.ManagedDisk.Id
            }
        }
    )
    $snapshotLocation = "$($vm.Location)"
    $resourceTags = @{
        Project     = "$($datum.Global.ProjectSettings.ProjectName)"
        Environment = "$envName"
        ManagedBy   = 'Bicep'
    }
    $existingSnapshotNames = @(Get-AzSnapshot -ResourceGroupName $resourceGroupName -ErrorAction Stop | Select-Object -ExpandProperty Name)
    foreach ($diskSnapshot in $diskSnapshots)
    {
        if (-not $diskSnapshot.DiskId)
        {
            throw "VM '$vmName' disk '$($diskSnapshot.Name)' has no managed disk resource ID; it cannot be checkpointed by this script."
        }
        if ($diskSnapshot.Name -in $existingSnapshotNames)
        {
            Write-Host "Disk snapshot '$($diskSnapshot.Name)' already exists."
            continue
        }

        $sourceDiskId = "$($diskSnapshot.DiskId)"
        if ([string]::IsNullOrWhiteSpace($snapshotLocation) -or [string]::IsNullOrWhiteSpace($sourceDiskId))
        {
            throw "VM '$vmName' returned an invalid location or managed disk resource ID."
        }

        $snapshotConfig = New-AzSnapshotConfig `
            -SourceResourceId $sourceDiskId `
            -Location $snapshotLocation `
            -CreateOption Copy `
            -SkuName Standard_LRS `
            -Tag $resourceTags `
            -ErrorAction Stop
        if ($null -eq $snapshotConfig)
        {
            throw "Azure did not create a snapshot configuration for disk '$($diskSnapshot.DiskId)'."
        }

        $snapshot = New-AzSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $diskSnapshot.Name -Snapshot $snapshotConfig -ErrorAction Stop
        if ($null -eq $snapshot)
        {
            throw "Azure did not return the created disk snapshot '$($diskSnapshot.Name)'."
        }
        $existingSnapshotNames += $snapshot.Name
        Write-Host "Created disk snapshot '$($diskSnapshot.Name)'."
    }

}

Write-Host "Finished creating or adopting all VMs for the project '$($datum.Global.ProjectSettings.ProjectName)'" -ForegroundColor Green

# ------------------------------------------------------------------------------------------------------------

Write-Host 'Starting to assign managed identity to VMs and set permissions for Microsoft365DSC workloads' -ForegroundColor Green
foreach ($envName in $environments)
{
    if ($EnvironmentName -and $envName -notin $EnvironmentName)
    {
        Write-Host "Skipping environment '$envName'" -ForegroundColor Yellow
        continue
    }

    $environment = $datum.Global.Azure.Environments."$envName"
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

    $vmName = Get-M365DscAgentVmName -ProjectName $datum.Global.ProjectSettings.ProjectName -EnvironmentName $envName
    $resourceGroupName = $vmResourceGroupNames[$envName]
    if (-not $resourceGroupName)
    {
        throw "No resource group was selected for environment '$envName'."
    }

    $vms = @(Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Status -ErrorAction Stop)
    if ($vms.Count -ne 1)
    {
        throw "Expected one VM named '$vmName' in resource group '$resourceGroupName', found $($vms.Count)."
    }
    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop
    Write-Host "Working with VM '$vmName' in resource group '$resourceGroupName'."

    $identityName = Get-M365DscAgentIdentityName -ProjectName $datum.Global.ProjectSettings.ProjectName -EnvironmentName $envName
    if (-not ($id = Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroupName -ErrorAction Stop | Where-Object Name -EQ $identityName))
    {
        Write-Host "Managed identity '$identityName' was not found; creating it."
        $id = New-AzUserAssignedIdentity -Name $identityName -ResourceGroupName $resourceGroupName -Location $vm.Location -ErrorAction Stop
    }

    $assignedIdentityIds = @($vm.Identity.UserAssignedIdentities.Keys)
    $identityAlreadyAssigned = @(
        $assignedIdentityIds | Where-Object {
            [string]::Equals([string]$_, [string]$id.Id, [StringComparison]::OrdinalIgnoreCase)
        }
    ).Count -gt 0
    if (-not $identityAlreadyAssigned)
    {
        Write-Host "Assigning managed identity '$identityName' to VM '$vmName'."
        $identityIds = $assignedIdentityIds + $id.Id
        $identityType = 'UserAssigned'
        if ($vm.Identity.Type -match 'SystemAssigned')
        {
            $identityType = 'SystemAssignedUserAssigned'
        }
        Update-AzVM -ResourceGroupName $resourceGroupName -VM $vm -IdentityType $identityType -IdentityId $identityIds -ErrorAction Stop | Out-Null
    }
    else
    {
        Write-Host "Managed identity '$identityName' is already assigned to VM '$vmName'."
    }

    # The build agent identity is an Azure user-assigned managed identity, so it has a service principal but no application registration.
    $azIdentity = New-M365DscIdentity -Name $identityName -OnlyServicePrincipals -PassThru
    Write-Host "Setting permissions for managed identity '$identityName' in environment '$envName'."
    Add-M365DscIdentityPermission -Identity $azIdentity -AccessType Update

    $runCommand = Invoke-AzVMRunCommand `
        -ResourceGroupName $resourceGroupName `
        -VMName $vmName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString "Set-Item -Path WSMan:\localhost\MaxEnvelopeSizekb -Value 8192" `
        -ErrorAction Stop
    if ($runCommand.Status -ne 'Succeeded')
    {
        $runCommandOutput = ($runCommand.Value | ForEach-Object Message) -join [Environment]::NewLine
        throw "Azure Run Command failed to set WSMan MaxEnvelopeSizekb on '$vmName' (status: $($runCommand.Status)). $runCommandOutput"
    }
}

Write-Host 'Finished assigning managed identity to VMs and setting permissions for Microsoft365DSC workloads' -ForegroundColor Green

Write-Host 'All done.'
