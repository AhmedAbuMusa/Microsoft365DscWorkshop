[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

$currentIdentity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentIdentity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    throw 'This script provisions AutomatedLab VMs and must run from an elevated PowerShell process. Close this session, open PowerShell as Administrator, and rerun it.'
}

$productKeysPath = Join-Path -Path $env:ProgramData -ChildPath 'AutomatedLab\Assets\ProductKeys.xml'
$productKeysStream = $null
try
{
    $productKeysStream = [System.IO.File]::OpenRead($productKeysPath)
}
catch
{
    throw "AutomatedLab cannot read its asset file '$productKeysPath'. Run this script as Administrator and verify that the file exists and is readable. $($_.Exception.Message)"
}
finally
{
    if ($productKeysStream)
    {
        $productKeysStream.Dispose()
    }
}

$requiredModulesPath = (Resolve-Path -Path $PSScriptRoot\..\..\output\RequiredModules).Path
$requiredModuleVersions = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + ";$requiredModulesPath"
}

$loadedAzAccounts = Get-Module -Name Az.Accounts | Sort-Object -Property Version | Select-Object -Last 1
# AutomatedLab's Az.Storage requires Az.Accounts 5.5.2 or newer; lab\AutomatedLab\00 Prep.ps1 installs 5.5.3.
$requiredAzAccountsVersion = [version]'5.5.3'
if ($loadedAzAccounts -and $loadedAzAccounts.Version -ne $requiredAzAccountsVersion)
{
    throw "Az.Accounts version '$($loadedAzAccounts.Version)' is already loaded, but AutomatedLab requires version '$requiredAzAccountsVersion' for its Azure modules. PowerShell cannot unload the loaded Azure assemblies; close this PowerShell process and rerun the script in a fresh one."
}

if (-not $loadedAzAccounts)
{
    $assemblyLoading = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Azure.PowerShell.AssemblyLoading' } |
        Select-Object -First 1
    if ($assemblyLoading)
    {
        throw "The Azure assembly '$($assemblyLoading.FullName)' is already loaded, but Az.Accounts is not loaded in this PowerShell session. PowerShell cannot unload it; close this process and rerun the script in a fresh one."
    }
}

try
{
    if (-not $loadedAzAccounts)
    {
        Import-Module -Name Az.Accounts -RequiredVersion $requiredAzAccountsVersion -ErrorAction Stop
    }
    Import-Module -Name Az.Compute -RequiredVersion $requiredModuleVersions['Az.Compute'] -ErrorAction Stop
    Import-Module -Name Az.Resources -RequiredVersion $requiredModuleVersions['Az.Resources'] -ErrorAction Stop
    Import-Module -Name Az.ManagedServiceIdentity -RequiredVersion $requiredModuleVersions['Az.ManagedServiceIdentity'] -ErrorAction Stop
}
catch
{
    throw "Failed to load the Azure PowerShell modules required by AutomatedLab. This script requires Az.Accounts $requiredAzAccountsVersion; close this PowerShell process and rerun in a fresh one if a conflicting Azure assembly is already loaded. $($_.Exception.Message)"
}

Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force

# AutomatedLabTest 5.61.4 fails the discovery of its own tests under Pester 6, which makes 'Install-Lab' report a false deployment failure.
if (-not (Get-Module -Name Pester -ListAvailable | Where-Object Version -EQ 5.7.1))
{
    Write-Error "Pester 5.7.1 is not installed. Please run 'lab\AutomatedLab\00 Prep.ps1' first." -ErrorAction Stop
}
Import-Module -Name Pester -RequiredVersion 5.7.1

$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$environments = $datum.Global.Azure.Environments.Keys

if ($datum.Global.ProjectSettings.BuildAgents.Password -eq '<Password>' -or $null -eq $datum.Global.BuildAgents.Password)
{
    $defaultPassword = 'Somepass1'
    $password = Read-Host -Prompt 'Enter the password for the build agents or press <Enter> to use the default password (Somepass1)'

    if ($password -eq '')
    {
        $datum.Global.ProjectSettings.BuildAgents.Password = $defaultPassword
    }
    else
    {
        $datum.Global.ProjectSettings.BuildAgents.Password = $password
    }
    if ($datum.Global.ProjectSettings.PersonalAccessToken -ne '<PersonalAccessToken>')
    {
        $pass = $datum.__Definition.DatumHandlers.'Datum.ProtectedData::ProtectedDatum'.CommandOptions.PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force
        $datum.Global.ProjectSettings.PersonalAccessToken = $datum.Global.ProjectSettings.PersonalAccessToken | Protect-Datum -Password $pass -MaxLineLength 9999
    }
    $datum.Global.ProjectSettings | ConvertTo-Yaml | Out-File $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
}

