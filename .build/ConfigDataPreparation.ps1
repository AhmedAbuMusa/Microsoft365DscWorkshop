task ConfigDataPreparation {

    if ($env:M365DSC_METADATA_PATH)
    {
        if (-not $env:BuildEnvironment)
        {
            throw 'BuildEnvironment is required with M365DSC_METADATA_PATH; no Key Vault fallback is allowed.'
        }
        Import-Module -Name (Join-Path $BuildRoot 'lab\Secrets\Kdbx\PipelineSecrets.psm1') -Force -ErrorAction Stop
        $datum = Update-M365DscDatumFromPipelineMetadata -Datum $datum -Path $env:M365DSC_METADATA_PATH -EnvironmentName $env:BuildEnvironment
    }
    elseif ($env:M365DSC_SECRET_BACKEND -eq 'Kdbx')
    {
        if ($env:BuildEnvironment)
        {
            throw 'Operational Kdbx builds require M365DSC_METADATA_PATH; no Key Vault or database fallback is allowed.'
        }
        # Bootstrap's clean azureinit child uses public template data before identities exist.
    }
    else
    {
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

        Import-Module -Name (Join-Path -Path $BuildRoot -ChildPath 'lab\AutomatedLab\AzHelpers.psm1') -Force -ErrorAction Stop
        if ($env:BuildEnvironment)
        {
            $datum = Update-M365DscDatumFromKeyVault `
                -Datum $datum `
                -ProjectName $datum.Global.ProjectSettings.ProjectName `
                -EnvironmentName $env:BuildEnvironment `
                -ManagedIdentity
        }
    }

    $global:azBuildParameters = @{}

    foreach ($env in $datum.Global.Azure.Environments.GetEnumerator())
    {
        if ($env:BuildEnvironment -and $env.Name -eq $env:BuildEnvironment -and -not $env.Value.AzTenantId)
        {
            if ($env:M365DSC_METADATA_PATH)
            {
                throw "Kdbx pipeline metadata did not provide tenant metadata for build environment '$($env.Name)'."
            }
            throw "Key Vault did not provide tenant metadata for build environment '$($env.Name)'."
        }

        Write-Build DarkGray "`tAdding Azure environment '$($env.Name)' to build parameters."
        $identities = @($env.Value.Identities | Where-Object { $_.CertificateThumbprint })
        $tenantId = [string]$env.Value.AzTenantId
        if (-not $tenantId)
        {
            $tenantHash = [System.Security.Cryptography.SHA256]::HashData(
                [System.Text.Encoding]::UTF8.GetBytes("Microsoft365DscWorkshopBuildOnly|$($env.Name)|tenant")
            )
            $tenantId = [Guid]::new([byte[]]$tenantHash[0..15]).ToString()
            $identities = foreach ($identityName in 'M365DscLcmApplication', 'M365DscExportApplication')
            {
                $identityHash = [System.Security.Cryptography.SHA256]::HashData(
                    [System.Text.Encoding]::UTF8.GetBytes("Microsoft365DscWorkshopBuildOnly|$($env.Name)|$identityName")
                )
                $thumbprint = [System.Convert]::ToHexString(
                    [System.Security.Cryptography.SHA1]::HashData(
                        [System.Text.Encoding]::UTF8.GetBytes("Microsoft365DscWorkshopBuildOnly|$($env.Name)|$identityName")
                    )
                )
                @{
                    Name                 = $identityName
                    ApplicationId        = [Guid]::new([byte[]]$identityHash[0..15]).ToString()
                    CertificateThumbprint = $thumbprint
                }
            }
        }

        $global:azBuildParameters."$($env.Name)" = @{
            AzTenantId   = $tenantId
            AzTenantName = $env.Value.AzTenantName
            Identities   = $identities
        }

    }

    if ($datum.Global.ProjectSettings.ProjectName -eq '<ProjectName>')
    {
        Write-Host "The ProjectName placeholder will be replaced with 'Microsoft365DscWorkshopDemoTemplate' for the build to work." -ForegroundColor Yellow
        $datum.Global.ProjectSettings.ProjectName = 'Microsoft365DscWorkshopDemoTemplate'
    }
}
