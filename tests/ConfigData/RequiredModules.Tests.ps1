BeforeDiscovery {
    $requiredModules = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')

    $getPinnedVersion = {
        param ($Pin)

        if ($Pin -is [hashtable])
        {
            $Pin.Version
        }
        else
        {
            $Pin
        }
    }

    $authenticationVersion = & $getPinnedVersion $requiredModules['Microsoft.Graph.Authentication']

    $graphModuleNames = $requiredModules.Keys |
        Where-Object -FilterScript { $_ -like 'Microsoft.Graph.*' -and $_ -ne 'Microsoft.Graph.Authentication' } |
            Sort-Object

    $graphModuleTestCases = @(
        foreach ($graphModuleName in $graphModuleNames)
        {
            @{
                ModuleName            = $graphModuleName
                ModuleVersion         = & $getPinnedVersion $requiredModules[$graphModuleName]
                AuthenticationVersion = $authenticationVersion
            }
        }
    )
}

Describe 'Microsoft Graph SDK pins in RequiredModules.psd1' -Tag Integration {
    # Every Microsoft Graph SDK module manifest requires one exact version of Microsoft.Graph.Authentication. A pin to
    # another version makes the restore save a second copy of Microsoft.Graph.Authentication, and importing the module
    # next to the pinned one fails with 'Assembly with same name is already loaded'.
    It "Should pin '<ModuleName>' to the version of 'Microsoft.Graph.Authentication'" -ForEach $graphModuleTestCases {
        $ModuleVersion | Should -Be $AuthenticationVersion -Because "the manifest of '$ModuleName' requires exactly that version of 'Microsoft.Graph.Authentication'"
    }
}

Describe 'Build tool versions in RequiredModules.psd1' {
    It 'Pins Pester to the version used by the build pipeline' {
        $requiredModules = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')

        $requiredModules['Pester'] | Should -Be '5.7.1'
    }
}

Describe 'Pinned Azure module loading' {
    It 'Loads Az.Accounts before Az.Resources using exact RequiredModules versions' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..\..\.build\ConfigDataPreparation.ps1'
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'Import-PowerShellDataFile -Path \(Join-Path -Path \$BuildRoot -ChildPath ''RequiredModules\.psd1''\)'
        $content | Should -Match 'foreach \(\$moduleName in ''Az\.Accounts'', ''Az\.Resources''\)'
        $content | Should -Match 'Import-Module -Name \$moduleName -RequiredVersion \$requiredVersion -ErrorAction Stop'
    }

    It 'Imports the pinned ExchangeOnlineManagement version during export initialization' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..\..\.build\InitLab.ps1'
        $content = Get-Content -Path $path -Raw

        $content | Should -Match 'Import-Module -Name ExchangeOnlineManagement -RequiredVersion \$exchangeOnlineManagementVersion -ErrorAction Stop'
        $content | Should -Match 'Import-Module -Name \$moduleToImport -RequiredVersion \$moduleVersion -PassThru -ErrorAction Stop'
    }
}

Describe 'Build runtime requirements' {
    It 'Requires PowerShell 7.4 or newer before importing build modules' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..\..\pipelines\scripts\TestBuildRuntime.ps1'
        $content = Get-Content -Path $path -Raw

        $content | Should -Match "\`$minimumPowerShellVersion = \[version\]'7\.4\.0'"
        $content | Should -Match 'Build preflight requires PowerShell \$minimumPowerShellVersion or newer'
    }
}