if ((git status -s) -like '*source/Global/ProjectSettings.yml')
{
    git add $PSScriptRoot\..\..\source\Global\ProjectSettings.yml
    git commit -m 'Updated Azure DevOps Build Agent Data' | Out-Null
    git push | Out-Null
}

if ($EnvironmentName)
{
    Write-Host "Filtering environments to: $($EnvironmentName -join ', ')" -ForegroundColor Magenta
    $environments = $environments | Where-Object { $EnvironmentName -contains $_ }
}
Write-Host "Setting up environments: $($environments -join ', ')" -ForegroundColor Magenta

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
    $notes = @{
        Environment = [string]$envName
    }

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
    Write-Host "Successfully connected to Azure environment '$envName'."

    $projectName = $datum.Global.ProjectSettings.ProjectName
    $vmName = Get-M365DscAgentVmName -ProjectName $projectName -EnvironmentName $envName
    $resourceGroupName = Get-M365DscAgentResourceGroupName -ProjectName $projectName -EnvironmentName $envName
    $existingVm = Get-M365DscAgentVm -ProjectName $projectName -EnvironmentName $envName
    if ($null -ne $existingVm)
    {
        if ($existingVm.ResourceGroupName -ne $resourceGroupName)
        {
            Write-Warning "Adopting existing VM '$vmName' in resource group '$($existingVm.ResourceGroupName)'; existing resources are not moved to '$resourceGroupName'."
        }
        else
        {
            Write-Host "VM '$vmName' already exists in canonical resource group '$resourceGroupName'; skipping VM creation."
        }
        continue
    }

    $existingResourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    $hasAutomatedLabResourceGroupTag = $existingResourceGroup -and
        $existingResourceGroup.Tags.AutomatedLab -eq "$projectName$envName"
    $hasExpectedWorkerResourceGroupTags = $existingResourceGroup -and
        $existingResourceGroup.Tags.Project -eq $projectName -and
        $existingResourceGroup.Tags.Environment -eq [string]$envName -and
        $existingResourceGroup.Tags.ManagedBy -in 'AutomatedLab', 'Bicep'
    if ($existingResourceGroup -and -not ($hasAutomatedLabResourceGroupTag -or $hasExpectedWorkerResourceGroupTags))
    {
        throw "Resource group '$resourceGroupName' already exists without matching worker ownership tags; refusing to deploy into it."
    }
    if ($existingResourceGroup -and $existingResourceGroup.Tags.ManagedBy -eq 'Bicep')
    {
        throw "Resource group '$resourceGroupName' is Bicep-managed but contains no VM named '$vmName'; refusing to deploy an AutomatedLab VM into it."
    }

    Write-Host "Creating lab for environment '$envName' in the subscription."
    New-LabDefinition -Name "$projectName$envName" -DefaultVirtualizationEngine Azure -Notes $notes

    Add-LabAzureSubscription `
        -SubscriptionId $environment.AzSubscriptionId `
        -DefaultLocationName $datum.Global.ProjectSettings.BuildAgents.AzureLocation `
        -DefaultResourceGroupName $resourceGroupName

    Sync-LabAzureLabSources

    Set-LabInstallationCredential -Username $datum.Global.ProjectSettings.BuildAgents.UserName -Password $datum.Global.ProjectSettings.BuildAgents.Password

    $PSDefaultParameterValues = @{
        'Add-LabMachineDefinition:ToolsPath'       = "$labSources\Tools"
        'Add-LabMachineDefinition:OperatingSystem' = 'Windows Server 2022 Datacenter (Desktop Experience)'
    }

    Add-LabDiskDefinition -Name "$($vmName)Data1" -DiskSizeInGb 250 -Label Data

    Add-LabMachineDefinition -Name $vmName -AzureRoleSize $datum.Global.ProjectSettings.BuildAgents.AzureRoleSize -DiskName "$($vmName)Data1"

    Install-Lab

    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction Stop
    $resourceGroupTags = @{}
    if ($resourceGroup.Tags)
    {
        foreach ($tagName in $resourceGroup.Tags.Keys)
        {
            $resourceGroupTags[$tagName] = $resourceGroup.Tags[$tagName]
        }
    }
    $resourceGroupTags.Project = $projectName
    $resourceGroupTags.Environment = [string]$envName
    $resourceGroupTags.ManagedBy = 'AutomatedLab'
    Set-AzResourceGroup -Name $resourceGroupName -Tag $resourceGroupTags -ErrorAction Stop | Out-Null

    Write-Host "Finished creating lab for environment '$envName'."

    Checkpoint-LabVM -All -SnapshotName AfterInstall

    Write-Host "Created snapshot 'AfterInstall' for lab '$($datum.Global.ProjectSettings.ProjectName)$($envName)'."

}

Write-Host "Finished creating all labs VMs for the project '$($datum.Global.ProjectSettings.ProjectName)'" -ForegroundColor Green

# ------------------------------------------------------------------------------------------------------------

Write-Host 'Starting to assign managed identity to VMs and set permissions for Microsoft365DSC workloads' -ForegroundColor Green
$labs = Get-Lab -List | Where-Object { $_ -Like "$($datum.Global.ProjectSettings.ProjectName)*" }
foreach ($lab in $labs)
{
    $lab -match "(?:$($datum.Global.ProjectSettings.ProjectName))(?<Environment>\w+)" | Out-Null
    $envName = $Matches.Environment
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
    Write-Host "Successfully connected to Azure environment '$envName'."

    $lab = Import-Lab -Name $lab -NoValidation -PassThru
    $resourceGroupName = $lab.AzureSettings.DefaultResourceGroup.ResourceGroupName
    $projectName = $datum.Global.ProjectSettings.ProjectName
    $vmName = Get-M365DscAgentVmName -ProjectName $projectName -EnvironmentName $envName
    $identityName = Get-M365DscAgentIdentityName -ProjectName $projectName -EnvironmentName $envName
    $selectedVm = Get-M365DscAgentVm -ProjectName $projectName -EnvironmentName $envName
    if ($null -eq $selectedVm -or $selectedVm.ResourceGroupName -ne $resourceGroupName)
    {
        Write-Warning "Skipping AutomatedLab '$($lab.Name)' because it is not the selected VM for environment '$envName'."
        continue
    }
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction Stop
    if ($resourceGroup.Tags.ManagedBy -ne 'AutomatedLab' -and $resourceGroup.Tags.AutomatedLab -ne $lab.Name)
    {
        Write-Warning "Skipping AutomatedLab '$($lab.Name)' because resource group '$resourceGroupName' is not AutomatedLab-managed."
        continue
    }

    Write-Host "Working in lab '$($lab.Name)' with environment '$envName'"

    if (-not ($id = Get-AzUserAssignedIdentity -Name $identityName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue))
    {
        Write-Host "Managed identity '$identityName' was not found; creating it."
        $id = New-AzUserAssignedIdentity -Name $identityName -ResourceGroupName $resourceGroupName -Location $lab.AzureSettings.DefaultLocation.Location -ErrorAction Stop
    }

    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop
    if ($vm.Identity.UserAssignedIdentities.Keys -eq $id.Id)
    {
        Write-Host "Managed identity '$identityName' is already assigned to VM '$vmName' in environment '$envName'."
    }
    else
    {
        Write-Host "Assigning managed identity '$identityName' to VM '$vmName' in environment '$envName'."
        Update-AzVM -ResourceGroupName $resourceGroupName -VM $vm -IdentityType UserAssigned -IdentityId $id.Id -ErrorAction Stop | Out-Null
    }

    # The build agent identity is an Azure user-assigned managed identity, so it has a service principal but no application registration.
    $azIdentity = New-M365DscIdentity -Name $identityName -OnlyServicePrincipals -PassThru
    Write-Host "Setting permissions for managed identity '$identityName' in environment '$envName'"
    Add-M365DscIdentityPermission -Identity $azIdentity -AccessType Update

    $vm = Get-LabVM

    Invoke-LabCommand -ComputerName $vm -ScriptBlock {
        Set-Item -Path WSMan:\localhost\MaxEnvelopeSizekb -Value 8192
    } -ActivityName 'Setting WSMan MaxEnvelopeSizekb to 8192 for VMs in environment'
}

Write-Host 'Finished assigning managed identity to VMs and setting permissions for Microsoft365DSC workloads' -ForegroundColor Green

Write-Host 'All done.'
