task InitLab {

    $requiredModuleVersions = Import-PowerShellDataFile -Path (Join-Path -Path $ProjectPath -ChildPath 'RequiredModules.psd1')
    $exchangeOnlineManagementVersion = $requiredModuleVersions['ExchangeOnlineManagement']
    if ($exchangeOnlineManagementVersion -is [hashtable])
    {
        $exchangeOnlineManagementVersion = $exchangeOnlineManagementVersion.Version
    }

    if (-not $exchangeOnlineManagementVersion -or $exchangeOnlineManagementVersion -eq 'latest')
    {
        throw "Module 'ExchangeOnlineManagement' must have an explicit version in RequiredModules.psd1."
    }

    #workaround for https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3331
    $dummyCred = [pscredential]::new('dummy', ('123' | ConvertTo-SecureString -AsPlainText -Force))
    Import-Module -Name ExchangeOnlineManagement -RequiredVersion $exchangeOnlineManagementVersion -ErrorAction Stop
    try
    {
        Connect-ExchangeOnline -UserPrincipalName dummy@contoso.com -Credential $dummyCred -ErrorAction Ignore | Out-Null
    }
    catch
    {
        # Exception is expected
    }

    Write-Host "Importing module 'AzHelpers' from path '$ProjectPath\lab\AutomatedLab\AzHelpers.psm1'." -ForegroundColor Yellow
    Import-Module -Name $ProjectPath\lab\AutomatedLab\AzHelpers.psm1 -Force

    Write-Host "Importing module 'CertHelpers' from path '$ProjectPath\lab\AutomatedLab\CertHelpers.psm1'." -ForegroundColor Yellow
    Import-Module -Name $ProjectPath\lab\AutomatedLab\CertHelpers.psm1 -Force

    Write-Host "Importing module 'M365DscHelpers' from path '$ProjectPath\lab\AutomatedLab\M365DscHelpers.psm1'." -ForegroundColor Yellow
    Import-Module -Name $ProjectPath\lab\AutomatedLab\M365DscHelpers.psm1 -Force

    if ($PSVersionTable.PSEdition -eq 'Core')
    {
        Write-Host "Importing module 'MofConvert' from path '$ProjectPath\export\MofConvert.psm1'." -ForegroundColor Yellow
        Import-Module -Name $ProjectPath\export\MofConvert.psm1 -Force
    }
    else
    {
        Write-Host "The module 'MofConvert.psm1' cannot be loaded on Windows PowerShell."
    }

    if (Get-Module -Name AutomatedLab -ListAvailable)
    {
        Write-Host "Importing module 'AutomatedLab'..." -NoNewline -ForegroundColor Yellow

        try
        {
            #Import-Module -Name AutomatedLab -Force -ErrorAction Stop
        }
        catch
        {
            Write-Host 'failed, retrying...' -NoNewline -ForegroundColor Yellow
            #Import-Module -Name AutomatedLab -Force -ErrorAction Stop
            Write-Host 'succeeded.' -ForegroundColor Yellow
        }
    }
    else
    {
        Write-Host "Module 'AutomatedLab' is not installed, module will not be imported." -ForegroundColor Yellow
    }

    Write-Host ''

    $modulesToImport = @(
        'ExchangeOnlineManagement',
        'Az.Accounts',
        'Az.Resources',
        'Az.Compute',
        'Az.ManagedServiceIdentity',
        'Microsoft365DSC'
    )

    foreach ($moduleToImport in $modulesToImport)
    {
        $moduleVersion = $requiredModuleVersions[$moduleToImport]
        if ($moduleVersion -is [hashtable])
        {
            $moduleVersion = $moduleVersion.Version
        }

        if (-not $moduleVersion -or $moduleVersion -eq 'latest')
        {
            throw "Module '$moduleToImport' must have an explicit version in RequiredModules.psd1."
        }

        $module = Import-Module -Name $moduleToImport -RequiredVersion $moduleVersion -PassThru -ErrorAction Stop
        Write-Host "'$module' pinned module version $($module.Version) is imported." -ForegroundColor Yellow

    }

}
