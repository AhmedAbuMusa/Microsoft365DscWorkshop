[CmdletBinding()]
param (
    [Parameter()]
    [string[]]$EnvironmentName
)

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
    Import-Module -Name Az.KeyVault -RequiredVersion $requiredModuleVersions['Az.KeyVault'] -ErrorAction Stop
    Import-Module -Name Az.ManagedServiceIdentity -RequiredVersion $requiredModuleVersions['Az.ManagedServiceIdentity'] -ErrorAction Stop
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
$datum = New-DatumStructure -DefinitionFile $PSScriptRoot\..\..\source\Datum.yml
$datum = Get-M365DscProjectConfiguration -Datum $datum
$secretBackend = Get-M365DscSecretBackend -Datum $datum
if ($secretBackend -eq 'Kdbx') { Import-Module $PSScriptRoot\..\Secrets\Kdbx\Store.psm1 -ErrorAction Stop }
$certificatesToInstall = 'M365DscLcmApplication', 'M365DscExportApplication'
$selectedEnvironments = @($datum.Global.Azure.Environments.Keys | Where-Object {
        -not $EnvironmentName -or $_ -in $EnvironmentName
    })
Update-M365DscEnvironmentMetadata `
    -Datum $datum `
    -ProjectName $datum.Global.ProjectSettings.ProjectName `
    -EnvironmentName $selectedEnvironments | Out-Null
$datum = Get-M365DscProjectSecrets -Datum $datum -CredentialType personal-access-token

foreach ($envKey in $datum.Global.Azure.Environments.Keys)
{
    if ($envKey -notin $selectedEnvironments)
    {
        continue
    }

    $environment = $datum.Global.Azure.Environments[$envKey]
    $projectName = $datum.Global.ProjectSettings.ProjectName
    if ($secretBackend -eq 'Kdbx')
    {
        Connect-M365DscEnvironmentContext -TenantName $environment.AzTenantName `
            -SubscriptionId $environment.AzSubscriptionId | Out-Null
    }
    $vm = Get-M365DscAgentVm -ProjectName $projectName -EnvironmentName $envKey -ErrorAction Stop
    if ($null -eq $vm)
    {
        throw "Environment '$envKey': the agent VM must exist before certificate and agent setup."
    }
    if ($secretBackend -eq 'Kdbx')
    {
        foreach ($role in $certificatesToInstall)
        {
            $stored = Get-M365DscStoredCertificate -EnvironmentName $envKey -IdentityName $role
            try
            {
                $identity = @($environment.Identities | Where-Object Name -EQ $role)
                if ($identity.Count -ne 1 -or $stored.Thumbprint -ne $identity[0].CertificateThumbprint)
                {
                    throw "Recovery certificate mismatch for '$envKey/$role'."
                }
            }
            finally
            {
                $stored.Password.Dispose()
                [Array]::Clear($stored.Pfx, 0, $stored.Pfx.Length)
            }
        }
        continue
    }
    Initialize-M365DscAgentKeyVaultPrivateEndpoint -Datum $datum -EnvironmentName $envKey -VM $vm -ErrorAction Stop
    Write-M365DscEnvironmentContext -EnvironmentName $envKey -TenantName $environment.AzTenantName `
        -TenantId $environment.AzTenantId -SubscriptionId $environment.AzSubscriptionId -KeyVaultName $environment.KeyVaultName `
        -Operation 'Installing application certificates'
    Connect-M365DscEnvironmentContext `
        -TenantName $environment.AzTenantName `
        -SubscriptionId $environment.AzSubscriptionId | Out-Null

    $vaultName = Resolve-M365DscKeyVaultName `
        -ProjectName $datum.Global.ProjectSettings.ProjectName `
        -EnvironmentName $envKey `
        -TenantId $environment.AzTenantId `
        -SubscriptionId $environment.AzSubscriptionId

    foreach ($certificateToInstall in $certificatesToInstall)
    {
        $identity = $environment.Identities | Where-Object Name -EQ $certificateToInstall
        $thumbprint = $identity.CertificateThumbprint
        if ([string]::IsNullOrWhiteSpace($thumbprint) -or $thumbprint -like '<*')
        {
            throw "Certificate thumbprint for '$certificateToInstall' is not configured in environment '$envKey'."
        }

        $pfxName = Get-M365DscKeyVaultSecretName -IdentityName $certificateToInstall -CredentialType pfx
        $pfxPasswordName = Get-M365DscKeyVaultSecretName -IdentityName $certificateToInstall -CredentialType pfx-password
        $pfxBase64Secure = Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $pfxName
        $pfxPasswordSecure = Get-M365DscKeyVaultSecret -VaultName $vaultName -Name $pfxPasswordName
        $pfxBase64 = [System.Net.NetworkCredential]::new('', $pfxBase64Secure).Password
        $pfxPassword = [System.Net.NetworkCredential]::new('', $pfxPasswordSecure).Password
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [Convert]::FromBase64String($pfxBase64),
            $pfxPassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        )
        try
        {
            if (-not $certificate.HasPrivateKey -or
                -not [string]::Equals($certificate.Thumbprint, $thumbprint, [StringComparison]::OrdinalIgnoreCase))
            {
                throw "The Key Vault certificate for '$certificateToInstall' does not match configured thumbprint '$thumbprint' or has no private key."
            }
        }
        finally
        {
            $certificate.Dispose()
        }
    }
}

