<#
    .SYNOPSIS
        Prepares the local machine for the lab scripts of the Microsoft365DscWorkshop.

    .DESCRIPTION
        This is the first script to run when following the guide in 'docs/GettingStarted Azure.md'.
        It performs these steps:

        - Verifies that the session is elevated and that the repository is a clone of an
          Azure DevOps project.
        - Restores the default module paths, see 'Restore-DefaultModulePath'.
        - Writes the project name into 'source/Global/ProjectSettings.yml'.
        - Installs 'VSTeam' and 'Az.Accounts' with pinned versions for all users.
        - Removes module copies that shadow a newer installation, see 'Resolve-ShadowedModule'.
        - Enables remoting for the lab host.
        - Sets the git user data and the Azure PowerShell defaults the other lab scripts rely on.

        Run it from an elevated PowerShell session in the root of the cloned repository.

    .EXAMPLE
        & '.\lab\Azure\00 Prep.ps1'

        Runs all preparation steps.

    .EXAMPLE
        & '.\lab\Azure\00 Prep.ps1' -ProjectName 'Workshop Dev'

        Sets the Azure DevOps project name explicitly while preparing the machine.

    .NOTES
        Elevation is mandatory as the script installs modules with the scope 'AllUsers'.

    .LINK
        https://github.com/dsccommunity/Microsoft365DscWorkshop
#>

[CmdletBinding()]

param
(
    [Parameter()]
    [string]$ProjectName
)

