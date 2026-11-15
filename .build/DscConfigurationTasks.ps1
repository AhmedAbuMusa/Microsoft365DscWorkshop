Import-Module -Name $ProjectPath\Lab\AutomatedLab\M365DscHelpers.psm1

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

task TestDeploymentDscConfiguration {

    $environment = $env:buildEnvironment
    if (-not $environment)
    {
        Write-Error 'The build environment is not set' -ErrorAction Stop
    }

    $mofDirectory = Join-Path -Path (Join-Path -Path $OutputDirectory -ChildPath $MofOutputFolder) -ChildPath $environment
    $mofFiles = @(Get-ChildItem -Path $mofDirectory -Filter '*.mof' -File -ErrorAction SilentlyContinue)
    if ($mofFiles.Count -eq 0)
    {
        Write-Error "No compiled MOF files were found in '$mofDirectory'. The deployment validation job must download the environment's MOF artifact." -ErrorAction Stop
    }

    foreach ($mofFile in $mofFiles)
    {
        $computerName = $mofFile.BaseName
        Write-Host "Validating DSC configuration on '$computerName'." -ForegroundColor Yellow

        $cimSession = New-CimSession -ComputerName $computerName -ErrorAction Stop
        $validationDeadline = (Get-Date).AddMinutes(10)
        try
        {
            while ($true)
            {
                $lcmState = (Get-DscLocalConfigurationManager -CimSession $cimSession -ErrorAction Stop).LCMState
                if ($lcmState -eq 'Busy')
                {
                    if ((Get-Date) -ge $validationDeadline)
                    {
                        throw "Timed out waiting for the LCM on '$computerName' to become idle; validation was not run."
                    }

                    Write-Host "LCM on '$computerName' is busy; checking again in 10 seconds." -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                    continue
                }

                try
                {
                    $dscState = Test-DscConfiguration -CimSession $cimSession -Detailed -ErrorAction Stop
                    break
                }
                catch
                {
                    if ($_.Exception.Message -notmatch '(?i)cmdlet is in progress and must return before Test-DscConfiguration can be invoked')
                    {
                        throw
                    }

                    if ((Get-Date) -ge $validationDeadline)
                    {
                        throw "Timed out waiting for the active DSC operation on '$computerName' to finish; validation was not run. $($_.Exception.Message)"
                    }

                    Write-Host "A DSC operation is still in progress on '$computerName'; retrying validation in 10 seconds." -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                }
            }
        }
        finally
        {
            try
            {
                Remove-CimSession -CimSession $cimSession -ErrorAction Stop
            }
            catch
            {
                Write-Warning "Could not close the CIM session for '$computerName': $($_.Exception.Message)"
            }
        }

        if (-not $dscState.InDesiredState)
        {
            Write-Host "The following $($dscState.ResourcesNotInDesiredState.Count) resource(s) are not in the desired state on '$computerName':" -ForegroundColor Red
            $dscState.ResourcesNotInDesiredState | ConvertTo-Yaml | Write-Host -ForegroundColor Yellow

            Write-Error -Message "Test failed on '$computerName', $($dscState.ResourcesNotInDesiredState.Count) resource(s) are not in the desired state." -ErrorAction Stop
        }

        Write-Host "All resources on '$computerName' are in the desired state." -ForegroundColor Green
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

    # UPSTREAM: M365DSC-1
    & (Join-Path -Path $ProjectPath -ChildPath 'pipelines\scripts\PatchMicrosoft365DscAADGroupsSettings.ps1') -RequiredModulesPath $requiredModulesPath

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
