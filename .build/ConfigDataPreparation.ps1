task ConfigDataPreparation {

    $requiredModuleVersions = Import-PowerShellDataFile -Path (Join-Path -Path $BuildRoot -ChildPath 'RequiredModules.psd1')

    try
    {
        foreach ($moduleName in 'Az.Accounts', 'Az.Resources')
        {
            $requiredVersion = $requiredModuleVersions[$moduleName]
            if ($requiredVersion -is [hashtable])
            {
                $requiredVersion = $requiredVersion.Version
            }

            if (-not $requiredVersion -or $requiredVersion -eq 'latest')
            {
                throw "Module '$moduleName' must have an explicit version in RequiredModules.psd1."
            }

            $loadedModule = Get-Module -Name $moduleName | Select-Object -First 1
            if ($loadedModule)
            {
                if ($loadedModule.Version -ne [version]$requiredVersion)
                {
                    throw "Module '$moduleName' version '$($loadedModule.Version)' is already loaded; expected '$requiredVersion'."
                }
            }
            else
            {
                Import-Module -Name $moduleName -RequiredVersion $requiredVersion -ErrorAction Stop
            }
        }
    }
    catch
    {
        throw "Failed to load the pinned Azure PowerShell modules. $($_.Exception.Message)"
    }

    $global:azBuildParameters = @{}

    foreach ($env in $datum.Global.Azure.Environments.GetEnumerator())
    {
        if (-not $env.Value.AzTenantId)
        {
            Write-Error "AzTenantId is not defined for environment $($env.Name)" -ErrorAction Stop
        }

        Write-Build DarkGray "`tAdding Azure environment '$($env.Name)' to build parameters."
        $global:azBuildParameters."$($env.Name)" = @{
            AzTenantId   = $env.Value.AzTenantId
            AzTenantName = $env.Value.AzTenantName
            Identities   = $env.Value.Identities | Where-Object { $_.CertificateThumbprint }
        }

    }

    if ($datum.Global.ProjectSettings.ProjectName -eq '<ProjectName>')
    {
        Write-Host "The ProjectName placeholder will be replaced with 'Microsoft365DscWorkshopDemoTemplate' for the build to work." -ForegroundColor Yellow
        $datum.Global.ProjectSettings.ProjectName = 'Microsoft365DscWorkshopDemoTemplate'
    }
}