function Invoke-WorkerVmScript
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Parameters = @{},

        [ValidateRange(60, 1800)]
        [int]$TimeoutInSeconds = 1800
    )

    $scriptText = $ScriptBlock.ToString()
    $runCommandName = "DSCLocal-$([Guid]::NewGuid().ToString('N'))"
    $runCommandParameters = @{
        ResourceGroupName = $VM.ResourceGroupName
        VMName            = $VM.Name
        RunCommandName    = $runCommandName
        Location          = $VM.Location
        SourceScript      = $scriptText
        AsyncExecution    = $true
        TimeoutInSecond   = $TimeoutInSeconds
        ErrorAction       = 'Stop'
    }
    if ($Parameters.Count -gt 0)
    {
        $runCommandParameters.ProtectedParameter = @(
            foreach ($parameter in $Parameters.GetEnumerator())
            {
                @{
                    Name  = [string]$parameter.Key
                    Value = [string]$parameter.Value
                }
            }
        )
    }

    $null = Set-AzVMRunCommand @runCommandParameters
    try
    {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timeout = [TimeSpan]::FromSeconds($TimeoutInSeconds)
        $nextStatusReport = [TimeSpan]::FromSeconds(30)
        Write-Host "Started Azure Run Command '$runCommandName' on VM '$($VM.Name)'; checking every 5 seconds."
        do
        {
            if ($stopwatch.Elapsed -gt $timeout)
            {
                throw "Azure Run Command '$runCommandName' on VM '$($VM.Name)' did not complete within $TimeoutInSeconds seconds."
            }

            Start-Sleep -Seconds 5
            $runCommand = Get-AzVMRunCommand `
                -ResourceGroupName $VM.ResourceGroupName `
                -VMName $VM.Name `
                -RunCommandName $runCommandName `
                -Expand InstanceView `
                -ErrorAction Stop
            $executionState = [string]$runCommand.InstanceView.ExecutionState
            if ($executionState -notin 'Succeeded', 'Failed', 'TimedOut', 'Canceled' -and
                $stopwatch.Elapsed -ge $nextStatusReport)
            {
                $elapsedMinutes = [int]$stopwatch.Elapsed.TotalMinutes
                $elapsedSeconds = $stopwatch.Elapsed.Seconds
                $reportedState = if ($executionState) { $executionState } else { 'not reported yet' }
                Write-Host "Azure Run Command on VM '$($VM.Name)' is still $reportedState ($elapsedMinutes min $elapsedSeconds sec elapsed)."
                $nextStatusReport = $nextStatusReport.Add([TimeSpan]::FromSeconds(30))
            }
        } while ($executionState -notin 'Succeeded', 'Failed', 'TimedOut', 'Canceled')

        $instanceView = $runCommand.InstanceView
        $output = [string]$instanceView.Output
        $errorOutput = [string]$instanceView.Error
        $exitCode = $instanceView.ExitCode
        if ($secretBackend -ne 'Kdbx')
        {
            Remove-AzVMRunCommand `
                -ResourceGroupName $VM.ResourceGroupName `
                -VMName $VM.Name `
                -RunCommandName $runCommandName `
                -ErrorAction Stop | Out-Null
        }

        if ($executionState -ne 'Succeeded' -or $exitCode -ne 0)
        {
            throw "Azure Run Command failed on VM '$($VM.Name)' (state: '$executionState', exit code: '$exitCode'). $output $errorOutput"
        }

        if ($output)
        {
            Write-Host $output.TrimEnd()
        }
    }
    finally
    {
        if ($secretBackend -eq 'Kdbx')
        {
            Remove-AzVMRunCommand -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name `
                -RunCommandName $runCommandName -ErrorAction Stop | Out-Null
        }
    }
}

