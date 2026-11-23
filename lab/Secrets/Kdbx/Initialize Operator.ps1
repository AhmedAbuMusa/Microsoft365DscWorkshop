[CmdletBinding()]
param(
    [string]$Path = $env:M365DSC_SECRET_STORE,
    [string]$ProjectSettingsPath = "$PSScriptRoot\..\..\..\source\Global\ProjectSettings.yml"
)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Restore Dependencies.ps1"
Import-Module $PSScriptRoot\Store.psm1 -ErrorAction Stop
if (-not $Path) { $Path = Join-Path $env:LOCALAPPDATA 'Microsoft365DscWorkshop\Secrets\operator.kdbx' }
if (Test-Path -LiteralPath $Path) { Open-M365DscSecretStore -Path $Path }
else
{
    $password = Read-Host 'New KDBX passphrase (at least 16 characters)' -AsSecureString
    $confirmation = Read-Host 'Confirm KDBX passphrase' -AsSecureString
    try
    {
        if ([Net.NetworkCredential]::new('', $password).Password -cne [Net.NetworkCredential]::new('', $confirmation).Password)
        {
            throw 'The passphrases do not match.'
        }
        Open-M365DscSecretStore -Path $Path -Password $password -Create
    }
    finally { $password.Dispose(); $confirmation.Dispose() }
}
if (Test-M365DscSecret 'ProjectSettings') { return }
Import-Module powershell-yaml -ErrorAction Stop
$configuredSettings = Get-Content -LiteralPath $ProjectSettingsPath -Raw -ErrorAction Stop |
    ConvertFrom-Yaml -ErrorAction Stop
if ($configuredSettings -isnot [Collections.IDictionary]) { throw 'ProjectSettings.yml must contain a settings mapping.' }
$configuredWorker = if ($null -eq $configuredSettings.BuildAgents) { @{} } else { $configuredSettings.BuildAgents }
if ($configuredWorker -isnot [Collections.IDictionary]) { throw 'BuildAgents in ProjectSettings.yml must contain a settings mapping.' }

function Read-KdbxInitialSetting
{
    param([object]$Value, [string]$Prompt)
    if ([string]::IsNullOrWhiteSpace([string]$Value) -or [string]$Value -match '^\s*<.*>\s*$')
    {
        $Value = Read-Host $Prompt
    }
    if ([string]::IsNullOrWhiteSpace([string]$Value) -or [string]$Value -match '^\s*<.*>\s*$')
    {
        throw "A real value for '$Prompt' is required."
    }
    return [string]$Value
}

$settings = [ordered]@{ SecretStorage = 'Kdbx' }
foreach ($field in 'OrganizationName','ProjectName','RepositoryName','GitHubRepositoryUrl','LocalPath','GitUserName','GitUserEmail','AgentPoolName')
{
    $value = Read-KdbxInitialSetting -Value $configuredSettings[$field] -Prompt "Private project setting: $field"
    $settings[$field] = $value
}
$count = 0
$agentCount = Read-KdbxInitialSetting -Value $configuredSettings.NumbertOfBuildAgents -Prompt 'Agents per environment'
if (-not [int]::TryParse($agentCount, [ref]$count) -or $count -lt 1)
{
    throw 'Agents per environment must be a positive integer.'
}
$settings.NumbertOfBuildAgents = $count
$settings.BuildAgents = [ordered]@{}
foreach ($field in 'UserName','AzureLocation','AzureRoleSize')
{
    $value = Read-KdbxInitialSetting -Value $configuredWorker[$field] -Prompt "Worker setting: $field"
    $settings.BuildAgents[$field] = $value
}
$pat = Read-Host 'Short-lived bootstrap Azure DevOps PAT' -AsSecureString
$vmPassword = $null
try
{
    $configuredPassword = [string]$configuredWorker.Password
    if ([string]::IsNullOrWhiteSpace($configuredPassword) -or $configuredPassword -match '^\s*<.*>\s*$')
    {
        $vmPassword = Read-Host 'Worker VM administrator password' -AsSecureString
    }
    else
    {
        $vmPassword = [securestring]::new()
        foreach ($character in $configuredPassword.ToCharArray()) { $vmPassword.AppendChar($character) }
        $vmPassword.MakeReadOnly()
    }
    $plainPassword = [Net.NetworkCredential]::new('', $vmPassword).Password
    $classes = @([bool]($plainPassword -cmatch '[A-Z]'), [bool]($plainPassword -cmatch '[a-z]'),
        [bool]($plainPassword -match '\d'), [bool]($plainPassword -match '[^A-Za-z0-9]')).Where({ $_ }).Count
    if ($vmPassword.Length -lt 12 -or $classes -lt 3) { throw 'Use a VM password of at least 12 characters with three character classes.' }
    if (-not $pat.Length) { throw 'A non-empty bootstrap PAT is required.' }
    $plainToken = [Net.NetworkCredential]::new('', $pat).Password
    $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$plainToken"))
    Invoke-RestMethod -Uri "https://dev.azure.com/$($settings.OrganizationName)/_apis/projects?api-version=7.1" `
        -Headers @{ Authorization = "Basic $authorization" } -TimeoutSec 30 -ErrorAction Stop | Out-Null
    $settings.PersonalAccessToken = $plainToken
    $settings.BuildAgents.Password = $plainPassword
    Set-M365DscSecretJson -Name 'ProjectSettings' -Value $settings
    Write-Host 'Private settings and credentials saved in the encrypted operator database; no Key Vault was accessed.'
}
finally
{
    $pat.Dispose()
    if ($vmPassword) { $vmPassword.Dispose() }
    $configuredPassword = $null
    $configuredSettings = $null
    $configuredWorker = $null
    $plainToken = $null
    $plainPassword = $null
    $authorization = $null
    $settings.PersonalAccessToken = $null
    $settings.BuildAgents.Password = $null
}
