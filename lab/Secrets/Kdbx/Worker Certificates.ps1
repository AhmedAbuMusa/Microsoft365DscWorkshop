[CmdletBinding()]
param(
    [Parameter(Mandatory)][object]$VM,
    [Parameter(Mandatory)][object]$Environment,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][scriptblock]$InvokeCommand
)
$ErrorActionPreference = 'Stop'
Import-Module $PSScriptRoot\Store.psm1 -ErrorAction Stop
foreach ($role in 'M365DscLcmApplication','M365DscExportApplication')
{
    $stored = Get-M365DscStoredCertificate -EnvironmentName $EnvironmentName -IdentityName $role
    try
    {
        $identity = @($Environment.Identities | Where-Object Name -EQ $role)
        if ($identity.Count -ne 1 -or $identity[0].CertificateThumbprint -ne $stored.Thumbprint)
        {
            throw "Recovery certificate mismatch for '$EnvironmentName/$role'."
        }
        & $InvokeCommand -VM $VM -TimeoutInSeconds 600 -ScriptBlock {
            param([string]$PfxBase64, [string]$PfxPassword, [string]$Thumbprint)
            $ErrorActionPreference = 'Stop'
            $folder = Join-Path $env:TEMP ([Guid]::NewGuid().ToString('N'))
            $path = Join-Path $folder 'authentication.pfx'
            $password = [securestring]::new()
            try
            {
                $null = New-Item $folder -ItemType Directory
                $acl = [Security.AccessControl.DirectorySecurity]::new()
                $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.WindowsIdentity]::GetCurrent().User,
                    'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
                Set-Acl -LiteralPath $folder -AclObject $acl -ErrorAction Stop
                [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($PfxBase64))
                foreach ($character in $PfxPassword.ToCharArray()) { $password.AppendChar($character) }
                $password.MakeReadOnly()
                Import-PfxCertificate -FilePath $path -Password $password -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop | Out-Null
                $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop
                if (-not $certificate.HasPrivateKey) { throw 'The worker certificate was imported without a private key.' }
            }
            finally
            {
                $password.Dispose()
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop }
                if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -ErrorAction Stop }
                $PfxBase64 = $null
                $PfxPassword = $null
            }
            Write-Output 'Worker authentication certificate installed.'
        } -Parameters @{
            PfxBase64 = [Convert]::ToBase64String($stored.Pfx)
            PfxPassword = [Net.NetworkCredential]::new('', $stored.Password).Password
            Thumbprint = $stored.Thumbprint
        }
    }
    finally
    {
        $stored.Password.Dispose()
        [Array]::Clear($stored.Pfx, 0, $stored.Pfx.Length)
    }
}
