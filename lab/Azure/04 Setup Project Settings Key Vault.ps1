[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
$requiredModulesPath = Join-Path -Path $repositoryRoot -ChildPath 'output\RequiredModules'
$requiredModuleVersions = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $repositoryRoot -ChildPath 'RequiredModules.psd1')
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = "$requiredModulesPath;$env:PSModulePath"
}

Import-Module -Name Az.Accounts -RequiredVersion $requiredModuleVersions['Az.Accounts'] -ErrorAction Stop
Import-Module -Name Az.KeyVault -RequiredVersion $requiredModuleVersions['Az.KeyVault'] -ErrorAction Stop
Import-Module -Name Az.Resources -RequiredVersion $requiredModuleVersions['Az.Resources'] -ErrorAction Stop
Import-Module -Name Datum -ErrorAction Stop
Import-Module -Name Datum.ProtectedData -ErrorAction Stop
Import-Module -Name $PSScriptRoot\AzHelpers.psm1 -Force -ErrorAction Stop

function Get-HttpStatusCode
{
    param
    (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode)
    {
        return [int]$response.StatusCode
    }

    return 0
}

function Test-AzureDevOpsPersonalAccessToken
{
    param
    (
        [Parameter(Mandatory)]
        [string]$OrganizationName,

        [Parameter(Mandatory)]
        [securestring]$PersonalAccessToken
    )

    $plainToken = ConvertTo-M365DscPlainText -Value $PersonalAccessToken
    $authorization = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plainToken"))
    $uri = "https://dev.azure.com/$OrganizationName/_apis/projects?api-version=7.1"
    try
    {
        Invoke-RestMethod `
            -Uri $uri `
            -Method Get `
            -Headers @{ Authorization = "Basic $authorization" } `
            -TimeoutSec 30 `
            -ErrorAction Stop | Out-Null
        return $true
    }
    catch
    {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 401)
        {
            return $false
        }
        if ($statusCode -eq 403)
        {
            throw "The PAT is recognized by Azure DevOps organization '$OrganizationName' but lacks permission to list projects. Create a PAT with the permissions required by this workshop."
        }
        throw "Could not validate the PAT against Azure DevOps organization '$OrganizationName' (HTTP status $statusCode). $($_.Exception.Message)"
    }
}

function Assert-BuildAgentPassword
{
    param
    (
        [Parameter(Mandatory)]
        [securestring]$Password
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try
    {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $characterClassCount = @(
            [bool]($plainPassword -cmatch '[A-Z]')
            [bool]($plainPassword -cmatch '[a-z]')
            [bool]($plainPassword -match '\d')
            [bool]($plainPassword -match '[^A-Za-z0-9]')
        ).Where({ $_ }).Count
        if ($plainPassword.Length -lt 12 -or $characterClassCount -lt 3)
        {
            throw 'The build-agent password must be at least 12 characters and include at least three of uppercase, lowercase, numeric, and special characters.'
        }
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

$datum = New-DatumStructure -DefinitionFile (Join-Path -Path $repositoryRoot -ChildPath 'source\Datum.yml')
$projectSettings = $datum.Global.ProjectSettings
$organizationName = [string]$projectSettings.OrganizationName
if ([string]::IsNullOrWhiteSpace($organizationName) -or $organizationName -notmatch '^[A-Za-z0-9._-]+$')
{
    throw "Set a valid Azure DevOps OrganizationName in 'source/Global/ProjectSettings.yml'."
}

$environmentName = [string]$projectSettings.CredentialVaultEnvironment
$environment = $datum.Global.Azure.Environments[$environmentName]
if ($null -eq $environment)
{
    throw "CredentialVaultEnvironment '$environmentName' is not configured in 'source/Global/Azure.yml'."
}

Write-M365DscEnvironmentContext -EnvironmentName $environmentName -TenantName $environment.AzTenantName -Operation 'Signing in to configure the project credential vault'
$context = Connect-M365DscEnvironmentContext -TenantName ([string]$environment.AzTenantName)
$networkParameters = Get-M365DscKeyVaultNetworkParameters -Datum $datum -EnvironmentName $environmentName
$vault = Initialize-M365DscKeyVault `
    -ProjectName ([string]$projectSettings.ProjectName) `
    -EnvironmentName $environmentName `
    -TenantId ([string]$context.Tenant.Id) `
    -SubscriptionId ([string]$context.Subscription.Id) `
    -Location ([string]$projectSettings.BuildAgents.AzureLocation) `
    @networkParameters `
    -ErrorAction Stop
if ($null -eq $vault)
{
    throw "Failed to initialize the project-settings Key Vault for environment '$environmentName'."
}

Write-M365DscEnvironmentContext -EnvironmentName $environmentName -TenantName $environment.AzTenantName `
    -TenantId $context.Tenant.Id -SubscriptionId $context.Subscription.Id -KeyVaultName $vault.VaultName `
    -Operation 'Configuring project credential storage'

$operatorAccount = [string]$context.Account.Id
if ([string]::IsNullOrWhiteSpace($operatorAccount))
{
    throw 'The interactive Azure session did not identify the signed-in operator.'
}
$operator = Get-AzADUser -UserPrincipalName $operatorAccount -ErrorAction Stop
if (-not $operator.Id)
{
    throw "Could not resolve the signed-in operator '$operatorAccount' to an Entra user object."
}
Ensure-M365DscKeyVaultRoleAssignment `
    -VaultResourceId $vault.ResourceId `
    -PrincipalId $operator.Id `
    -RoleDefinitionName 'Key Vault Secrets Officer' `
    -ErrorAction Stop

Wait-M365DscKeyVaultAccess -VaultName $vault.VaultName -EnvironmentName $environmentName -ErrorAction Stop

$patSecretName = Get-M365DscKeyVaultSecretName -IdentityName 'ProjectSettings' -CredentialType 'personal-access-token'
$passwordSecretName = Get-M365DscKeyVaultSecretName -IdentityName 'ProjectSettings' -CredentialType 'build-agent-password'
$personalAccessToken = $null
$buildAgentPassword = $null
try
{
    if (Test-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $patSecretName)
    {
        $personalAccessToken = Get-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $patSecretName
        if (-not (Test-AzureDevOpsPersonalAccessToken -OrganizationName $organizationName -PersonalAccessToken $personalAccessToken))
        {
            Write-Warning "The PAT stored in Key Vault is no longer accepted by '$organizationName'; provide a replacement."
            $personalAccessToken.Dispose()
            $personalAccessToken = $null
        }
    }

    if (-not $personalAccessToken)
    {
        $tokenPage = "https://dev.azure.com/$organizationName/_usersSettings/tokens"
        Write-Host "Opening the PAT management page for Azure DevOps organization '$organizationName'." -ForegroundColor Cyan
        Start-Process -FilePath $tokenPage -ErrorAction Stop
        $personalAccessToken = Read-Host -Prompt "Create a PAT for '$organizationName', then paste it here" -AsSecureString
        if ($personalAccessToken.Length -eq 0)
        {
            throw 'A non-empty Azure DevOps PAT is required.'
        }
        if (-not (Test-AzureDevOpsPersonalAccessToken -OrganizationName $organizationName -PersonalAccessToken $personalAccessToken))
        {
            throw "The supplied PAT was rejected by Azure DevOps organization '$organizationName'. Check the token and its expiration, then rerun the bootstrap."
        }

        Set-M365DscKeyVaultSecret `
            -VaultName $vault.VaultName `
            -Name $patSecretName `
            -SecretValue $personalAccessToken `
            -ContentType 'text/plain' `
            -Overwrite `
            -ErrorAction Stop
    }

    if (Test-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $passwordSecretName)
    {
        $buildAgentPassword = Get-M365DscKeyVaultSecret -VaultName $vault.VaultName -Name $passwordSecretName
        Assert-BuildAgentPassword -Password $buildAgentPassword
    }
    else
    {
        $buildAgentPassword = Read-Host -Prompt 'Enter the build-agent password to store in Key Vault' -AsSecureString
        Assert-BuildAgentPassword -Password $buildAgentPassword
        Set-M365DscKeyVaultSecret `
            -VaultName $vault.VaultName `
            -Name $passwordSecretName `
            -SecretValue $buildAgentPassword `
            -ContentType 'text/plain' `
            -ErrorAction Stop
    }

    Write-Host "Project credentials are stored in Key Vault '$($vault.VaultName)'. They were not written to ProjectSettings.yml." -ForegroundColor Green
}
finally
{
    if ($personalAccessToken)
    {
        $personalAccessToken.Dispose()
    }
    if ($buildAgentPassword)
    {
        $buildAgentPassword.Dispose()
    }
}
