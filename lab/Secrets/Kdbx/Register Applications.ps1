[CmdletBinding()]
param([string[]]$EnvironmentName)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $PSScriptRoot\..\..\..).Path
$env:PSModulePath += [IO.Path]::PathSeparator + "$root\output\RequiredModules"
Import-Module $root\lab\Azure\AzHelpers.psm1 -Force -ErrorAction Stop
Import-Module $PSScriptRoot\Store.psm1 -ErrorAction Stop
$datum = Get-M365DscKdbxProjectSettings -Datum (New-DatumStructure -DefinitionFile $root\source\Datum.yml)
$names = @($datum.Global.Azure.Environments.Keys)
if ($EnvironmentName)
{
    if (@($EnvironmentName | Where-Object { $_ -notin $names }).Count) { throw 'An unknown environment was requested.' }
    $names = @($names | Where-Object { $_ -in $EnvironmentName })
}
$deploymentId = Get-M365DscDeploymentId
$roles = 'M365DscSetupApplication','M365DscLcmApplication','M365DscExportApplication'
foreach ($name in $names)
{
    $environment = $datum.Global.Azure.Environments[$name]
    Write-Host "Registering isolated KDBX deployment applications for '$name'."
    $context = Connect-M365DscEnvironmentContext -TenantName $environment.AzTenantName
    Connect-M365Dsc -TenantId $context.Tenant.Id -TenantName $environment.AzTenantName `
        -SubscriptionId $context.Subscription.Id -SkipExchangeOnline:($environment.HasExchangeOnline -eq $false) -ErrorAction Stop
    try
    {
        if (-not (Test-M365DscConnection -TenantId $context.Tenant.Id -SubscriptionId $context.Subscription.Id `
                    -SkipExchangeOnline:($environment.HasExchangeOnline -eq $false))) { throw "Connection mismatch for '$name'." }
        $identities = foreach ($role in $roles)
        {
            $applicationName = "$role-$deploymentId"
            $binding = "Application/$name/$role"
            $application = New-M365DscIdentity -Name $applicationName -PassThru
            if (-not $application.AppId) { throw "Could not create application role '$role'." }
            if (Test-M365DscSecret $binding)
            {
                $storedId = Get-M365DscSecret $binding
                try
                {
                    if ([Net.NetworkCredential]::new('', $storedId).Password -ne $application.AppId)
                    {
                        throw "Application binding mismatch for '$role'; refusing to reuse unrelated credentials."
                    }
                }
                finally { $storedId.Dispose() }
            }
            else
            {
                $id = ConvertTo-M365DscSecureString $application.AppId
                try { Set-M365DscSecret -Name $binding -Value $id } finally { $id.Dispose() }
            }
            $access = if ($role -eq 'M365DscExportApplication') { 'Read' } else { 'Update' }
            Add-M365DscIdentityPermission -Identity $application -AccessType $access -SkipAzurePermissions `
                -AddToGlobalAdminRole:($role -eq 'M365DscSetupApplication') | Out-Null
            $scope = "/subscriptions/$($context.Subscription.Id)"
            if (-not (Get-AzRoleAssignment -ObjectId $application.AppPrincipalId -RoleDefinitionName Reader -Scope $scope -ErrorAction Stop))
            {
                New-AzRoleAssignment -ObjectId $application.AppPrincipalId -RoleDefinitionName Reader -Scope $scope -ErrorAction Stop | Out-Null
            }
            $record = "Certificate/$name/$role"
            if (-not (Test-M365DscSecret $record))
            {
                $application = New-M365DscIdentity -Name $applicationName -GenereateCertificate -PassThru
                $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($application.CertificateThumbprint)" -ErrorAction Stop
                $random = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
                $password = ConvertTo-M365DscSecureString ([Convert]::ToBase64String($random))
                $pfx = $null
                try
                {
                    $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
                    Set-M365DscSecret -Name $record -Value $password -Attachment $pfx
                }
                finally
                {
                    $password.Dispose()
                    [Array]::Clear($random, 0, $random.Length)
                    if ($pfx) { [Array]::Clear($pfx, 0, $pfx.Length) }
                }
            }
            $stored = Get-M365DscStoredCertificate -EnvironmentName $name -IdentityName $role
            try
            {
                $local = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($stored.Thumbprint)" -ErrorAction SilentlyContinue
                if (-not $local -or -not $local.HasPrivateKey)
                {
                    $temporaryPath = Join-Path (Split-Path $env:M365DSC_SECRET_STORE -Parent) "$([Guid]::NewGuid().ToString('N')).pfx"
                    try
                    {
                        [IO.File]::WriteAllBytes($temporaryPath, $stored.Pfx)
                        Import-PfxCertificate -FilePath $temporaryPath -Password $stored.Password `
                            -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop | Out-Null
                    }
                    finally { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -ErrorAction Stop } }
                }
                @{ Name = $role; ApplicationId = $application.AppId; CertificateThumbprint = $stored.Thumbprint }
            }
            finally
            {
                $stored.Password.Dispose()
                [Array]::Clear($stored.Pfx, 0, $stored.Pfx.Length)
            }
        }
        Set-M365DscSecretJson -Name "Environment/$name" -Value @{
            AzTenantName = $environment.AzTenantName
            AzTenantId = [string]$context.Tenant.Id
            AzSubscriptionId = [string]$context.Subscription.Id
            HasExchangeOnline = [bool]$environment.HasExchangeOnline
            HasSharePointOnline = [bool]$environment.HasSharePointOnline
            Identities = @($identities)
        }
    }
    finally { Disconnect-M365Dsc -KeepAzureContext }
}
