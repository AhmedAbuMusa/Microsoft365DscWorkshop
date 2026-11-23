function Get-M365DscSecretBackend
{
    param([object]$Datum)
    $backend = if ($env:M365DSC_SECRET_BACKEND) { $env:M365DSC_SECRET_BACKEND }
        elseif ($Datum -and $Datum.Global.ProjectSettings.SecretStorage) { $Datum.Global.ProjectSettings.SecretStorage }
        else { 'KeyVault' }
    if ($backend -notin 'KeyVault','Kdbx') { throw "Unknown secret backend '$backend'. Choose KeyVault or Kdbx." }
    return $backend
}

function Import-KdbxBackend
{
    Import-Module $PSScriptRoot\Kdbx\Store.psm1 -ErrorAction Stop
}

function Get-M365DscProjectConfiguration
{
    param([Parameter(Mandatory)][object]$Datum)
    if ((Get-M365DscSecretBackend $Datum) -eq 'Kdbx')
    {
        Import-KdbxBackend
        return Get-M365DscKdbxProjectSettings -Datum $Datum
    }
    return $Datum
}

function Get-M365DscProjectSecrets
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Datum,
        [ValidateSet('personal-access-token','build-agent-password')]
        [string[]]$CredentialType = @('personal-access-token','build-agent-password')
    )
    if ((Get-M365DscSecretBackend $Datum) -eq 'Kdbx')
    {
        return Get-M365DscProjectConfiguration -Datum $Datum
    }
    return Get-M365DscProjectSettingsFromKeyVault -Datum $Datum -CredentialType $CredentialType
}

function Update-M365DscEnvironmentMetadata
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Datum,
        [Parameter(Mandatory)][string]$ProjectName,
        [string[]]$EnvironmentName,
        [switch]$ManagedIdentity,
        [switch]$IncludeCredentials,
        [string[]]$CredentialIdentityName
    )
    if ((Get-M365DscSecretBackend $Datum) -eq 'Kdbx')
    {
        if ($ManagedIdentity) { throw 'KDBX operator storage cannot be unlocked using a managed identity. Use native pipeline metadata on workers.' }
        Import-KdbxBackend
        $Datum = Get-M365DscKdbxProjectSettings -Datum $Datum
        return Update-M365DscDatumFromKdbx -Datum $Datum -EnvironmentName $EnvironmentName `
            -IncludeCredentials:$IncludeCredentials -CredentialIdentityName $CredentialIdentityName
    }
    return Update-M365DscDatumFromKeyVault @PSBoundParameters
}

function Select-M365DscSecretBackend
{
    param([ValidateSet('KeyVault','Kdbx')][string]$Backend, [object]$Datum)
    if ($Backend) { return $Backend }
    $default = Get-M365DscSecretBackend -Datum $Datum
    $answer = Read-Host "Secret storage: [1] Azure Key Vault (public endpoint permitted) [2] KDBX (portable, no vault). Default: $default"
    switch ($answer.Trim())
    {
        '' { return $default }
        '1' { return 'KeyVault' }
        '2' { return 'Kdbx' }
        'KeyVault' { return 'KeyVault' }
        'Kdbx' { return 'Kdbx' }
        default { throw 'Choose 1/KeyVault or 2/Kdbx. No backend was selected.' }
    }
}

function Set-M365DscSecretBackendSetting
{
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('KeyVault','Kdbx')][string]$Backend)
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $pattern = '(?m)^SecretStorage:[^\r\n]*'
    if ([regex]::Matches($content, $pattern).Count -gt 1) { throw 'ProjectSettings.yml contains duplicate SecretStorage settings.' }
    $updated = if ($content -match $pattern) { [regex]::Replace($content, $pattern, "SecretStorage: $Backend") }
        else { "SecretStorage: $Backend`r`n$content" }
    if ($updated -ne $content) { [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false)) }
}

Export-ModuleMember -Function Get-M365DscSecretBackend,Get-M365DscProjectConfiguration,Get-M365DscProjectSecrets,Update-M365DscEnvironmentMetadata,Select-M365DscSecretBackend,Set-M365DscSecretBackendSetting
