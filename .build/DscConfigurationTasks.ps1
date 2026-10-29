Import-Module -Name $ProjectPath\Lab\M365DscHelpers.psm1

task StartDscConfiguration {

    $environment = $env:buildEnvironment
    if (-not $environment)
    {
        Write-Error 'The build environment is not set'
    }

    Wait-DscLocalConfigurationManager -DoNotWaitForProcessToFinish

    $mofOutputDirectory = Join-Path -Path $OutputDirectory -ChildPath $MofOutputFolder
    try
    {
        Start-DscConfiguration -Path "$mofOutputDirectory\$environment" -Wait -Force -Verbose -ErrorAction Stop
    }
    catch
    {
        $waitTimeInSeconds = Get-Random -Minimum 10 -Maximum 40
        Write-Host "Failed to start DSC configuration. Will retry in $waitTimeInSeconds seconds." -ForegroundColor Yellow

        Start-Sleep -Seconds $waitTimeInSeconds
        Wait-DscLocalConfigurationManager -DoNotWaitForProcessToFinish

        Start-DscConfiguration -Path "$mofOutputDirectory\$environment" -Wait -Force -Verbose -ErrorAction Stop
    }

}

task StartExistingDscConfiguration {

    Wait-DscLocalConfigurationManager -DoNotWaitForProcessToFinish

    try
    {
        Start-DscConfiguration -UseExisting -Wait -Verbose -ErrorAction Stop
    }
    catch
    {
        $waitTimeInSeconds = Get-Random -Minimum 10 -Maximum 40
        Write-Host "Failed to start existing DSC configuration. Will retry in $waitTimeInSeconds seconds." -ForegroundColor Yellow

        Start-Sleep -Seconds $waitTimeInSeconds
        Wait-DscLocalConfigurationManager -DoNotWaitForProcessToFinish

        Start-DscConfiguration -UseExisting -Wait -Verbose -ErrorAction Stop
    }

}

task TestDscConfiguration {

    Wait-DscLocalConfigurationManager -DoNotWaitForProcessToFinish

    $dscState = Write-M365DscStatusEvent -PassThru

    if (-not $dscState.InDesiredState)
    {
        Write-Host "The following $($dscState.ResourcesNotInDesiredState.Count) resource(s) are not in the desired state:" -ForegroundColor Red
        $dscState.ResourcesNotInDesiredState | ConvertTo-Yaml | Write-Host -ForegroundColor Yellow

        Write-Error -Message "Test failed, $($dscState.ResourcesNotInDesiredState.Count) resource(s) are not in the desired state. Please see the output above for more details."
    }
    else
    {
        Write-Host 'All resources are in the desired state' -ForegroundColor Green
    }
}

task CleanModuleFolder {

    $programFileModulePath = 'C:\Program Files\WindowsPowerShell\Modules'
    $modulesToKeep = 'Microsoft.PowerShell.Operation.Validation', 'PackageManagement', 'Pester', 'PowerShellGet', 'PSReadline'

    Wait-DscLocalConfigurationManager

    Get-ChildItem -Path $programFileModulePath |
        Where-Object { $_.BaseName -notin $modulesToKeep } |
            Remove-Item -Recurse -Force

}

task InitializeModuleFolder {

    $environment = $env:buildEnvironment
    if (-not $environment)
    {
        Write-Error 'The build environment is not set'
    }

    Wait-DscLocalConfigurationManager

    $programFileModulePath = 'C:\Program Files\WindowsPowerShell\Modules'
    $m365DscSourcePath = Join-Path -Path $requiredModulesPath -ChildPath 'Microsoft365DSC'
    $m365DscSourceVersions = @(Get-ChildItem -Path $m365DscSourcePath -Directory -ErrorAction Stop)
    if ($m365DscSourceVersions.Count -ne 1)
    {
        throw "Expected exactly one pinned Microsoft365DSC version under '$m365DscSourcePath', found $($m365DscSourceVersions.Count)."
    }

    $m365DscTargetPath = Join-Path -Path $programFileModulePath -ChildPath 'Microsoft365DSC'
    if (Test-Path -Path $m365DscTargetPath)
    {
        Get-ChildItem -Path $m365DscTargetPath -Directory -ErrorAction Stop |
            Where-Object { $_.Name -ne $m365DscSourceVersions[0].Name } |
                ForEach-Object {
                    Write-Host "Removing conflicting Microsoft365DSC version '$($_.Name)'"
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                }
    }

    Write-Host "Copying modules from '$requiredModulesPath' to '$programFileModulePath'"
    Get-ChildItem -Path $requiredModulesPath | ForEach-Object {
        Write-Host "Copying module '$($_.BaseName)'"
        $_ | Copy-Item -Destination $programFileModulePath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable copyErrors

        if ($copyErrors)
        {
            Write-Host "There were $($copyErrors.Count) errors copying the module '$($_.BaseName)'"
        }
    }

}

task InitializeModuleFolderForDeltaReport {

    Wait-DscLocalConfigurationManager

    $programFileModulePath = 'C:\Program Files\WindowsPowerShell\Modules'
    $m365DscSourcePath = Join-Path -Path $requiredModulesPath -ChildPath 'Microsoft365DSC'
    $m365DscSourceVersions = @(Get-ChildItem -Path $m365DscSourcePath -Directory -ErrorAction Stop)
    if ($m365DscSourceVersions.Count -ne 1)
    {
        throw "Expected exactly one pinned Microsoft365DSC version under '$m365DscSourcePath', found $($m365DscSourceVersions.Count)."
    }

    $m365DscTargetPath = Join-Path -Path $programFileModulePath -ChildPath 'Microsoft365DSC'
    if (Test-Path -Path $m365DscTargetPath)
    {
        Write-Host "Removing duplicate Microsoft365DSC installation from '$m365DscTargetPath'"
        Remove-Item -LiteralPath $m365DscTargetPath -Recurse -Force -ErrorAction Stop
    }

    Write-Host "Copying modules from '$requiredModulesPath' to '$programFileModulePath'"
    Get-ChildItem -Path $requiredModulesPath | ForEach-Object {
        $module = $_
        if ($module.BaseName -eq 'Microsoft365DSC')
        {
            Write-Host "Keeping Microsoft365DSC available only from '$m365DscSourcePath'"
            return
        }

        Write-Host "Copying module '$($module.BaseName)'"
        try
        {
            $module | Copy-Item -Destination $programFileModulePath -Recurse -Force -ErrorAction Stop
        }
        catch
        {
            throw "Failed to copy module '$($module.BaseName)' to '$programFileModulePath': $_"
        }
    }

    $visibleM365DscModules = @(Get-Module -ListAvailable -Name Microsoft365DSC)
    if ($visibleM365DscModules.Count -ne 1)
    {
        $visiblePaths = $visibleM365DscModules.Path -join ', '
        throw "Expected exactly one discoverable Microsoft365DSC module after initialization, found $($visibleM365DscModules.Count): $visiblePaths"
    }

    if ([string]$visibleM365DscModules[0].Version -ne $m365DscSourceVersions[0].Name)
    {
        throw "Expected Microsoft365DSC version '$($m365DscSourceVersions[0].Name)' after initialization, found '$($visibleM365DscModules[0].Version)' at '$($visibleM365DscModules[0].Path)'."
    }

}
