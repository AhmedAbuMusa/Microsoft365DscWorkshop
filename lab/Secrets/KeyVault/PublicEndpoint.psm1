function Assert-M365DscPublicKeyVault
{
    param([Parameter(Mandatory)][object]$Vault, [Parameter(Mandatory)][string]$EnvironmentName)
    if ($Vault.PublicNetworkAccess -ne 'Enabled')
    {
        throw "Environment '$EnvironmentName': Key Vault public access is disabled or unverified. Select Kdbx explicitly and rerun; no private endpoint or automatic secret migration will be created."
    }
}
Export-ModuleMember -Function Assert-M365DscPublicKeyVault
