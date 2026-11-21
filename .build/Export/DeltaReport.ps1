. "$PSScriptRoot\DeltaReport.Helpers.ps1"

task NewM365DscDeltaReport {

    $sourceTenant = if ($env:DeltaReportSourceTenant)
    {
        $env:DeltaReportSourceTenant
    }
    else
    {
        Write-Error "The environment variable 'DeltaReportSourceTenant' is not set. Please specify the source tenant for the delta report." -ErrorAction Stop
    }

    $inputDirectory = if ($env:DeltaReportInputDirectory)
    {
        $env:DeltaReportInputDirectory
    }
    else
    {
        Join-Path -Path $OutputDirectory -ChildPath 'Export'
    }

    $reportDirectory = if ($env:DeltaReportOutputDirectory)
    {
        $env:DeltaReportOutputDirectory
    }
    else
    {
        Join-Path -Path $OutputDirectory -ChildPath 'DeltaReport'
    }

    if (-not (Test-Path -Path $inputDirectory))
    {
        Write-Error "The input directory '$inputDirectory' does not exist. Please download the 'TenantConfig-*' artifacts first." -ErrorAction Stop
    }

    Write-Host "Looking for exported tenant configurations in '$inputDirectory'" -ForegroundColor Yellow

    #The export creates '<Tenant>\<DscResource>\M365TenantConfig.ps1', hence the tenant is the grandparent of each configuration file.
    $tenants = @(Get-ChildItem -Path $inputDirectory -Filter *.ps1 -File -Recurse |
        Where-Object { $null -ne $_.Directory.Parent } |
            Group-Object -Property { $_.Directory.Parent.FullName })

    if ($tenants.Count -eq 0)
    {
        Write-Error "Could not find any exported DSC configuration (*.ps1) in '$inputDirectory'." -ErrorAction Stop
    }

    Write-Host "Found $($tenants.Count) tenant(s) in the input directory." -ForegroundColor Yellow

    $stagingDirectory = Join-Path -Path $reportDirectory -ChildPath '_staging'
    if (Test-Path -Path $reportDirectory)
    {
        Remove-Item -Path $reportDirectory -Recurse -Force
    }
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null

    $mergedConfigurations = @{}

    foreach ($tenant in $tenants)
    {
        $tenantName = Split-Path -Path $tenant.Name -Leaf
        Write-Host "Merging $($tenant.Count) configuration file(s) of tenant '$tenantName'" -ForegroundColor Yellow

        $tenantStagingDirectory = Join-Path -Path $stagingDirectory -ChildPath $tenantName
        New-Item -Path $tenantStagingDirectory -ItemType Directory -Force | Out-Null

        #Join-M365DSCConfiguration merges all configurations of one folder into the base file, so the nested export structure has to be flattened first.
        $baseConfigurationFile = 'M365TenantConfig.ps1'
        $isBaseConfiguration = $true
        foreach ($configurationFile in ($tenant.Group | Sort-Object -Property FullName))
        {
            $targetName = if ($isBaseConfiguration)
            {
                $baseConfigurationFile
            }
            else
            {
                "$($configurationFile.Directory.Name).ps1"
            }
            $isBaseConfiguration = $false

            Copy-Item -Path $configurationFile.FullName -Destination (Join-Path -Path $tenantStagingDirectory -ChildPath $targetName) -Force
        }

        #Join-M365DSCConfiguration returns the merged configuration as a string instead of writing it to disk.
        $mergedConfiguration = Join-M365DSCConfiguration -ConfigurationFile $baseConfigurationFile -ConfigurationPath $tenantStagingDirectory

        if ([System.String]::IsNullOrWhiteSpace($mergedConfiguration))
        {
            Write-Error "Join-M365DSCConfiguration returned an empty configuration for tenant '$tenantName'." -ErrorAction Stop
        }

        $tenantConfigurationPath = Join-Path -Path $reportDirectory -ChildPath "$tenantName.ps1"
        Set-Content -Path $tenantConfigurationPath -Value $mergedConfiguration -Encoding utf8 -Force
        $mergedConfigurations.Add($tenantName, $tenantConfigurationPath)

        Write-Host "    Merged configuration written to '$tenantConfigurationPath'." -ForegroundColor Green
    }

    Remove-Item -Path $stagingDirectory -Recurse -Force

    if (-not $mergedConfigurations.ContainsKey($sourceTenant))
    {
        Write-Error "The source tenant '$sourceTenant' was not found in '$inputDirectory'. Available tenants: $($mergedConfigurations.Keys -join ', ')." -ErrorAction Stop
    }

    $destinationTenants = $mergedConfigurations.Keys | Where-Object { $_ -ne $sourceTenant } | Sort-Object
    if ($destinationTenants.Count -eq 0)
    {
        Write-Error "There is no destination tenant to compare with source tenant '$sourceTenant'. The input directory '$inputDirectory' contains only this tenant." -ErrorAction Stop
    }

    $tenantIdentifierMap = $null
    if ($env:DeltaReportAnonymizeTenantIdentifiers -eq 'true')
    {
        if (-not $env:BuildEnvironment)
        {
            Write-Error "Set 'BuildEnvironment' so the build agent can load tenant IDs from Key Vault using its managed identity before anonymizing the delta report." -ErrorAction Stop
        }

        $azureConfigurationPath = Join-Path -Path $ProjectPath -ChildPath 'source\Global\Azure.yml'
        if (-not (Test-Path -LiteralPath $azureConfigurationPath -PathType Leaf))
        {
            Write-Error "Azure configuration file '$azureConfigurationPath' was not found; tenant identifiers cannot be anonymized." -ErrorAction Stop
        }

        $azureConfiguration = Get-Content -LiteralPath $azureConfigurationPath -Raw -ErrorAction Stop | ConvertFrom-Yaml -ErrorAction Stop
        if ($null -eq $azureConfiguration.Environments)
        {
            Write-Error "Azure configuration file '$azureConfigurationPath' does not define Environments; tenant identifiers cannot be anonymized." -ErrorAction Stop
        }

        $requiredModuleVersions = Import-PowerShellDataFile -Path (Join-Path -Path $ProjectPath -ChildPath 'RequiredModules.psd1')
        Import-Module -Name Az.Accounts -RequiredVersion $requiredModuleVersions['Az.Accounts'] -ErrorAction Stop
        Import-Module -Name Az.KeyVault -RequiredVersion $requiredModuleVersions['Az.KeyVault'] -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $ProjectPath -ChildPath 'lab\AutomatedLab\AzHelpers.psm1') -Force -ErrorAction Stop
        $datum = New-DatumStructure -DefinitionFile (Join-Path -Path $ProjectPath -ChildPath 'source\Datum.yml')
        Update-M365DscDatumFromKeyVault `
            -Datum $datum `
            -ProjectName $datum.Global.ProjectSettings.ProjectName `
            -EnvironmentName ([string]$env:BuildEnvironment) `
            -ManagedIdentity | Out-Null

        $tenantIdentifierMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($environment in $datum.Global.Azure.Environments.GetEnumerator())
        {
            $tenantName = [string]$environment.Value.AzTenantName
            $tenantId = [string]$environment.Value.AzTenantId
            if ([string]::IsNullOrWhiteSpace($tenantName))
            {
                Write-Error "Environment '$($environment.Name)' is missing its public tenant name; refusing to anonymize the delta report." -ErrorAction Stop
            }

            $tenantIdentifierMap[$tenantName] = [string]$environment.Name
            if ($tenantId)
            {
                if ($tenantIdentifierMap.Contains($tenantId) -and $tenantIdentifierMap[$tenantId] -ne $environment.Name)
                {
                    Write-Error "Tenant identifier '$tenantId' maps to more than one environment." -ErrorAction Stop
                }

                $tenantIdentifierMap[$tenantId] = [string]$environment.Name
            }
        }

        foreach ($tenantName in $mergedConfigurations.Keys)
        {
            if (-not $tenantIdentifierMap.Contains($tenantName))
            {
                if ($tenantName -eq 'delta-report-test.onmicrosoft.com')
                {
                    $tenantIdentifierMap[$tenantName] = 'Synthetic'
                    continue
                }

                Write-Error "Exported tenant '$tenantName' is not configured in '$azureConfigurationPath'; refusing to publish an incompletely anonymized report." -ErrorAction Stop
            }
            if ($tenantIdentifierMap[$tenantName] -ne $env:BuildEnvironment)
            {
                Write-Error "The build agent's managed identity can load Key Vault metadata only for '$($env:BuildEnvironment)'; refusing to publish a report containing tenant identifiers for '$tenantName'." -ErrorAction Stop
            }
        }
    }

    foreach ($destinationTenant in $destinationTenants)
    {
        $reportSourceName = $sourceTenant
        $reportDestinationName = $destinationTenant
        if ($null -ne $tenantIdentifierMap)
        {
            $reportSourceName = $tenantIdentifierMap[$sourceTenant]
            $reportDestinationName = $tenantIdentifierMap[$destinationTenant]
        }

        $reportPath = Join-Path -Path $reportDirectory -ChildPath "DeltaReport-$reportSourceName-vs-$reportDestinationName.html"
        Write-Host "Creating delta report of '$sourceTenant' against '$destinationTenant'" -ForegroundColor Yellow

        $Parameters = @{
            Source      = $mergedConfigurations[$sourceTenant]
            Destination = $mergedConfigurations[$destinationTenant]
            OutputPath  = $reportPath
            Type        = 'HTML'
            DriftOnly   = $true
        }
        New-M365DSCDeltaReport @Parameters

        if ($null -ne $tenantIdentifierMap)
        {
            Convert-DeltaReportTenantIdentifiers -Path $reportPath -TenantIdentifierMap $tenantIdentifierMap
        }

        Write-Host "    Delta report written to '$reportPath'." -ForegroundColor Green
    }

}