Describe 'Microsoft365DSC AADGroupsSettings null-safety workaround' -Tag Integration {
    It 'Preserves omitted values, handles missing boolean values, and is idempotent' {
        $requiredModules = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')
        $microsoft365DscPin = $requiredModules['Microsoft365DSC']
        $microsoft365DscVersion = if ($microsoft365DscPin -is [hashtable]) { $microsoft365DscPin.Version } else { [string]$microsoft365DscPin }
        $requiredModulesPath = Join-Path -Path $TestDrive -ChildPath 'RequiredModules'
        $moduleDirectory = Join-Path -Path $requiredModulesPath -ChildPath "Microsoft365DSC\$microsoft365DscVersion\Classes"
        $moduleFile = Join-Path -Path $moduleDirectory -ChildPath 'Part01.psm1'
        $patchScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\pipelines\scripts\PatchMicrosoft365DscAADGroupsSettings.ps1'
        $null = New-Item -Path $moduleDirectory -ItemType Directory -Force

        $source = @'
class AADGroupsSettings : M365DSCResourceBase
{
    [void] Set()
    {
        if ($this.Ensure -eq 'Present' -and $currentPolicy.Ensure -eq 'Absent')
        {
            $Policy = New-MgBetaDirectorySetting -TemplateId '62375ab9-6b52-47ed-826b-58e47e0e304b' | Out-Null
            $needToUpdate = $true
        }
                    EnableGroupCreation       = [Boolean]::Parse($valueEnableGroupCreation.Value)
                    EnableMIPLabels           = [Boolean]::Parse($valueEnableMIPLabels.Value)
                    AllowGuestsToBeGroupOwner = [Boolean]::Parse($valueAllowGuestsToBeGroupOwner.Value)
                    AllowGuestsToAccessGroups = [Boolean]::Parse($valueAllowGuestsToAccessGroups.Value)
                    AllowToAddGuests          = [Boolean]::Parse($valueAllowToAddGuests.Value)
                if ($property.Name -eq 'EnableGroupCreation')
                elseif ($property.Name -eq 'EnableMIPLabels')
                elseif ($property.Name -eq 'AllowGuestsToBeGroupOwner')
                elseif ($property.Name -eq 'AllowGuestsToAccessGroups')
                elseif ($property.Name -eq 'GuestUsageGuidelinesUrl')
                elseif ($property.Name -eq 'GroupCreationAllowedGroupId')
                elseif ($property.Name -eq 'AllowToAddGuests')
                elseif ($property.Name -eq 'UsageGuidelinesUrl')
                elseif ($property.Name -eq 'NewUnifiedGroupWritebackDefault')
                {
                    $entry = $newValues | Where-Object -FilterScript { $_.Name -eq 'NewUnifiedGroupWritebackDefault' }
                    $newUnifiedGroupWritebackDefaultValue = $this.NewUnifiedGroupWritebackDefault
                    if ($null -eq $newUnifiedGroupWritebackDefaultValue)
                    {
                        $newUnifiedGroupWritebackDefaultValue = $false
                    }
                    $entry.value = $newUnifiedGroupWritebackDefaultValue.ToString().ToLower()
                }
    }

    [bool] Test()
    {
    }
}
'@
        [System.IO.File]::WriteAllText($moduleFile, $source, [System.Text.UTF8Encoding]::new($true))

        & $patchScript -RequiredModulesPath $requiredModulesPath
        $patchedContent = Get-Content -Path $moduleFile -Raw

        $patchedContent | Should -Match 'EnableMIPLabels\s+= if \(\[System\.String\]::IsNullOrEmpty'
        $patchedContent | Should -Match 'property\.Name -eq ''EnableMIPLabels'' -and \$null -ne \$this\.EnableMIPLabels'
        $patchedContent | Should -Match 'property\.Name -eq ''NewUnifiedGroupWritebackDefault'' -and \$null -ne \$this\.NewUnifiedGroupWritebackDefault'
        $patchedContent | Should -Match '\$Policy = New-MgBetaDirectorySetting -TemplateId'
        $patchedContent | Should -Not -Match '\$Policy = New-MgBetaDirectorySetting -TemplateId .* \| Out-Null'

        & $patchScript -RequiredModulesPath $requiredModulesPath
        (Get-Content -Path $moduleFile -Raw) | Should -Be $patchedContent
    }

    It 'Fails without modifying the module when the pinned source no longer matches' {
        $requiredModules = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')
        $microsoft365DscPin = $requiredModules['Microsoft365DSC']
        $microsoft365DscVersion = if ($microsoft365DscPin -is [hashtable]) { $microsoft365DscPin.Version } else { [string]$microsoft365DscPin }
        $requiredModulesPath = Join-Path -Path $TestDrive -ChildPath 'ChangedSource'
        $moduleDirectory = Join-Path -Path $requiredModulesPath -ChildPath "Microsoft365DSC\$microsoft365DscVersion\Classes"
        $moduleFile = Join-Path -Path $moduleDirectory -ChildPath 'Part01.psm1'
        $patchScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\pipelines\scripts\PatchMicrosoft365DscAADGroupsSettings.ps1'
        $null = New-Item -Path $moduleDirectory -ItemType Directory -Force
        [System.IO.File]::WriteAllText($moduleFile, 'unrecognized source', [System.Text.UTF8Encoding]::new($true))

        { & $patchScript -RequiredModulesPath $requiredModulesPath } | Should -Throw
        (Get-Content -Path $moduleFile -Raw) | Should -Be 'unrecognized source'
    }

    It 'Patches the actual pinned class file without introducing syntax errors' {
        $requiredModules = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\RequiredModules.psd1')
        $microsoft365DscPin = $requiredModules['Microsoft365DSC']
        $microsoft365DscVersion = if ($microsoft365DscPin -is [hashtable]) { $microsoft365DscPin.Version } else { [string]$microsoft365DscPin }
        $sourceModuleFile = Join-Path -Path $PSScriptRoot -ChildPath "..\..\output\RequiredModules\Microsoft365DSC\$microsoft365DscVersion\Classes\Part01.psm1"
        $requiredModulesPath = Join-Path -Path $TestDrive -ChildPath 'ActualModuleCopy'
        $moduleFile = Join-Path -Path $requiredModulesPath -ChildPath "Microsoft365DSC\$microsoft365DscVersion\Classes\Part01.psm1"
        $patchScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\pipelines\scripts\PatchMicrosoft365DscAADGroupsSettings.ps1'
        $null = New-Item -Path (Split-Path -Path $moduleFile -Parent) -ItemType Directory -Force
        Copy-Item -Path $sourceModuleFile -Destination $moduleFile -ErrorAction Stop

        & $patchScript -RequiredModulesPath $requiredModulesPath

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($moduleFile, [ref]$tokens, [ref]$parseErrors)
        $syntaxErrors = @($parseErrors | Where-Object -FilterScript { $_.ErrorId -ne 'TypeNotFound' })
        $syntaxErrors | Should -BeNullOrEmpty
        (Get-Content -Path $moduleFile -Raw) | Should -Match 'property\.Name -eq ''EnableMIPLabels'' -and \$null -ne \$this\.EnableMIPLabels'
    }

    It 'Runs the workaround before copying modules to the worker module path' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..\..\.build\DscConfigurationTasks.ps1'
        $content = Get-Content -Path $path -Raw
        $patchIndex = $content.IndexOf('PatchMicrosoft365DscAADGroupsSettings.ps1')
        $copyIndex = $content.IndexOf('Copying modules from')

        $patchIndex | Should -BeGreaterThan -1
        $copyIndex | Should -BeGreaterThan $patchIndex
    }

    It 'Waits for a remote DSC LCM to become idle before validating the deployment' {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..\..\.build\DscConfigurationTasks.ps1'
        $content = Get-Content -Path $path -Raw
        $lcmWaitIndex = $content.IndexOf('Get-DscLocalConfigurationManager -CimSession $cimSession')
        $testIndex = $content.IndexOf('Test-DscConfiguration -CimSession $cimSession')

        $lcmWaitIndex | Should -BeGreaterThan -1
        $testIndex | Should -BeGreaterThan $lcmWaitIndex
        $content | Should -Match '\$lcmState -eq ''Busy'''
        $content | Should -Match 'AddMinutes\(10\)'
        $content | Should -Match 'cmdlet is in progress and must return before Test-DscConfiguration can be invoked'
        $content | Should -Match 'A DSC operation is still in progress'
        $content | Should -Not -Match 'Test-DscConfiguration -ComputerName'
    }
}