function Restore-DefaultModulePath
{
    <#
        .SYNOPSIS
            Puts the default module paths back into 'PSModulePath' of the current session.

        .DESCRIPTION
            The Sampler build task 'Set_PSModulePath' is configured in 'build.yaml' with
            'RemovePersonal' and 'RemoveProgramFiles', so a session that has run 'build.ps1'
            no longer sees the modules installed for the current user or for all users. In
            such a session this script reinstalls modules although they are present, and
            the commands are still not recognized afterwards.

            This function prepends the default paths of the running PowerShell edition to
            'PSModulePath'. Paths a build has added, like 'output/RequiredModules', are kept
            but move behind the default ones. The change only affects the current process.

        .EXAMPLE
            Restore-DefaultModulePath

            Returns '$true' if paths were missing and have been restored.

        .OUTPUTS
            System.Boolean
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    param ()

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
    $normalizedModulePaths = $currentModulePaths | ForEach-Object { $_.TrimEnd('\') }
    $missingModulePaths = $defaultModulePaths | Where-Object { $_.TrimEnd('\') -notin $normalizedModulePaths }

    if (-not $missingModulePaths)
    {
        return $false
    }

    $env:PSModulePath = (@($defaultModulePaths) + $currentModulePaths | Select-Object -Unique) -join [System.IO.Path]::PathSeparator

    return $true
}

function Resolve-ShadowedModule
{
    <#
        .SYNOPSIS
            Removes module versions that keep the newest installed version from being imported.

        .DESCRIPTION
            PowerShell does not import the highest installed version of a module. It walks
            'PSModulePath' from left to right and imports the highest version found in the first
            path that contains the module. An outdated copy in an earlier path therefore shadows
            a newer copy in a later path. This is a common cause of the Azure PowerShell error
            'An earlier version of Az.Accounts is imported in the current PowerShell session',
            which no amount of restarting the script can fix.

            This function deletes every copy of the module that is older than the newest installed
            copy and that lives in a 'PSModulePath' entry preceding the one holding the newest
            copy. Copies in later paths are kept as they cannot shadow anything and may be the
            only ones a different PowerShell edition can see.

        .PARAMETER Name
            The name of the module to inspect, for example 'Az.Accounts'.

        .EXAMPLE
            Resolve-ShadowedModule -Name Az.Accounts

            Removes an 'Az.Accounts' copy in the CurrentUser scope if a newer version is installed
            in the AllUsers scope.

        .NOTES
            Only the four standard module scopes are cleaned up. A repository-local module folder
            like 'output/RequiredModules', which a Sampler build adds to 'PSModulePath', is never
            touched.

            Deleting a module fails while another PowerShell session holds its assemblies open.
            The caller is expected to catch that terminating error and to ask the user to close
            the other sessions.
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$RequiredVersion
    )

    $standardModulePaths = @(
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'PowerShell\Modules'
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WindowsPowerShell\Modules'
        Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules'
        Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'
    )
    $modulePaths = $env:PSModulePath -split [System.IO.Path]::PathSeparator |
        Where-Object { $_ -and $_.TrimEnd('\') -in $standardModulePaths }

    $installedModules = Get-Module -Name $Name -ListAvailable
    if (-not $installedModules)
    {
        return
    }

    if ($RequiredVersion)
    {
        $preferredModule = $installedModules |
            Where-Object { $_.Version -eq $RequiredVersion } |
            Sort-Object -Property Version |
            Select-Object -Last 1
    }
    else
    {
        $preferredModule = $installedModules | Sort-Object -Property Version | Select-Object -Last 1
    }

    if (-not $preferredModule)
    {
        return
    }

    #PowerShell imports from the first path in 'PSModulePath' containing the module, not from the one with the highest version.
    foreach ($modulePath in $modulePaths)
    {
        if ($preferredModule.ModuleBase.StartsWith($modulePath, [StringComparison]::OrdinalIgnoreCase))
        {
            break
        }

        $shadowingModules = $installedModules |
            Where-Object {
                $isInModulePath = $_.ModuleBase.StartsWith($modulePath, [StringComparison]::OrdinalIgnoreCase)
                $isShadowing = if ($RequiredVersion) { $_.Version -ne $preferredModule.Version } else { $_.Version -lt $preferredModule.Version }
                $isInModulePath -and $isShadowing
            }

        foreach ($shadowingModule in $shadowingModules)
        {
            Write-Host "Removing '$Name' version '$($shadowingModule.Version)' from '$($shadowingModule.ModuleBase)' as it shadows version '$($preferredModule.Version)'."
            Remove-Item -Path $shadowingModule.ModuleBase -Recurse -Force -ErrorAction Stop

            $moduleRoot = Split-Path -Path $shadowingModule.ModuleBase -Parent
            if (-not (Get-ChildItem -Path $moduleRoot -ErrorAction SilentlyContinue))
            {
                Remove-Item -Path $moduleRoot -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host 'Checking if the script is running with administrative privileges...' -NoNewline
$currentIdentity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentIdentity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host
    Write-Host 'This script installs modules for all users. Please start PowerShell as administrator and run the script again.' -ForegroundColor Red
    return
}
else
{
    Write-Host 'ok.'
}

Write-Host 'Checking the module path of this session...' -NoNewline
if (Restore-DefaultModulePath)
{
    Write-Host 'restored the default module paths that a build had removed.'
}
else
{
    Write-Host 'ok.'
}

Write-Host 'Checking if the script is running in a git repository...' -NoNewline
$projectUrl = git remote get-url origin *>&1

if ($projectUrl -like '*fatal: not a git repository*' -and $LASTEXITCODE -eq 128)
{
    Write-Host 'Not working in a git repository. Please run the script in a git repository.'
    return
}
else
{
    Write-Host 'ok.'
}

Write-Host 'Checking if the script is running in an Azure DevOps repository...' -NoNewline
if ($projectUrl -notmatch '^https:\/\/(?:[^\/@]+@)?dev\.azure\.com\/[^\/]+\/[^\/]+\/_git\/[^\/]+\/?$')
{
    Write-Host 'The script is not running in an Azure DevOps repository. Please run the script in an Azure DevOps repository.'
    return
}
else
{
    Write-Host 'ok.'
}

$projectSettingsPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Global\ProjectSettings.yml'
$projectSettings = Get-Content -Path $projectSettingsPath -Raw
$resolvedProjectName = if ($ProjectName)
{
    $ProjectName
}
elseif ($projectSettings -match '(?m)^ProjectName:\s*<ProjectName>\s*$')
{
    Split-Path -Path (git rev-parse --show-toplevel) -Leaf
}

if ($resolvedProjectName)
{
    Write-Host "Updating the project name in the 'ProjectSettings.yml' file"
    $quotedProjectName = $resolvedProjectName.Replace("'", "''").Replace('$', '$$')
    $projectSettings = [regex]::Replace($projectSettings, '(?m)^ProjectName:\s*.*$', "ProjectName: '$quotedProjectName'")
    Set-Content -Path $projectSettingsPath -Value $projectSettings -Encoding utf8
}

$requiredModules = @{
    VSTeam        = '7.15.2'
    'Az.Accounts' = '5.3.2'
}

foreach ($module in $requiredModules.GetEnumerator())
{
    $requiredVersion, $prereleaseTag = $module.Value -split '-', 2

    $param = @{
        Name               = $module.Name
        Scope              = 'AllUsers'
        Force              = $true
        AllowClobber       = $true
        SkipPublisherCheck = $true
    }
    if ($prereleaseTag)
    {
        $param.AllowPrerelease = $true
    }
    if ($module.Value -ne 'latest')
    {
        $param.RequiredVersion = $module.Value
    }

    $moduleInfo = Get-Module -Name $module.Name -ListAvailable
    if ($module.Value -ne 'latest')
    {
        #'Version' never carries the prerelease tag, hence both parts are compared separately.
        $moduleInfo = $moduleInfo | Where-Object {
            $_.Version -eq $requiredVersion -and [string]$_.PrivateData.PSData.Prerelease -eq [string]$prereleaseTag
        }
    }

    if ($moduleInfo)
    {
        Write-Host "Module '$($module.Name)' with version '$($module.Value)' is already installed"
        continue
    }

    Write-Host "Installing module '$($module.Name)' with version '$($module.Value)'"
    try
    {
        Install-Module @param -ErrorAction Stop
    }
    catch
    {
        Write-Host "Installing the module '$($module.Name)' failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'PowerShellGet also reports missing administrator rights when the module files are locked by another PowerShell session. Please close all other PowerShell sessions and run the script again.' -ForegroundColor Red
        return
    }
}

Write-Host 'Looking for modules that shadow a newer installation.'
try
{
    foreach ($moduleName in $requiredModules.Keys)
    {
        $requiredVersion = ($requiredModules[$moduleName] -split '-', 2)[0]
        if ($requiredVersion -eq 'latest')
        {
            Resolve-ShadowedModule -Name $moduleName
        }
        else
        {
            Resolve-ShadowedModule -Name $moduleName -RequiredVersion $requiredVersion
        }
    }
}
catch
{
    Write-Host "Removing a shadowing module failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'The module files are most likely in use. Please close all other PowerShell sessions and run the script again.' -ForegroundColor Red
    return
}

$loadedAzAccounts = Get-Module -Name Az.Accounts | Sort-Object -Property Version | Select-Object -Last 1
$requiredAzAccounts = Get-Module -Name Az.Accounts -ListAvailable |
    Where-Object { $_.Version -eq [version]'5.3.2' } |
    Select-Object -First 1
if (-not $requiredAzAccounts)
{
    Write-Host "Az.Accounts 5.3.2 is not installed. Close the other PowerShell sessions and run the preparation script again." -ForegroundColor Red
    return
}

if ($loadedAzAccounts -and $loadedAzAccounts.Version -ne [version]'5.3.2')
{
    Write-Host "Az.Accounts version '$($loadedAzAccounts.Version)' is already loaded. Close this PowerShell session and run the script again." -ForegroundColor Red
    return
}

if (-not $loadedAzAccounts)
{
    $assemblyLoading = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Azure.PowerShell.AssemblyLoading' } |
        Select-Object -First 1
    if ($assemblyLoading)
    {
        Write-Host "The Az.Accounts assembly is already loaded in this PowerShell session. Close this session, open a new elevated PowerShell session, and run the preparation script again." -ForegroundColor Red
        return
    }

    try
    {
        Import-Module -Name Az.Accounts -RequiredVersion '5.3.2' -ErrorAction Stop
    }
    catch
    {
        Write-Host "Importing Az.Accounts 5.3.2 failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}

if (-not (git config --get user.email))
{
    $emailAddress = Read-Host -Prompt 'The git user email is not set. Please enter your email address'
    git config user.email $emailAddress
}

if (-not (git config --get user.name))
{
    $yourName = Read-Host -Prompt 'The git user name is not set. Please enter your / a name'
    git config user.name $yourName
}
else
{
    Write-Host 'Git user name is already set.'
}

Write-Host 'Disabling web account manager login for Azure.'
try
{
    Set-AzConfig -EnableLoginByWam $false -ErrorAction Stop | Out-Null
    Set-AzConfig -DisplaySecretsWarning $false -ErrorAction Stop | Out-Null
    Set-Item -Path Env:\AZURE_CLIENTS_SHOW_SECRETS_WARNING -Value $false -ErrorAction Stop
}
catch
{
    Write-Host "Configuring Azure PowerShell failed: $($_.Exception.Message)" -ForegroundColor Red
    return
}

Write-Host 'The preparation is done. You can now continue with the next steps.'