# Chocolatey supplies all software on the build agents. The former agent CDN
# 'vstsagentpackage.azureedge.net' has been retired and no longer resolves, while the
# 'azure-pipelines-agent' package downloads from 'download.agent.dev.azure.com'.
$agentPackagePath = 'C:\AzurePipelinesAgent'

foreach ($envName in $datum.Global.Azure.Environments.Keys)
{
    if ($EnvironmentName -and $envName -notin $EnvironmentName)
    {
        Write-Host "Skipping environment '$envName'" -ForegroundColor Yellow
        continue
    }

    $environment = $datum.Global.Azure.Environments.$envName
    Write-M365DscEnvironmentContext -EnvironmentName $envName -TenantName $environment.AzTenantName `
        -TenantId $environment.AzTenantId -SubscriptionId $environment.AzSubscriptionId -KeyVaultName $environment.KeyVaultName `
        -Operation 'Configuring the Azure DevOps agent'

    Write-Host "Connecting to environment '$envName'" -ForegroundColor Magenta
    $param = @{
        TenantId         = $environment.AzTenantId
        TenantName       = $environment.AzTenantName
        SubscriptionId   = $environment.AzSubscriptionId
    }
    # 'HasExchangeOnline' is maintained by the user and controls whether Exchange Online is expected.
    $param.SkipExchangeOnline = $environment.HasExchangeOnline -eq $false
    Connect-M365Dsc @param -ErrorAction Stop
    Set-AzContext -TenantId $environment.AzTenantId -SubscriptionId $environment.AzSubscriptionId -ErrorAction Stop | Out-Null
    $azureContext = Get-AzContext -ErrorAction Stop
    if ($azureContext.Tenant.Id -ne $environment.AzTenantId -or $azureContext.Subscription.Id -ne $environment.AzSubscriptionId)
    {
        throw "Azure context does not match tenant '$($environment.AzTenantId)' and subscription '$($environment.AzSubscriptionId)' for environment '$envName'. Agent setup was not attempted."
    }
    Write-Host "Successfully connected to Azure environment '$envName'."

    $projectName = $datum.Global.ProjectSettings.ProjectName
    $vmName = Get-M365DscAgentVmName -ProjectName $projectName -EnvironmentName $envName
    $vmSelection = Get-M365DscAgentVm -ProjectName $projectName -EnvironmentName $envName
    if ($null -eq $vmSelection)
    {
        throw "Expected one VM named '$vmName' in subscription '$($environment.AzSubscriptionId)', but none was found."
    }
    $resourceGroupName = $vmSelection.ResourceGroupName
    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop
    Write-Host "Found VM '$vmName' in resource group '$($vm.ResourceGroupName)'."

    $buildAgentIdentityName = Get-M365DscAgentIdentityName -ProjectName $projectName -EnvironmentName $envName
    $buildAgentIdentities = @(
        Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType 'Microsoft.ManagedIdentity/userAssignedIdentities' `
            -ApiVersion '2023-01-31' -ExpandProperties -ErrorAction Stop |
            Where-Object Name -EQ $buildAgentIdentityName
    )
    if ($buildAgentIdentities.Count -ne 1)
    {
        throw "Expected one user-assigned managed identity named '$buildAgentIdentityName' in resource group '$resourceGroupName', found $($buildAgentIdentities.Count). Run '30 Create Agent VMs.ps1' first."
    }
    $buildAgentIdentity = $buildAgentIdentities[0]
    $identityResourceId = "/subscriptions/$($environment.AzSubscriptionId)/resourceGroups/$resourceGroupName/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$buildAgentIdentityName"
    if (-not [string]::Equals([string]$buildAgentIdentity.ResourceId, $identityResourceId, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Managed identity '$buildAgentIdentityName' did not return the expected resource ID '$identityResourceId'. Agent setup was not attempted."
    }
    if (-not $buildAgentIdentity.Properties.clientId -or -not $buildAgentIdentity.Properties.principalId)
    {
        throw "Managed identity '$buildAgentIdentityName' did not return its client ID and principal ID. Agent setup was not attempted."
    }
    $vmIdentityIds = @($vm.Identity.UserAssignedIdentities.Keys)
    if ($identityResourceId -notin $vmIdentityIds)
    {
        throw "Managed identity '$buildAgentIdentityName' is not assigned to VM '$vmName'. Run '30 Create Agent VMs.ps1' first."
    }

    if ($secretBackend -eq 'KeyVault')
    {
        $vaultName = Resolve-M365DscKeyVaultName `
            -ProjectName $projectName `
            -EnvironmentName $envName `
            -TenantId $environment.AzTenantId `
            -SubscriptionId $environment.AzSubscriptionId
        $vault = Get-AzKeyVault -ErrorAction Stop |
            Where-Object VaultName -EQ $vaultName
        if (-not $vault)
        {
            throw "Key Vault '$vaultName' was not found. Run '10 Setup App Registrations.ps1' first."
        }
        Ensure-M365DscKeyVaultRoleAssignment `
            -VaultResourceId $vault.ResourceId `
            -PrincipalId $buildAgentIdentity.Properties.principalId `
            -RoleDefinitionName 'Key Vault Secrets User'
    }

    $vmStatus = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Status -ErrorAction Stop
    $isVmRunning = @($vmStatus.Statuses | Where-Object Code -EQ 'PowerState/running').Count -gt 0
    if (-not $isVmRunning)
    {
        Write-Host "VM '$vmName' is stopped. Starting it now."
        Start-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop | Out-Null
    }

    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        param([string]$DscNodeName)
        $ErrorActionPreference = 'Stop'
        $trustedHostsPath = 'WSMan:\localhost\Client\TrustedHosts'
        $trustedHosts = @(
            (Get-Item -Path $trustedHostsPath -ErrorAction Stop).Value -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )

        if ($DscNodeName -notin $trustedHosts)
        {
            $trustedHosts += $DscNodeName
            Set-Item -Path $trustedHostsPath -Value ($trustedHosts -join ',') -Force -ErrorAction Stop
        }

        Write-Output "WinRM TrustedHosts includes this DSC node: $DscNodeName"
    } -Parameters @{ DscNodeName = $env:COMPUTERNAME }

    Write-Host 'Installing software on the worker VM.'

    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        $ErrorActionPreference = 'Stop'

        if (-not (Test-Path -Path "$env:ProgramData\chocolatey\bin\choco.exe"))
        {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            $installer = Join-Path -Path $env:TEMP -ChildPath 'InstallChocolatey.ps1'
            Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -OutFile $installer
            & $installer
            if (-not $?)
            {
                throw 'Chocolatey installer failed.'
            }
            Remove-Item -Path $installer -Force
        }

    }

    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        param([string]$AgentPackagePath)
        $ErrorActionPreference = 'Stop'
        $chocolateyPackages = 'vscode', 'vscode-powershell', 'git', 'notepadplusplus'

        # A fresh remoting session does not inherit the machine PATH that the Chocolatey installer wrote.
        $choco = "$env:ProgramData\chocolatey\bin\choco.exe"

        foreach ($package in $chocolateyPackages)
        {
            & $choco install $package --yes --no-progress
            if ($LASTEXITCODE -notin 0, 1641, 3010)
            {
                throw "Chocolatey failed to install '$package', exit code $LASTEXITCODE."
            }
        }

        $pwsh = Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\7\pwsh.exe'
        $requiredPowerShellVersion = [version]'7.6.10'
        $installedPowerShellVersion = $null
        if (Test-Path -LiteralPath $pwsh)
        {
            $versionOutput = & $pwsh -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
            if ($LASTEXITCODE -eq 0 -and $versionOutput)
            {
                $installedPowerShellVersion = [version]($versionOutput | Select-Object -Last 1)
            }
        }

        if (-not $installedPowerShellVersion -or $installedPowerShellVersion -lt $requiredPowerShellVersion)
        {
            Write-Output "Installing PowerShell $requiredPowerShellVersion or newer; found '$installedPowerShellVersion'."
            $requiredPowerShellVersionString = $requiredPowerShellVersion.ToString()
            & $choco install powershell-core --version $requiredPowerShellVersionString --yes --no-progress --force
            if ($LASTEXITCODE -notin 0, 1641, 3010)
            {
                throw "Chocolatey failed to install 'powershell-core', exit code $LASTEXITCODE."
            }
        }
        else
        {
            Write-Output "PowerShell $installedPowerShellVersion is already installed at '$pwsh'."
        }

        $versionOutput = & $pwsh -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
        if ($LASTEXITCODE -ne 0 -or -not $versionOutput)
        {
            throw "Could not read the installed PowerShell version from '$pwsh'."
        }
        $installedPowerShellVersion = [version]($versionOutput | Select-Object -Last 1)
        if ($installedPowerShellVersion -lt $requiredPowerShellVersion)
        {
            throw "PowerShell $requiredPowerShellVersion or newer is required, but '$pwsh' is still version '$installedPowerShellVersion'. Reboot the VM if the installer requested it, then rerun agent setup."
        }

        # Without '/Url' the package only extracts the agent binaries. They are copied per agent below,
        # so the personal access token stays out of the Chocolatey command line and its log.
        & $choco install azure-pipelines-agent --yes --no-progress --params "'/Directory:$AgentPackagePath'"
        if ($LASTEXITCODE -notin 0, 1641, 3010)
        {
            throw "Chocolatey failed to install 'azure-pipelines-agent', exit code $LASTEXITCODE."
        }

    } -Parameters @{ AgentPackagePath = $agentPackagePath }

    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $pwsh = Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\7\pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwsh))
        {
            throw "PowerShell 7 was not installed at '$pwsh'."
        }

        & $pwsh -NoLogo -NoProfile -NonInteractive -Command 'Unregister-PSSessionConfiguration -Name PowerShell.7 -Force -ErrorAction SilentlyContinue'
        if ($LASTEXITCODE -ne 0)
        {
            throw "Could not remove the stale PowerShell.7 remoting endpoint (exit code $LASTEXITCODE)."
        }

        & $pwsh -NoLogo -NoProfile -NonInteractive -Command '$ErrorActionPreference = ''Stop''; Enable-PSRemoting -Force -SkipNetworkProfileCheck'
        if ($LASTEXITCODE -ne 0)
        {
            throw "Enable-PSRemoting failed in PowerShell 7 with exit code $LASTEXITCODE."
        }

        $runtimeVersion = & $pwsh -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
        if ($LASTEXITCODE -ne 0 -or -not $runtimeVersion)
        {
            throw "Could not read the PowerShell 7 version (exit code $LASTEXITCODE)."
        }

        $runtimeFramework = & $pwsh -NoLogo -NoProfile -NonInteractive -Command '[System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription'
        if ($LASTEXITCODE -ne 0 -or -not $runtimeFramework)
        {
            throw "Could not read the .NET runtime details (exit code $LASTEXITCODE)."
        }

        $runtimeHome = & $pwsh -NoLogo -NoProfile -NonInteractive -Command '$PSHOME'
        if ($LASTEXITCODE -ne 0 -or -not $runtimeHome)
        {
            throw "Could not read the PowerShell home directory (exit code $LASTEXITCODE)."
        }
        Write-Output "Build agent runtime: PowerShell=$runtimeVersion; .NET=$runtimeFramework; PSHOME=$runtimeHome"

        Set-Service -Name WinRM -StartupType Automatic
        Restart-Service -Name WinRM -Force -ErrorAction Stop
        Write-Output 'PowerShell 7 remoting endpoint enabled.'
    }
    Start-Sleep -Seconds 10
    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $session = New-PSSession -ComputerName localhost -ConfigurationName PowerShell.7 -EnableNetworkAccess -ErrorAction Stop
        Remove-PSSession -Session $session

        Write-Output 'PowerShell 7 remoting endpoint is enabled and responding.'
    }

    for ($i = 1; $i -le $datum.Global.ProjectSettings.NumbertOfBuildAgents; $i++)
    {
        Invoke-WorkerVmScript -VM $vm -ScriptBlock {
            param(
                [int]$AgentIndex,
                [string]$AgentPackagePath,
                [string]$OrganizationName,
                [string]$PersonalAccessToken,
                [string]$AgentPoolName
            )
            $ErrorActionPreference = 'Stop'

            $vstsService = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'vstsagent%' AND PathName LIKE '%Agent$AgentIndex%'"
            if (-not $vstsService)
            {
                Write-Output "Installing AzDo Build Agent '$($env:COMPUTERNAME)-$AgentIndex'"
                $null = New-Item -Path "C:\Agent$AgentIndex" -ItemType Directory -Force
                Copy-Item -Path "$AgentPackagePath\*" -Destination "C:\Agent$AgentIndex" -Recurse -Force
                $previousToken = $env:VSTS_AGENT_INPUT_TOKEN
                try
                {
                    $env:VSTS_AGENT_INPUT_TOKEN = $PersonalAccessToken
                    & "C:\Agent$AgentIndex\config.cmd" `
                        --unattended `
                        --url "https://dev.azure.com/$OrganizationName" `
                        --auth pat `
                        --pool $AgentPoolName `
                        --agent "$($env:COMPUTERNAME)-$AgentIndex" `
                        --runAsService `
                        --windowsLogonAccount 'NT AUTHORITY\SYSTEM' `
                        --acceptTeeEula
                    if ($LASTEXITCODE -ne 0)
                    {
                        throw "Azure DevOps agent configuration failed with exit code $LASTEXITCODE."
                    }
                }
                finally { $env:VSTS_AGENT_INPUT_TOKEN = $previousToken }

                $vstsService = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'vstsagent%' AND PathName LIKE '%Agent$AgentIndex%'"
                $vstsService | Invoke-CimMethod -Name Change -Arguments @{ StartName = 'LocalSystem' }
                Restart-Service -Name $vstsService.Name -WarningAction SilentlyContinue
            }
            else
            {
                Write-Output "AzDo Build Agent '$($env:COMPUTERNAME)-$AgentIndex' already installed."
            }

        } -Parameters @{
            AgentIndex           = [string]$i
            AgentPackagePath     = $agentPackagePath
            OrganizationName     = $datum.Global.ProjectSettings.OrganizationName
            PersonalAccessToken  = $datum.Global.ProjectSettings.PersonalAccessToken
            AgentPoolName        = $datum.Global.ProjectSettings.AgentPoolName
        }
    }

    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        $ErrorActionPreference = 'Stop'

        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue))
        {
            Write-Output 'Installing the NuGet package provider.'
            Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.208' -Force -ErrorAction Stop
        }
        else
        {
            Write-Output 'The NuGet package provider is already installed.'
        }

        $powerShellGet = Get-Module -Name PowerShellGet -ListAvailable |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
        if (-not $powerShellGet)
        {
            throw 'Windows PowerShell does not have the built-in PowerShellGet module required to install Microsoft365DSC.'
        }

        Write-Output "Using the installed PowerShellGet module version $($powerShellGet.Version); skipping its redundant download."

    }

    Invoke-WorkerVmScript -VM $vm -ScriptBlock {
        param(
            [string]$EnvironmentName,
            [string]$M365DscVersion
        )
        $ErrorActionPreference = 'Stop'

        $installedModule = Get-Module -Name Microsoft365DSC -ListAvailable |
            Where-Object Version -EQ ([version]$M365DscVersion) |
            Select-Object -First 1
        if (-not $installedModule)
        {
            Write-Output "Installing Microsoft365DSC version $M365DscVersion from PSGallery."
            Install-Module -Name Microsoft365DSC -RequiredVersion $M365DscVersion -Repository PSGallery -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
        }
        else
        {
            Write-Output "Microsoft365DSC version $M365DscVersion is already installed."
        }

        Import-Module -Name Microsoft365DSC -RequiredVersion $M365DscVersion -Force -ErrorAction Stop
        Set-M365DSCLoggingOption -IncludeNonDrifted $true
        [System.Environment]::SetEnvironmentVariable('BuildEnvironment', $EnvironmentName, 'Machine')

    } -Parameters @{
        EnvironmentName = [string]$envName
        M365DscVersion  = [string]$requiredModuleVersions['Microsoft365DSC']
    }

    # ---------------------------------------------------------------------------
    #   Upload M365DscLcmApplication certificate for authentication with Azure
    # ---------------------------------------------------------------------------

    if ($secretBackend -eq 'Kdbx')
    {
        & "$PSScriptRoot\..\Secrets\Kdbx\Worker Certificates.ps1" -VM $vm -Environment $environment `
            -EnvironmentName $envName -InvokeCommand ${function:Invoke-WorkerVmScript}
    }
    else
    {
        foreach ($certificateToInstall in $certificatesToInstall)
        {
            $certificateThumbprint = ($environment.Identities | Where-Object Name -EQ $certificateToInstall).CertificateThumbprint
            $pfxName = Get-M365DscKeyVaultSecretName -IdentityName $certificateToInstall -CredentialType pfx
            $pfxPasswordName = Get-M365DscKeyVaultSecretName -IdentityName $certificateToInstall -CredentialType pfx-password
            $managedIdentityClientId = $buildAgentIdentity.Properties.clientId

            Write-Host "Installing certificate '$certificateToInstall' on VM '$($vm.Name)'."
            Invoke-WorkerVmScript -VM $vm -ScriptBlock {
                param(
                    [string]$VaultName,
                    [string]$PfxName,
                    [string]$PfxPasswordName,
                    [string]$ManagedIdentityClientId,
                    [string]$CertificateThumbprint,
                    [string]$AzKeyVaultVersion
                )
                $ErrorActionPreference = 'Stop'

                $installedAzKeyVault = Get-Module -Name Az.KeyVault -ListAvailable |
                    Where-Object Version -EQ ([version]$AzKeyVaultVersion) |
                    Select-Object -First 1
                if (-not $installedAzKeyVault)
                {
                    Write-Output "Installing Az.KeyVault version $AzKeyVaultVersion from PSGallery."
                    Install-Module -Name Az.KeyVault -RequiredVersion $AzKeyVaultVersion -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
                }
                else
                {
                    Write-Output "Az.KeyVault version $AzKeyVaultVersion is already installed."
                }

                Import-Module -Name Az.KeyVault -RequiredVersion $AzKeyVaultVersion -ErrorAction Stop
                [Environment]::SetEnvironmentVariable('AZURE_CLIENT_ID', $ManagedIdentityClientId, 'Machine')
                Write-Output "Connecting to managed identity '$ManagedIdentityClientId' for Key Vault access."
                Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId -ErrorAction Stop | Out-Null
                Write-Output 'Connected to the managed identity.'

                $pfxBase64 = $null
                $pfxPassword = $null
                for ($attempt = 1; $attempt -le 12; $attempt++)
                {
                    try
                    {
                        Write-Output "Reading certificate secrets from Key Vault (attempt $attempt of 12)."
                        $pfxBase64 = Get-AzKeyVaultSecret -VaultName $VaultName -Name $PfxName -AsPlainText -ErrorAction Stop
                        $pfxPassword = Get-AzKeyVaultSecret -VaultName $VaultName -Name $PfxPasswordName -AsPlainText -ErrorAction Stop
                        break
                    }
                    catch
                    {
                        if ($attempt -eq 12)
                        {
                            throw "The VM managed identity could not read certificate secrets from Key Vault '$VaultName'. $($_.Exception.Message)"
                        }

                        Write-Output 'Key Vault secret retrieval failed; retrying in 10 seconds.'
                        Start-Sleep -Seconds 10
                    }
                }

                if ([string]::IsNullOrWhiteSpace($pfxBase64) -or [string]::IsNullOrWhiteSpace($pfxPassword))
                {
                    throw "Key Vault certificate secrets for '$CertificateThumbprint' were empty."
                }

                $certificatePath = Join-Path -Path $env:TEMP -ChildPath "$CertificateThumbprint.pfx"
                try
                {
                    [System.IO.File]::WriteAllBytes($certificatePath, [Convert]::FromBase64String($pfxBase64))
                    Write-Output 'Importing the certificate into the LocalMachine certificate store.'
                    $securePfxPassword = [securestring]::new()
                    try
                    {
                        foreach ($character in $pfxPassword.ToCharArray())
                        {
                            $securePfxPassword.AppendChar($character)
                        }
                        $securePfxPassword.MakeReadOnly()
                        Import-PfxCertificate `
                            -FilePath $certificatePath `
                            -Password $securePfxPassword `
                            -CertStoreLocation Cert:\LocalMachine\My `
                            -ErrorAction Stop | Out-Null
                    }
                    finally
                    {
                        $securePfxPassword.Dispose()
                    }
                }
                finally
                {
                    Remove-Item -Path $certificatePath -Force -ErrorAction SilentlyContinue
                }

                $installedCertificate = Get-Item -Path "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction Stop
                if (-not $installedCertificate.HasPrivateKey)
                {
                    throw "Certificate '$CertificateThumbprint' was imported without its private key."
                }
                Write-Output "Certificate '$CertificateThumbprint' is installed with its private key."
            } -Parameters @{
                VaultName             = $vaultName
                PfxName               = $pfxName
                PfxPasswordName       = $pfxPasswordName
                ManagedIdentityClientId = $managedIdentityClientId
                CertificateThumbprint = $certificateThumbprint
                AzKeyVaultVersion     = [string]$requiredModuleVersions['Az.KeyVault']
            } -TimeoutInSeconds 600

        }

    }
    Write-Host "Restarting VM '$($vm.Name)' after installing certificates."
    Restart-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction Stop | Out-Null

    # ------------------------------------------------------------------------------------------------------------

    Write-Host "Finished installing AzDo Build Agent on VM '$($vm.Name)' in environment '$envName'."

}

Write-Host 'Agent setup completed.' -ForegroundColor Green
